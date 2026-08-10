/**
 * Wires the concrete adapters (Postgres, Redis) into an `AppContext`.
 *
 * Redis is optional in development and test only: without it the nonce cache
 * and rate-limit buckets are per-process, which is unsafe across instances.
 * Production therefore refuses to start without `REDIS_URL`.
 */

import { Redis } from 'ioredis';
import type { Config } from './config.ts';
import type { Logger } from './logger.ts';
import { MemoryNonceStore, RedisNonceStore } from './auth/nonce-store.ts';
import type { NonceStore } from './auth/nonce-store.ts';
import { createPool } from './db/pool.ts';
import type { AppContext } from './http/context.ts';
import {
  MemoryRateLimiter,
  RedisRateLimiter,
} from './ratelimit/token-bucket.ts';
import type { RateLimiter } from './ratelimit/token-bucket.ts';
import { PostgresRepository } from './repositories/postgres.ts';
import type { Repository } from './repositories/types.ts';

export interface AppResources {
  readonly ctx: AppContext;
  close(): Promise<void>;
}

export function createRedis(url: string): Redis {
  return new Redis(url, {
    maxRetriesPerRequest: 2,
    // Fail closed: if Redis is unreachable the replay cache cannot vouch for a
    // request, and auth must reject rather than accept unchecked.
    enableOfflineQueue: false,
    lazyConnect: false,
  });
}

export function createAppResources(
  config: Config,
  logger: Logger,
): AppResources {
  const pool = createPool(config.databaseUrl);
  const repository: Repository = new PostgresRepository(pool);

  let nonceStore: NonceStore;
  let rateLimiter: RateLimiter;
  let redis: Redis | null = null;

  if (config.redisUrl !== undefined && config.redisUrl !== '') {
    redis = createRedis(config.redisUrl);
    redis.on('error', (error: Error) => {
      logger.error('redis error', { reason: error.message });
    });
    nonceStore = new RedisNonceStore(redis);
    rateLimiter = new RedisRateLimiter(redis);
  } else if (config.nodeEnv === 'production') {
    throw new Error('REDIS_URL is required in production');
  } else {
    logger.warn(
      'REDIS_URL unset: using per-process nonce cache and rate limits',
    );
    nonceStore = new MemoryNonceStore();
    rateLimiter = new MemoryRateLimiter();
  }

  const ctx: AppContext = {
    config,
    repository,
    nonceStore,
    rateLimiter,
    logger,
    now: () => new Date(),
  };

  return {
    ctx,
    close: async () => {
      await repository.close();
      if (redis !== null) {
        await redis.quit().catch(() => undefined);
      }
    },
  };
}
