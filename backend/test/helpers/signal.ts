/**
 * Harness for the `GET /v1/signal` WebSocket endpoint: a real listening
 * server, a real `ws` client, and a frame queue so a test can await the next
 * frame instead of sleeping.
 */

import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { WebSocket } from 'ws';
import type { Config } from '../../src/config.ts';
import type { AppContext } from '../../src/http/context.ts';
import type { MemoryRepository } from '../../src/repositories/memory.ts';
import { buildServer } from '../../src/server.ts';
import type { MessageBus } from '../../src/ws/bus.ts';
import { MemoryMessageBus } from '../../src/ws/bus.ts';
import type { Signaling } from '../../src/ws/attach.ts';
import { attachSignaling } from '../../src/ws/attach.ts';
import { SIGNAL_PATH } from '../../src/ws/signal.ts';
import {
  bodySha256Hex,
  buildAuthHeader,
  canonicalString,
  computeMac,
} from '../../src/auth/canonical.ts';
import { createTestContext } from './app.ts';
import type { Metrics } from '../../src/metrics/registry.ts';
import type { FakeApnsSender } from './fake-apns.ts';

export interface SignalHarness {
  readonly ctx: AppContext;
  readonly repository: MemoryRepository;
  readonly config: Config;
  readonly metrics: Metrics;
  readonly apns: FakeApnsSender;
  readonly signaling: Signaling;
  readonly url: string;
  readonly app: ReturnType<typeof buildServer>;
  setNow(date: Date): void;
  now(): Date;
  close(): Promise<void>;
}

export async function createSignalHarness(
  overrides: Partial<Config> = {},
  bus: MessageBus = new MemoryMessageBus(),
): Promise<SignalHarness> {
  const base = createTestContext(overrides);
  const app = buildServer(base.ctx);
  const signaling = attachSignaling(app, base.ctx, bus);

  await app.listen({ host: '127.0.0.1', port: 0 });
  const address = app.server.address() as AddressInfo;
  const url = `ws://127.0.0.1:${address.port}${SIGNAL_PATH}`;

  return {
    ctx: base.ctx,
    repository: base.repository,
    config: base.config,
    metrics: base.metrics,
    apns: base.apns,
    signaling,
    app,
    url,
    setNow: base.setNow,
    now: base.now,
    close: async () => {
      await signaling.close();
      await app.close();
      await base.repository.close();
      await bus.close();
    },
  };
}

/** The `Authorization` header a device presents on the upgrade. */
export function signalAuthHeader(options: {
  pairingId: string;
  deviceId: string;
  deviceKey: Buffer;
  timestampSeconds: number;
  path?: string;
}): string {
  const timestamp = String(options.timestampSeconds);
  const macHex = computeMac(
    options.deviceKey,
    canonicalString(
      'GET',
      options.path ?? SIGNAL_PATH,
      timestamp,
      options.deviceId,
      bodySha256Hex(undefined),
    ),
  );
  return buildAuthHeader({
    pairingId: options.pairingId,
    principal: options.deviceId,
    timestamp,
    macHex,
  });
}

export interface ServerFrameLike {
  readonly type: string;
  readonly [key: string]: unknown;
}

/** A connected client with a frame queue. */
export class SignalClient {
  readonly socket: WebSocket;
  readonly #queue: ServerFrameLike[] = [];
  readonly #waiters: ((frame: ServerFrameLike) => void)[] = [];
  closeEvent: { code: number; reason: string } | null = null;
  pings = 0;

  constructor(socket: WebSocket) {
    this.socket = socket;
    socket.on('message', (data: Buffer) => {
      const frame = JSON.parse(data.toString('utf8')) as ServerFrameLike;
      const waiter = this.#waiters.shift();
      if (waiter !== undefined) waiter(frame);
      else this.#queue.push(frame);
    });
    socket.on('ping', () => {
      this.pings += 1;
    });
    socket.on('close', (code: number, reason: Buffer) => {
      this.closeEvent = { code, reason: reason.toString('utf8') };
    });
    socket.on('error', () => {
      // Surfaced through `closeEvent`; ignored here so a refused upgrade or a
      // server-side close does not become an unhandled error.
    });
  }

  /** Resolves with the next frame, or rejects after `timeoutMs`. */
  next(timeoutMs = 2000): Promise<ServerFrameLike> {
    const queued = this.#queue.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('timed out waiting for a frame'));
      }, timeoutMs);
      this.#waiters.push((frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
    });
  }

  /** Frames received so far, without waiting. */
  drain(): ServerFrameLike[] {
    return this.#queue.splice(0);
  }

  send(payload: unknown): void {
    this.socket.send(
      typeof payload === 'string' ? payload : JSON.stringify(payload),
    );
  }

  async waitForClose(timeoutMs = 2000): Promise<{
    code: number;
    reason: string;
  }> {
    if (this.closeEvent !== null) return this.closeEvent;
    const closed = once(this.socket, 'close');
    const timer = setTimeout(() => {
      this.socket.terminate();
    }, timeoutMs);
    const [code, reason] = (await closed) as [number, Buffer];
    clearTimeout(timer);
    return { code, reason: reason.toString('utf8') };
  }

  close(): void {
    this.socket.close();
  }
}

export interface ConnectOptions {
  readonly pairingId: string;
  readonly deviceId: string;
  readonly deviceKey: Buffer;
  readonly timestampSeconds: number;
  /** Overrides the header entirely, for the unauthenticated cases. */
  readonly authorization?: string | null;
}

/** Opens a signaling socket and waits for the handshake to complete. */
export async function connectSignal(
  harness: SignalHarness,
  options: ConnectOptions,
): Promise<SignalClient> {
  const headers: Record<string, string> = {};
  if (options.authorization !== null) {
    headers['authorization'] =
      options.authorization ??
      signalAuthHeader({
        pairingId: options.pairingId,
        deviceId: options.deviceId,
        deviceKey: options.deviceKey,
        timestampSeconds: options.timestampSeconds,
      });
  }

  const socket = new WebSocket(harness.url, { headers });
  const client = new SignalClient(socket);
  await once(socket, 'open');
  return client;
}

/** Attempts an upgrade and resolves with the HTTP status it was refused with. */
export function expectUpgradeRejected(
  harness: SignalHarness,
  headers: Record<string, string>,
): Promise<number> {
  return new Promise<number>((resolve, reject) => {
    const socket = new WebSocket(harness.url, { headers });
    socket.on('unexpected-response', (_request, response) => {
      socket.terminate();
      resolve(response.statusCode ?? 0);
    });
    socket.on('open', () => {
      socket.close();
      reject(new Error('upgrade unexpectedly succeeded'));
    });
    socket.on('error', (error: Error) => {
      reject(error);
    });
  });
}
