/**
 * Two API instances, one Postgres, one Redis — the deployment backend.md §2
 * describes.
 *
 * The camera connects to instance A and the viewer to instance B: without the
 * Redis pub/sub bridge nothing would reach the other side, so this is the test
 * that proves the bridge, over real sockets and a real broker.
 */

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import type { Redis } from 'ioredis';
import type { FastifyInstance } from 'fastify';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import { loadConfig } from '../../src/config.ts';
import { createPool } from '../../src/db/pool.ts';
import type { PgPool } from '../../src/db/pool.ts';
import { runMigrations } from '../../src/db/migrate.ts';
import type { AppContext } from '../../src/http/context.ts';
import { createLogger } from '../../src/logger.ts';
import { Metrics } from '../../src/metrics/registry.ts';
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import { PostgresRepository } from '../../src/repositories/postgres.ts';
import { buildServer } from '../../src/server.ts';
import { RedisMessageBus } from '../../src/ws/bus.ts';
import type { Signaling } from '../../src/ws/attach.ts';
import { attachSignaling } from '../../src/ws/attach.ts';
import { SIGNAL_PATH } from '../../src/ws/signal.ts';
import { bootstrapCamera, bootstrapViewer, secondsOf } from '../helpers/app.ts';
import { FakeApnsSender } from '../helpers/fake-apns.ts';
import { SignalClient, signalAuthHeader } from '../helpers/signal.ts';
import {
  TEST_DATABASE_URL,
  createTestRedis,
  postgresAvailable,
  redisAvailable,
} from '../helpers/services.ts';
import { WebSocket } from 'ws';
import { once } from 'node:events';

const available = (await postgresAvailable()) && (await redisAvailable());

interface Instance {
  readonly app: FastifyInstance;
  readonly ctx: AppContext;
  readonly signaling: Signaling;
  readonly url: string;
  readonly clients: Redis[];
}

describe.skipIf(!available)('signaling across two instances', () => {
  let pool: PgPool;
  const instances: Instance[] = [];
  let clock = new Date();

  async function startInstance(): Promise<Instance> {
    const publisher = createTestRedis();
    const subscriber = createTestRedis();
    await publisher.connect();
    await subscriber.connect();

    const ctx: AppContext = {
      config: loadConfig({ NODE_ENV: 'test' }),
      repository: new PostgresRepository(pool),
      nonceStore: new MemoryNonceStore(),
      rateLimiter: new MemoryRateLimiter(() => clock.getTime()),
      logger: createLogger('silent'),
      metrics: new Metrics(),
      apns: new FakeApnsSender(),
      signaling: null,
      now: () => clock,
    };

    const app = buildServer(ctx);
    const signaling = attachSignaling(
      app,
      ctx,
      new RedisMessageBus(publisher, subscriber),
    );
    await app.listen({ host: '127.0.0.1', port: 0 });
    const address = app.server.address() as AddressInfo;

    const instance: Instance = {
      app,
      ctx,
      signaling,
      url: `ws://127.0.0.1:${address.port}${SIGNAL_PATH}`,
      clients: [publisher, subscriber],
    };
    instances.push(instance);
    return instance;
  }

  async function connect(
    instance: Instance,
    device: { pairingId: string; deviceId: string; deviceKey: Buffer },
  ): Promise<SignalClient> {
    const socket = new WebSocket(instance.url, {
      headers: {
        authorization: signalAuthHeader({
          pairingId: device.pairingId,
          deviceId: device.deviceId,
          deviceKey: device.deviceKey,
          timestampSeconds: secondsOf(clock),
        }),
      },
    });
    const client = new SignalClient(socket);
    await once(socket, 'open');
    return client;
  }

  beforeAll(async () => {
    pool = createPool(TEST_DATABASE_URL);
    await runMigrations(pool);
  });

  afterAll(async () => {
    for (const instance of instances) {
      await instance.signaling.close();
      await instance.app.close();
      for (const client of instance.clients) client.disconnect();
    }
    await pool.end();
  });

  beforeEach(async () => {
    clock = new Date();
    await pool.query('truncate table pairings cascade');
  });

  it('routes a sealed blob from a camera on A to a viewer on B', async () => {
    const instanceA = await startInstance();
    const instanceB = await startInstance();

    const camera = await bootstrapCamera({
      app: instanceA.app,
      now: () => clock,
    });
    clock = new Date(clock.getTime() + 1000);
    const viewer = await bootstrapViewer(
      { app: instanceA.app, now: () => clock },
      camera,
    );
    clock = new Date(clock.getTime() + 1000);

    const cameraClient = await connect(instanceA, {
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: camera.deviceKey,
    });
    expect(await cameraClient.next()).toMatchObject({ type: 'ready' });

    clock = new Date(clock.getTime() + 1000);
    const viewerClient = await connect(instanceB, {
      pairingId: viewer.pairingId,
      deviceId: viewer.deviceId,
      deviceKey: viewer.deviceKey,
    });
    expect(await viewerClient.next()).toMatchObject({ type: 'ready' });

    // Presence crosses instances, which is how the camera learns to offer.
    expect(await cameraClient.next()).toEqual({
      type: 'peer-online',
      peer: `viewer:${viewer.deviceId}`,
    });
    expect(await viewerClient.next()).toEqual({
      type: 'peer-online',
      peer: 'camera',
    });

    const offer = randomBytes(200).toString('base64');
    cameraClient.send({
      to: `viewer:${viewer.deviceId}`,
      seq: 1,
      blob: offer,
    });
    expect(await viewerClient.next()).toEqual({
      type: 'message',
      from: 'camera',
      to: `viewer:${viewer.deviceId}`,
      seq: 1,
      blob: offer,
    });

    const answer = randomBytes(180).toString('base64');
    viewerClient.send({ to: 'camera', seq: 1, blob: answer });
    expect(await cameraClient.next()).toEqual({
      type: 'message',
      from: `viewer:${viewer.deviceId}`,
      to: 'camera',
      seq: 1,
      blob: answer,
    });

    viewerClient.close();
    expect(await cameraClient.next()).toEqual({
      type: 'peer-offline',
      peer: `viewer:${viewer.deviceId}`,
    });
    cameraClient.socket.terminate();
  });
});
