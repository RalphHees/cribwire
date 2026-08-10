/**
 * Integration tests against a real Postgres (docker-compose).
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
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import { buildServer } from '../../src/server.ts';
import type { AppContext } from '../../src/http/context.ts';
import {
  CAMERA_TOKEN,
  VIEWER_TOKEN,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';
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
  }> {
    const pairingId = randomUUID();
    const cameraId = randomUUID();
    const kAuth = randomBytes(32);
    const created = await repository.createPairing({
      pairingId,
      kAuth,
      cameraDeviceId: cameraId,
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
      now,
    });
    expect(created.ok).toBe(true);
    return { pairingId, cameraId, kAuth };
  }

  it('round-trips k_auth as raw bytes', async () => {
    const { pairingId, kAuth } = await seedPairing();
    const stored = await repository.getPairing(pairingId);
    expect(stored?.status).toBe('pending');
    expect(stored?.kAuth.equals(kAuth)).toBe(true);
  });

  it('rejects a duplicate pairing id', async () => {
    const { pairingId } = await seedPairing();
    const again = await repository.createPairing({
      pairingId,
      kAuth: randomBytes(32),
      cameraDeviceId: randomUUID(),
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
      now,
    });
    expect(again).toEqual({ ok: false, reason: 'conflict' });
  });

  it('activates the pairing on claim', async () => {
    const { pairingId } = await seedPairing();
    const claimed = await repository.claimPairing({
      pairingId,
      viewerDeviceId: randomUUID(),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() - 600_000),
      now,
    });
    expect(claimed.ok).toBe(true);
    expect((await repository.getPairing(pairingId))?.status).toBe('active');
  });

  it('holds the max-viewer limit under concurrent claims', async () => {
    const { pairingId } = await seedPairing();
    const attempts = Array.from({ length: 8 }, () =>
      repository.claimPairing({
        pairingId,
        viewerDeviceId: randomUUID(),
        apnsToken: VIEWER_TOKEN,
        apnsEnvironment: 'sandbox',
        maxViewers: 5,
        expiredBefore: new Date(now.getTime() - 600_000),
        now,
      }),
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
      pairingId,
      viewerDeviceId: randomUUID(),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() + 1),
      now,
    });
    expect(result).toEqual({ ok: false, reason: 'expired' });
  });

  it('cascades device deletion when a pairing is deleted', async () => {
    const { pairingId } = await seedPairing();
    await repository.claimPairing({
      pairingId,
      viewerDeviceId: randomUUID(),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() - 600_000),
      now,
    });

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
           (id, pairing_id, role, apns_token, apns_environment, created_at)
         values ($1, $2, 'camera', $3, 'sandbox', now())`,
        [randomUUID(), pairingId, CAMERA_TOKEN],
      ),
    ).rejects.toMatchObject({ code: '23505' });
  });

  it('deletes every device holding a token (APNs 410 cleanup)', async () => {
    const { pairingId } = await seedPairing();
    await repository.claimPairing({
      pairingId,
      viewerDeviceId: randomUUID(),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() - 600_000),
      now,
    });

    expect(await repository.deleteDevicesByApnsToken(VIEWER_TOKEN)).toBe(1);
    expect(await repository.listDevices(pairingId)).toHaveLength(1);
  });

  it('purges revoked and expired pairings but keeps active ones', async () => {
    const stale = await seedPairing();
    const active = await seedPairing();
    await repository.claimPairing({
      pairingId: active.pairingId,
      viewerDeviceId: randomUUID(),
      apnsToken: VIEWER_TOKEN,
      apnsEnvironment: 'sandbox',
      maxViewers: 5,
      expiredBefore: new Date(now.getTime() - 600_000),
      now,
    });

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

  beforeAll(async () => {
    pool = createPool(TEST_DATABASE_URL);
    await runMigrations(pool);
    ctx = {
      config: loadConfig({ NODE_ENV: 'test' }),
      repository: new PostgresRepository(pool),
      nonceStore: new MemoryNonceStore(),
      rateLimiter: new MemoryRateLimiter(),
      logger: createLogger('silent'),
      now: () => new Date(),
    };
  });

  afterAll(async () => {
    await pool.end();
  });

  beforeEach(async () => {
    await pool.query('truncate table pairings cascade');
  });

  it('runs the create → claim → revoke flow end to end', async () => {
    const app = buildServer(ctx);
    const kAuth = randomBytes(32);
    const pairingId = randomUUID();
    const timestamp = secondsOf(new Date());

    const created = await app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: timestamp,
        body: JSON.stringify({
          pairingId,
          kAuth: kAuth.toString('base64'),
          apnsToken: CAMERA_TOKEN,
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(created.statusCode).toBe(201);

    const claimed = await app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${pairingId}/claim`,
        kAuth,
        pairingId,
        role: 'viewer',
        timestampSeconds: timestamp,
        body: JSON.stringify({
          apnsToken: VIEWER_TOKEN,
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(claimed.statusCode).toBe(201);

    const revoked = await app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: timestamp,
      }),
    );
    expect(revoked.statusCode).toBe(204);

    const rows = await pool.query(
      'select count(*)::int as count from devices where pairing_id = $1',
      [pairingId],
    );
    expect(rows.rows[0]?.count).toBe(0);
    await app.close();
  });
});
