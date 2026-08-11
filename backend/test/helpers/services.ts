/**
 * Availability probes for the docker-compose services.
 *
 * Integration tests skip (rather than fail) when Postgres or Redis is not
 * reachable, so `npm test` is green on a machine without Docker while still
 * exercising the real stores in CI.
 */

import { Redis } from 'ioredis';
import pg from 'pg';

export const TEST_DATABASE_URL =
  process.env['TEST_DATABASE_URL'] ??
  process.env['DATABASE_URL'] ??
  'postgres://cribwire:cribwire@localhost:5432/cribwire_test';

export const TEST_REDIS_URL =
  process.env['TEST_REDIS_URL'] ??
  process.env['REDIS_URL'] ??
  'redis://localhost:6379/1';

export async function postgresAvailable(): Promise<boolean> {
  const pool = new pg.Pool({
    connectionString: TEST_DATABASE_URL,
    connectionTimeoutMillis: 1500,
    max: 1,
  });
  try {
    await pool.query('select 1');
    return true;
  } catch {
    return false;
  } finally {
    await pool.end().catch(() => undefined);
  }
}

export function createTestRedis(): Redis {
  return new Redis(TEST_REDIS_URL, {
    lazyConnect: true,
    connectTimeout: 1500,
    maxRetriesPerRequest: 1,
    retryStrategy: () => null,
    enableOfflineQueue: false,
  });
}

export async function redisAvailable(): Promise<boolean> {
  const redis = createTestRedis();
  try {
    await redis.connect();
    await redis.ping();
    return true;
  } catch {
    return false;
  } finally {
    redis.disconnect();
  }
}
