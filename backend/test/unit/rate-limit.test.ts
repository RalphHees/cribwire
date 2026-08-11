import { describe, expect, it } from 'vitest';
import type { RateLimitRule } from '../../src/config.ts';
import { MemoryRateLimiter } from '../../src/ratelimit/token-bucket.ts';

const RULE: RateLimitRule = { capacity: 3, refillPerSecond: 1 / 60 };

describe('MemoryRateLimiter', () => {
  it('allows a burst up to the capacity and then rejects', async () => {
    const now = 1_000_000;
    const limiter = new MemoryRateLimiter(() => now);

    for (let i = 0; i < RULE.capacity; i += 1) {
      const result = await limiter.consume('ip:1.2.3.4', RULE);
      expect(result.allowed, `request ${i}`).toBe(true);
    }

    const rejected = await limiter.consume('ip:1.2.3.4', RULE);
    expect(rejected.allowed).toBe(false);
    expect(rejected.retryAfterSeconds).toBeGreaterThan(0);
  });

  it('refills over time', async () => {
    let now = 1_000_000;
    const limiter = new MemoryRateLimiter(() => now);
    for (let i = 0; i < RULE.capacity; i += 1) {
      await limiter.consume('k', RULE);
    }
    expect((await limiter.consume('k', RULE)).allowed).toBe(false);

    now += 60_000;
    expect((await limiter.consume('k', RULE)).allowed).toBe(true);
    expect((await limiter.consume('k', RULE)).allowed).toBe(false);
  });

  it('never refills past the capacity', async () => {
    let now = 1_000_000;
    const limiter = new MemoryRateLimiter(() => now);
    await limiter.consume('k', RULE);
    now += 3_600_000;
    for (let i = 0; i < RULE.capacity; i += 1) {
      expect((await limiter.consume('k', RULE)).allowed).toBe(true);
    }
    expect((await limiter.consume('k', RULE)).allowed).toBe(false);
  });

  it('keeps buckets independent per key', async () => {
    const limiter = new MemoryRateLimiter(() => 1_000_000);
    for (let i = 0; i < RULE.capacity; i += 1) {
      await limiter.consume('a', RULE);
    }
    expect((await limiter.consume('a', RULE)).allowed).toBe(false);
    expect((await limiter.consume('b', RULE)).allowed).toBe(true);
  });
});
