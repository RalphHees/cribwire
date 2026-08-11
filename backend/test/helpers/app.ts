/**
 * Test harness: the real Fastify app on an in-memory repository, a
 * controllable clock, a fake APNs sender, and a signer that produces
 * `CribWire-HMAC` headers the way the iOS app will (protocol.md 1.1).
 */

import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance, LightMyRequestResponse } from 'fastify';
import type { Config } from '../../src/config.ts';
import { loadConfig } from '../../src/config.ts';
import { createLogger } from '../../src/logger.ts';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import { Metrics } from '../../src/metrics/registry.ts';
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import { MemoryRepository } from '../../src/repositories/memory.ts';
import type { AppContext } from '../../src/http/context.ts';
import { buildServer } from '../../src/server.ts';
import {
  BOOTSTRAP_PRINCIPAL,
  bodySha256Hex,
  buildAuthHeader,
  canonicalString,
  computeMac,
} from '../../src/auth/canonical.ts';
import { FakeApnsSender } from './fake-apns.ts';

export interface TestApp {
  readonly app: FastifyInstance;
  readonly ctx: AppContext;
  readonly repository: MemoryRepository;
  readonly config: Config;
  readonly metrics: Metrics;
  readonly apns: FakeApnsSender;
  readonly setNow: (date: Date) => void;
  readonly now: () => Date;
  readonly close: () => Promise<void>;
}

export function createTestContext(overrides: Partial<Config> = {}): {
  ctx: AppContext;
  repository: MemoryRepository;
  config: Config;
  apns: FakeApnsSender;
  metrics: Metrics;
  setNow: (date: Date) => void;
  now: () => Date;
} {
  const base = loadConfig({ NODE_ENV: 'test' });
  const config: Config = { ...base, ...overrides };
  const repository = new MemoryRepository();
  const apns = new FakeApnsSender();
  const metrics = new Metrics();
  let clock = new Date('2026-08-10T12:00:00.000Z');

  const ctx: AppContext = {
    config,
    repository,
    nonceStore: new MemoryNonceStore(),
    rateLimiter: new MemoryRateLimiter(() => clock.getTime()),
    logger: createLogger('silent'),
    metrics,
    apns,
    signaling: null,
    now: () => clock,
  };

  return {
    ctx,
    repository,
    config,
    apns,
    metrics,
    setNow: (date) => {
      clock = date;
    },
    now: () => clock,
  };
}

export function createTestApp(overrides: Partial<Config> = {}): TestApp {
  const harness = createTestContext(overrides);
  const app = buildServer(harness.ctx);

  return {
    app,
    ctx: harness.ctx,
    repository: harness.repository,
    config: harness.config,
    metrics: harness.metrics,
    apns: harness.apns,
    setNow: harness.setNow,
    now: harness.now,
    close: async () => {
      await app.close();
      await harness.repository.close();
    },
  };
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'DELETE';

export interface SignOptions {
  readonly method: HttpMethod;
  readonly path: string;
  /** `K_auth` for a bootstrap call, the device's own key otherwise. */
  readonly key: Buffer;
  readonly pairingId: string;
  /** `bootstrap` or the calling device's UUID. */
  readonly principal: string;
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
    options.principal,
    bodySha256Hex(body),
  );
  const macHex = computeMac(options.key, canonical);
  return {
    method: options.method,
    url: options.path,
    headers: {
      authorization: buildAuthHeader({
        pairingId: options.pairingId,
        principal: options.principal,
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
  return jsonOf<{ error: string }>(response).error;
}

export function secondsOf(date: Date): number {
  return Math.floor(date.getTime() / 1000);
}

export const CAMERA_TOKEN = 'a'.repeat(64);
export const VIEWER_TOKEN = 'b'.repeat(64);

/** A paired camera: what `POST /v1/pairings` leaves the client holding. */
export interface CameraCredentials {
  readonly pairingId: string;
  readonly kAuth: Buffer;
  readonly deviceId: string;
  readonly deviceKey: Buffer;
}

export interface ViewerCredentials {
  readonly pairingId: string;
  readonly deviceId: string;
  readonly deviceKey: Buffer;
  readonly apnsToken: string;
}

export function createPairingBody(
  pairingId: string,
  kAuth: Buffer,
  deviceKey: Buffer,
  apnsToken = CAMERA_TOKEN,
): string {
  return JSON.stringify({
    pairingId,
    kAuth: kAuth.toString('base64'),
    deviceKey: deviceKey.toString('base64'),
    apnsToken,
    apnsEnvironment: 'sandbox',
  });
}

export function claimBody(deviceKey: Buffer, apnsToken = VIEWER_TOKEN): string {
  return JSON.stringify({
    deviceKey: deviceKey.toString('base64'),
    apnsToken,
    apnsEnvironment: 'sandbox',
  });
}

/** Runs the real bootstrap flow so tests start from genuine credentials. */
export async function bootstrapCamera(
  harness: Pick<TestApp, 'app' | 'now'>,
  options: { pairingId?: string; kAuth?: Buffer; apnsToken?: string } = {},
): Promise<CameraCredentials> {
  const pairingId = options.pairingId ?? randomUUID();
  const kAuth = options.kAuth ?? randomBytes(32);
  const deviceKey = randomBytes(32);

  const response = await harness.app.inject(
    signRequest({
      method: 'POST',
      path: '/v1/pairings',
      key: kAuth,
      pairingId,
      principal: BOOTSTRAP_PRINCIPAL,
      timestampSeconds: secondsOf(harness.now()),
      body: createPairingBody(
        pairingId,
        kAuth,
        deviceKey,
        options.apnsToken ?? CAMERA_TOKEN,
      ),
    }),
  );
  if (response.statusCode !== 201) {
    throw new Error(`camera bootstrap failed: ${response.statusCode}`);
  }
  const body = jsonOf<{ deviceId: string }>(response);
  return { pairingId, kAuth, deviceId: body.deviceId, deviceKey };
}

export async function bootstrapViewer(
  harness: Pick<TestApp, 'app' | 'now'>,
  camera: CameraCredentials,
  apnsToken = VIEWER_TOKEN,
): Promise<ViewerCredentials> {
  const deviceKey = randomBytes(32);
  const response = await harness.app.inject(
    signRequest({
      method: 'POST',
      path: `/v1/pairings/${camera.pairingId}/claim`,
      key: camera.kAuth,
      pairingId: camera.pairingId,
      principal: BOOTSTRAP_PRINCIPAL,
      timestampSeconds: secondsOf(harness.now()),
      body: claimBody(deviceKey, apnsToken),
    }),
  );
  if (response.statusCode !== 201) {
    throw new Error(`viewer bootstrap failed: ${response.statusCode}`);
  }
  const body = jsonOf<{ deviceId: string }>(response);
  return {
    pairingId: camera.pairingId,
    deviceId: body.deviceId,
    deviceKey,
    apnsToken,
  };
}
