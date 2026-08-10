/**
 * Integration tests against a real Redis (docker-compose).
 * Skipped automatically when Redis is unreachable.
 */

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { RedisNonceStore } from '../../src/auth/nonce-store.ts';
import { RedisRateLimiter } from '../../src/ratelimit/token-bucket.ts';
import type { RateLimitRule } from '../../src/config.ts';
import { createTestRedis, redisAvailable } from '../helpers/services.ts';

const available = await redisAvailable();

describe.skipIf(!available)('Redis-backed stores', () => {
  let redis: Redis;

  beforeAll(async () => {
    redis = createTestRedis();
    await redis.connect();
  });

  afterAll(async () => {
    await redis.quit().catch(() => undefined);
  });

  beforeEach(async () => {
    await redis.flushdb();
  });

  describe('RedisNonceStore', () => {
    it('accepts a nonce once and rejects the replay', async () => {
      const store = new RedisNonceStore(redis);
      const pairingId = randomUUID();
      const mac = 'a'.repeat(64);

      expect(await store.checkAndRecord(pairingId, mac, 120)).toBe(true);
      expect(await store.checkAndRecord(pairingId, mac, 120)).toBe(false);
    });

    it('scopes nonces per pairing', async () => {
      const store = new RedisNonceStore(redis);
      const mac = 'b'.repeat(64);
      expect(await store.checkAndRecord(randomUUID(), mac, 120)).toBe(true);
      expect(await store.checkAndRecord(randomUUID(), mac, 120)).toBe(true);
    });

    it('expires entries after the TTL', async () => {
      const store = new RedisNonceStore(redis);
      const pairingId = randomUUID();
      const mac = 'c'.repeat(64);
      expect(await store.checkAndRecord(pairingId, mac, 1)).toBe(true);
      const ttl = await redis.ttl(`kidscam:nonce:${pairingId}:${mac}`);
      expect(ttl).toBeGreaterThan(0);
      expect(ttl).toBeLessThanOrEqual(1);
    });
  });

  describe('RedisRateLimiter', () => {
    const rule: RateLimitRule = { capacity: 3, refillPerSecond: 1 / 60 };

    it('allows a burst up to capacity and then rejects', async () => {
      const limiter = new RedisRateLimiter(redis, () => 1_000_000);
      const key = `test:${randomUUID()}`;
      for (let i = 0; i < rule.capacity; i += 1) {
        expect((await limiter.consume(key, rule)).allowed, `request ${i}`).toBe(
          true,
        );
      }
      const rejected = await limiter.consume(key, rule);
      expect(rejected.allowed).toBe(false);
      expect(rejected.retryAfterSeconds).toBeGreaterThan(0);
    });

    it('refills over time', async () => {
      let now = 1_000_000;
      const limiter = new RedisRateLimiter(redis, () => now);
      const key = `test:${randomUUID()}`;
      for (let i = 0; i < rule.capacity; i += 1) {
        await limiter.consume(key, rule);
      }
      expect((await limiter.consume(key, rule)).allowed).toBe(false);

      now += 60_000;
      expect((await limiter.consume(key, rule)).allowed).toBe(true);
      expect((await limiter.consume(key, rule)).allowed).toBe(false);
    });

    it('shares a bucket across limiter instances (cross-instance limits)', async () => {
      const key = `test:${randomUUID()}`;
      const first = new RedisRateLimiter(redis, () => 1_000_000);
      const second = new RedisRateLimiter(redis, () => 1_000_000);
      for (let i = 0; i < rule.capacity; i += 1) {
        expect((await first.consume(key, rule)).allowed).toBe(true);
      }
      expect((await second.consume(key, rule)).allowed).toBe(false);
    });
  });
});
