/**
 * Integration tests against a real Postgres (docker-compose, or the services
 * CI provides).
 *
 * Skipped automatically when the database is unreachable; see
 * backend/README.md for how to run them.
 */

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import { createPool } from '../../src/db/pool.ts';
import type { PgPool } from '../../src/db/pool.ts';
import { runMigrations } from '../../src/db/migrate.ts';
import { PostgresRepository } from '../../src/repositories/postgres.ts';
import { purgeStalePairings } from '../../src/jobs/purge.ts';
import { loadConfig } from '../../src/config.ts';
import { createLogger } from '../../src/logger.ts';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import { Metrics } from '../../src/metrics/registry.ts';
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import { buildServer } from '../../src/server.ts';
import type { AppContext } from '../../src/http/context.ts';
import {
  CAMERA_TOKEN,
  VIEWER_TOKEN,
  bootstrapCamera,
  bootstrapViewer,
  errorCode,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';
import { FakeApnsSender } from '../helpers/fake-apns.ts';
import { TEST_DATABASE_URL, postgresAvailable } from '../helpers/services.ts';

const available = await postgresAvailable();

describe.skipIf(!available)('PostgresRepository', () => {
  let pool: PgPool;
  let repository: PostgresRepository;
  const now = new Date('2026-08-10T12:00:00.000Z');

  beforeAll(async () => {
    pool = createPool(TEST_DATABASE_URL);
    await runMigrations(pool);
    repository = new PostgresRepository(pool);
  });

  afterAll(async () => {
    await pool.end();
  });

  beforeEach(async () => {
    await pool.query('truncate table pairings cascade');
  });

  async function seedPairing(): Promise<{
    pairingId: string;
    cameraId: string;
    kAuth: Buffer;
    cameraDeviceKey: Buffer;
  }> {
    const pairingId = randomUUID();
    const cameraId = randomUUID();
    const kAuth = randomBytes(32);
    const cameraDeviceKey = randomBytes(32);
    const created = await repository.createPairing({
      pairingId,
      kAuth,
      cameraDeviceId: cameraId,
      cameraDeviceKey,
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
      now,
    });
    expect(created.ok).toBe(true);
    return { pairingId, cameraId, kAuth, cameraDeviceKey };
  }

  function claimInput(
    pairingId: string,
  ): Parameters<PostgresRepository['claimPairing']>[0] {
    return {
      pairingId,
      viewerDeviceId: randomUUID(),
      viewerDeviceKey: randomBytes(32),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() - 600_000),
      now,
    };
  }

  it('round-trips k_auth and the device key as raw bytes', async () => {
    const { pairingId, cameraId, kAuth, cameraDeviceKey } = await seedPairing();
    const stored = await repository.getPairing(pairingId);
    expect(stored?.status).toBe('pending');
    expect(stored?.kAuth.equals(kAuth)).toBe(true);

    const camera = await repository.getDevice(pairingId, cameraId);
    expect(camera?.deviceKey.equals(cameraDeviceKey)).toBe(true);
    expect(camera?.deviceKey.equals(kAuth)).toBe(false);
  });

  it('rejects a device key that is not 32 bytes', async () => {
    const { pairingId } = await seedPairing();
    await expect(
      pool.query(
        `insert into devices
           (id, pairing_id, role, device_key, apns_token, apns_environment,
            created_at)
         values ($1, $2, 'viewer', $3, $4, 'sandbox', now())`,
        [randomUUID(), pairingId, randomBytes(16), VIEWER_TOKEN],
      ),
    ).rejects.toMatchObject({ code: '23514' });
  });

  it('rejects a duplicate pairing id', async () => {
    const { pairingId } = await seedPairing();
    const again = await repository.createPairing({
      pairingId,
      kAuth: randomBytes(32),
      cameraDeviceId: randomUUID(),
      cameraDeviceKey: randomBytes(32),
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
      now,
    });
    expect(again).toEqual({ ok: false, reason: 'conflict' });
  });

  it('activates the pairing on claim', async () => {
    const { pairingId } = await seedPairing();
    const claimed = await repository.claimPairing(claimInput(pairingId));
    expect(claimed.ok).toBe(true);
    expect((await repository.getPairing(pairingId))?.status).toBe('active');
  });

  it('holds the max-viewer limit under concurrent claims', async () => {
    const { pairingId } = await seedPairing();
    const attempts = Array.from({ length: 8 }, () =>
      repository.claimPairing(claimInput(pairingId)),
    );
    const results = await Promise.all(attempts);
    expect(results.filter((result) => result.ok)).toHaveLength(5);
    expect(
      results.filter(
        (result) => !result.ok && result.reason === 'too_many_viewers',
      ),
    ).toHaveLength(3);

    const viewers = (await repository.listDevices(pairingId)).filter(
      (device) => device.role === 'viewer',
    );
    expect(viewers).toHaveLength(5);
  });

  it('rejects a claim on an expired pending pairing', async () => {
    const { pairingId } = await seedPairing();
    const result = await repository.claimPairing({
      ...claimInput(pairingId),
      expiredBefore: new Date(now.getTime() + 1),
    });
    expect(result).toEqual({ ok: false, reason: 'expired' });
  });

  it('cascades device deletion when a pairing is deleted', async () => {
    const { pairingId } = await seedPairing();
    await repository.claimPairing(claimInput(pairingId));

    expect(await repository.deletePairing(pairingId)).toBe(true);
    const remaining = await pool.query(
      'select count(*)::int as count from devices where pairing_id = $1',
      [pairingId],
    );
    expect(remaining.rows[0]?.count).toBe(0);
  });

  it('enforces one camera per pairing at the database level', async () => {
    const { pairingId } = await seedPairing();
    await expect(
      pool.query(
        `insert into devices
           (id, pairing_id, role, device_key, apns_token, apns_environment,
            created_at)
         values ($1, $2, 'camera', $3, $4, 'sandbox', now())`,
        [randomUUID(), pairingId, randomBytes(32), CAMERA_TOKEN],
      ),
    ).rejects.toMatchObject({ code: '23505' });
  });

  it('deletes every device holding a token (APNs 410 cleanup)', async () => {
    const { pairingId } = await seedPairing();
    await repository.claimPairing(claimInput(pairingId));

    expect(await repository.deleteDevicesByApnsToken(VIEWER_TOKEN)).toBe(1);
    expect(await repository.listDevices(pairingId)).toHaveLength(1);
  });

  it('rotates a token without touching the device key', async () => {
    const { pairingId, cameraId, cameraDeviceKey } = await seedPairing();
    const updated = await repository.updateDeviceToken({
      pairingId,
      deviceId: cameraId,
      apnsToken: 'e'.repeat(64),
      apnsEnvironment: 'production',
      now,
    });
    expect(updated?.apnsToken).toBe('e'.repeat(64));
    expect(updated?.deviceKey.equals(cameraDeviceKey)).toBe(true);
  });

  it('purges revoked and expired pairings but keeps active ones', async () => {
    const stale = await seedPairing();
    const active = await seedPairing();
    await repository.claimPairing(claimInput(active.pairingId));

    const revoked = await seedPairing();
    await pool.query(`update pairings set status = 'revoked' where id = $1`, [
      revoked.pairingId,
    ]);

    const result = await purgeStalePairings(
      repository,
      600,
      new Date(now.getTime() + 3_600_000),
    );
    expect(result.revokedPairings).toBe(1);
    expect(result.expiredPairings).toBe(1);

    expect(await repository.getPairing(stale.pairingId)).toBeNull();
    expect(await repository.getPairing(revoked.pairingId)).toBeNull();
    expect(await repository.getPairing(active.pairingId)).not.toBeNull();
  });

  it('applies migrations idempotently', async () => {
    const second = await runMigrations(pool);
    expect(second.applied).toHaveLength(0);
    expect(second.skipped.length).toBeGreaterThan(0);
  });
});

describe.skipIf(!available)('HTTP against Postgres', () => {
  let pool: PgPool;
  let ctx: AppContext;
  let apns: FakeApnsSender;
  let clock = new Date();

  beforeAll(async () => {
    pool = createPool(TEST_DATABASE_URL);
    await runMigrations(pool);
    apns = new FakeApnsSender();
    ctx = {
      config: loadConfig({ NODE_ENV: 'test' }),
      repository: new PostgresRepository(pool),
      nonceStore: new MemoryNonceStore(),
      rateLimiter: new MemoryRateLimiter(() => clock.getTime()),
      logger: createLogger('silent'),
      metrics: new Metrics(),
      apns,
      signaling: null,
      now: () => clock,
    };
  });

  afterAll(async () => {
    await pool.end();
  });

  beforeEach(async () => {
    clock = new Date();
    apns.reset();
    await pool.query('truncate table pairings cascade');
  });

  it('runs the create → claim → event → revoke flow end to end', async () => {
    const app = buildServer(ctx);
    const harness = { app, now: () => clock };

    const camera = await bootstrapCamera(harness);
    clock = new Date(clock.getTime() + 1000);
    const viewer = await bootstrapViewer(harness, camera);
    clock = new Date(clock.getTime() + 1000);

    // Shaped like a real sealed envelope: 12-byte nonce, ciphertext, 16-byte
    // tag. The server never looks inside it.
    const ciphertext = randomBytes(60).toString('base64');
    const event = await app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(clock),
        body: JSON.stringify({ ciphertext }),
      }),
    );
    expect(event.statusCode).toBe(202);
    expect(apns.sent).toHaveLength(1);
    expect(apns.sent[0]?.notification.deviceToken).toBe(viewer.apnsToken);
    expect(apns.sent[0]?.payload.ciphertext).toBe(ciphertext);

    clock = new Date(clock.getTime() + 1000);
    const revoked = await app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(clock),
      }),
    );
    expect(revoked.statusCode).toBe(204);

    const rows = await pool.query(
      'select count(*)::int as count from devices where pairing_id = $1',
      [camera.pairingId],
    );
    expect(rows.rows[0]?.count).toBe(0);
    await app.close();
  });

  it('refuses a viewer key on a camera-only route, against real rows', async () => {
    const app = buildServer(ctx);
    const harness = { app, now: () => clock };

    const camera = await bootstrapCamera(harness);
    clock = new Date(clock.getTime() + 1000);
    const viewer = await bootstrapViewer(harness, camera);
    clock = new Date(clock.getTime() + 1000);

    const response = await app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: viewer.deviceKey,
        pairingId: camera.pairingId,
        principal: viewer.deviceId,
        timestampSeconds: secondsOf(clock),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');

    const rows = await pool.query(
      'select count(*)::int as count from pairings where id = $1',
      [camera.pairingId],
    );
    expect(rows.rows[0]?.count).toBe(1);
    await app.close();
  });
});
