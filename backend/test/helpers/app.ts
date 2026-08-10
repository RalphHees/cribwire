/**
 * Test harness: the real Fastify app on an in-memory repository, a controllable
 * clock, and a signer that produces `KidsCam-HMAC` headers the way the iOS app
 * will.
 */

import type { FastifyInstance, LightMyRequestResponse } from 'fastify';
import type { Config } from '../../src/config.ts';
import { loadConfig } from '../../src/config.ts';
import { createLogger } from '../../src/logger.ts';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import { MemoryRepository } from '../../src/repositories/memory.ts';
import type { AppContext } from '../../src/http/context.ts';
import { buildServer } from '../../src/server.ts';
import {
  bodySha256Hex,
  buildAuthHeader,
  canonicalString,
  computeMac,
} from '../../src/auth/canonical.ts';
import type { Role } from '../../src/domain/types.ts';

export interface TestApp {
  readonly app: FastifyInstance;
  readonly ctx: AppContext;
  readonly repository: MemoryRepository;
  readonly config: Config;
  setNow(date: Date): void;
  now(): Date;
  close(): Promise<void>;
}

export function createTestApp(overrides: Partial<Config> = {}): TestApp {
  const base = loadConfig({ NODE_ENV: 'test' });
  const config: Config = { ...base, ...overrides };
  const repository = new MemoryRepository();
  let clock = new Date('2026-08-10T12:00:00.000Z');

  const ctx: AppContext = {
    config,
    repository,
    nonceStore: new MemoryNonceStore(),
    rateLimiter: new MemoryRateLimiter(() => clock.getTime()),
    logger: createLogger('silent'),
    now: () => clock,
  };

  const app = buildServer(ctx);

  return {
    app,
    ctx,
    repository,
    config,
    setNow: (date) => {
      clock = date;
    },
    now: () => clock,
    close: async () => {
      await app.close();
      await repository.close();
    },
  };
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

export interface SignOptions {
  readonly method: HttpMethod;
  readonly path: string;
  readonly kAuth: Buffer;
  readonly pairingId: string;
  readonly role: Role;
  readonly timestampSeconds: number;
  readonly body?: string;
}

export interface SignedRequest {
  readonly method: HttpMethod;
  readonly url: string;
  readonly headers: Record<string, string>;
  readonly payload: string;
}

export function signRequest(options: SignOptions): SignedRequest {
  const body = options.body ?? '';
  const timestamp = String(options.timestampSeconds);
  const canonical = canonicalString(
    options.method,
    options.path,
    timestamp,
    bodySha256Hex(body),
  );
  const macHex = computeMac(options.kAuth, canonical);
  return {
    method: options.method,
    url: options.path,
    headers: {
      authorization: buildAuthHeader({
        pairingId: options.pairingId,
        role: options.role,
        timestamp,
        macHex,
      }),
      'content-type': 'application/json',
    },
    payload: body,
  };
}

/** Typed body access; `response.json()` is untyped. */
// eslint-disable-next-line @typescript-eslint/no-unnecessary-type-parameters -- deliberate caller-chosen assertion
export function jsonOf<T = unknown>(response: LightMyRequestResponse): T {
  return JSON.parse(response.body) as T;
}

export function errorCode(response: LightMyRequestResponse): string {
  return jsonOf<{ error: { code: string } }>(response).error.code;
}

export function secondsOf(date: Date): number {
  return Math.floor(date.getTime() / 1000);
}

export const CAMERA_TOKEN = 'a'.repeat(64);
export const VIEWER_TOKEN = 'b'.repeat(64);
