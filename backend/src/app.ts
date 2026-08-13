/**
 * Wires the concrete adapters (Postgres, Redis, APNs) into an `AppContext`.
 *
 * Redis is optional in development and test only: without it the nonce cache,
 * the rate-limit buckets, and the signaling bus are per-process, which is
 * unsafe (and, for the bus, simply wrong) across instances. Production
 * therefore refuses to start without `REDIS_URL`.
 */

import { Redis } from 'ioredis';
import type { Config } from './config.ts';
import { apnsConfigured, turnConfigured, turnScheme } from './config.ts';
import type { Logger } from './logger.ts';
import { MemoryNonceStore, RedisNonceStore } from './auth/nonce-store.ts';
import type { NonceStore } from './auth/nonce-store.ts';
import { createPool } from './db/pool.ts';
import type { AppContext } from './http/context.ts';
import { Metrics } from './metrics/registry.ts';
import type { ApnsSender } from './push/apns.ts';
import { DisabledApnsSender } from './push/apns.ts';
import { Http2ApnsSender } from './push/http2-apns.ts';
import {
  MemoryRateLimiter,
  RedisRateLimiter,
} from './ratelimit/token-bucket.ts';
import type { RateLimiter } from './ratelimit/token-bucket.ts';
import { PostgresRepository } from './repositories/postgres.ts';
import type { Repository } from './repositories/types.ts';
import type { MessageBus } from './ws/bus.ts';
import { MemoryMessageBus, RedisMessageBus } from './ws/bus.ts';

export interface AppResources {
  readonly ctx: AppContext;
  readonly bus: MessageBus;
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

function createApnsSender(config: Config, logger: Logger): ApnsSender {
  if (!apnsConfigured(config)) {
    if (config.nodeEnv === 'production') {
      throw new Error(
        'APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID and APNS_TOPIC are required in production',
      );
    }
    logger.warn('APNs is not configured: detection events will not be pushed');
    return new DisabledApnsSender();
  }
  return new Http2ApnsSender(config.apns, logger);
}

export function createAppResources(
  config: Config,
  logger: Logger,
): AppResources {
  const pool = createPool(config.databaseUrl);
  const repository: Repository = new PostgresRepository(pool);

  let nonceStore: NonceStore;
  let rateLimiter: RateLimiter;
  let bus: MessageBus;
  let redis: Redis | null = null;
  let subscriber: Redis | null = null;

  if (config.redisUrl !== undefined && config.redisUrl !== '') {
    redis = createRedis(config.redisUrl);
    subscriber = createRedis(config.redisUrl);
    for (const client of [redis, subscriber]) {
      client.on('error', (error: Error) => {
        logger.error('redis error', { reason: error.message });
      });
    }
    nonceStore = new RedisNonceStore(redis);
    rateLimiter = new RedisRateLimiter(redis);
    bus = new RedisMessageBus(redis, subscriber);
  } else if (config.nodeEnv === 'production') {
    throw new Error('REDIS_URL is required in production');
  } else {
    logger.warn(
      'REDIS_URL unset: per-process nonce cache, rate limits, and signaling bus',
    );
    nonceStore = new MemoryNonceStore();
    rateLimiter = new MemoryRateLimiter();
    bus = new MemoryMessageBus();
  }

  if (!turnConfigured(config)) {
    if (config.nodeEnv === 'production') {
      throw new Error(
        'TURN_URIS with either TURN_SHARED_SECRET (coturn) or ' +
          'TURN_STATIC_USERNAME/TURN_STATIC_CREDENTIAL (hosted relay) are ' +
          'required in production',
      );
    }
    logger.warn('TURN is not configured: turn-credentials answers 503');
  } else {
    // Which relay is on the other end decides whether a credential we issue
    // can be verified at all, and it is invisible from the URIs alone.
    logger.info('TURN configured', { scheme: turnScheme(config.turn) });
  }

  const ctx: AppContext = {
    config,
    repository,
    nonceStore,
    rateLimiter,
    logger,
    metrics: new Metrics(),
    apns: createApnsSender(config, logger),
    signaling: null,
    now: () => new Date(),
  };

  return {
    ctx,
    bus,
    close: async () => {
      await bus.close();
      await ctx.apns.close();
      await repository.close();
      if (redis !== null) {
        await redis.quit().catch(() => undefined);
      }
      if (subscriber !== null) {
        subscriber.disconnect();
      }
    },
  };
}
