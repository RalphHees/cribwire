/**
 * Integration tests against a real Redis (docker-compose).
 * Skipped automatically when Redis is unreachable.
 */

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Redis } from 'ioredis';
import { randomUUID } from 'node:crypto';
import { randomBytes } from 'node:crypto';
import { RedisNonceStore } from '../../src/auth/nonce-store.ts';
import { RedisMessageBus, channelFor } from '../../src/ws/bus.ts';
import type { BusMessage } from '../../src/ws/bus.ts';
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

  describe('RedisMessageBus', () => {
    /**
     * Two buses on separate connections stand in for two API instances: this
     * is the bridge that lets a camera on one instance reach a viewer on
     * another.
     */
    async function createBus(): Promise<{
      bus: RedisMessageBus;
      received: { pairingId: string; message: BusMessage }[];
      close: () => Promise<void>;
    }> {
      const publisher = createTestRedis();
      const subscriber = createTestRedis();
      await publisher.connect();
      await subscriber.connect();
      const bus = new RedisMessageBus(publisher, subscriber);
      const received: { pairingId: string; message: BusMessage }[] = [];
      bus.setHandler((pairingId, message) => {
        received.push({ pairingId, message });
      });
      return {
        bus,
        received,
        close: async () => {
          await bus.close();
          publisher.disconnect();
          subscriber.disconnect();
        },
      };
    }

    async function settle(): Promise<void> {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }

    it('delivers an envelope to another instance, blob untouched', async () => {
      const instanceA = await createBus();
      const instanceB = await createBus();
      const pairingId = randomUUID();
      const blob = randomBytes(64).toString('base64');

      await instanceB.bus.subscribe(pairingId);
      await instanceA.bus.publish(pairingId, {
        kind: 'envelope',
        from: 'camera',
        to: 'viewer:9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
        seq: 3,
        blob,
      });
      await settle();

      expect(instanceB.received).toEqual([
        {
          pairingId,
          message: {
            kind: 'envelope',
            from: 'camera',
            to: 'viewer:9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
            seq: 3,
            blob,
          },
        },
      ]);

      await instanceA.close();
      await instanceB.close();
    });

    it('delivers presence and directed presence', async () => {
      const instance = await createBus();
      const pairingId = randomUUID();
      await instance.bus.subscribe(pairingId);

      await instance.bus.publish(pairingId, {
        kind: 'presence',
        event: 'peer-online',
        peer: 'camera',
      });
      await instance.bus.publish(pairingId, {
        kind: 'presence',
        event: 'peer-online',
        peer: 'camera',
        to: 'viewer:9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
      });
      await settle();

      expect(instance.received.map((entry) => entry.message)).toEqual([
        { kind: 'presence', event: 'peer-online', peer: 'camera' },
        {
          kind: 'presence',
          event: 'peer-online',
          peer: 'camera',
          to: 'viewer:9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
        },
      ]);
      await instance.close();
    });

    it('delivers nothing for a pairing it did not subscribe to', async () => {
      const instance = await createBus();
      await instance.bus.subscribe(randomUUID());
      await instance.bus.publish(randomUUID(), {
        kind: 'presence',
        event: 'peer-offline',
        peer: 'camera',
      });
      await settle();
      expect(instance.received).toHaveLength(0);
      await instance.close();
    });

    it('stops delivering after unsubscribe', async () => {
      const instance = await createBus();
      const pairingId = randomUUID();
      await instance.bus.subscribe(pairingId);
      await instance.bus.unsubscribe(pairingId);
      await instance.bus.publish(pairingId, {
        kind: 'presence',
        event: 'peer-online',
        peer: 'camera',
      });
      await settle();
      expect(instance.received).toHaveLength(0);
      await instance.close();
    });

    it('ignores traffic that is not a bus message', async () => {
      const instance = await createBus();
      const pairingId = randomUUID();
      await instance.bus.subscribe(pairingId);
      await redis.publish(channelFor(pairingId), 'not json');
      await redis.publish(channelFor(pairingId), '{"kind":"other"}');
      await settle();
      expect(instance.received).toHaveLength(0);
      await instance.close();
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
