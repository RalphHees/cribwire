/**
 * Token-bucket rate limiting (backend.md §6): per-IP and per-pairing.
 *
 * Redis-backed so limits hold across instances; the in-memory implementation
 * keeps unit tests runnable without Redis (single-process only).
 */

import type { Redis } from 'ioredis';
import type { RateLimitRule } from '../config.ts';

export interface RateLimitResult {
  readonly allowed: boolean;
  /** Seconds until one token is available again; 0 when allowed. */
  readonly retryAfterSeconds: number;
}

export interface RateLimiter {
  consume(key: string, rule: RateLimitRule): Promise<RateLimitResult>;
  close(): Promise<void>;
}

const ALLOWED: RateLimitResult = { allowed: true, retryAfterSeconds: 0 };

function bucketKey(key: string): string {
  return `cribwire:rl:${key}`;
}

/** TTL after which an untouched, full bucket can be forgotten. */
function bucketTtlSeconds(rule: RateLimitRule): number {
  return Math.max(60, Math.ceil(rule.capacity / rule.refillPerSecond) + 60);
}

interface BucketState {
  tokens: number;
  updatedAtMs: number;
}

export class MemoryRateLimiter implements RateLimiter {
  readonly #buckets = new Map<string, BucketState>();
  readonly #now: () => number;

  constructor(now: () => number = Date.now) {
    this.#now = now;
  }

  consume(key: string, rule: RateLimitRule): Promise<RateLimitResult> {
    const now = this.#now();
    const state = this.#buckets.get(key) ?? {
      tokens: rule.capacity,
      updatedAtMs: now,
    };
    const elapsedSeconds = Math.max(0, (now - state.updatedAtMs) / 1000);
    const tokens = Math.min(
      rule.capacity,
      state.tokens + elapsedSeconds * rule.refillPerSecond,
    );

    if (tokens < 1) {
      this.#buckets.set(key, { tokens, updatedAtMs: now });
      return Promise.resolve({
        allowed: false,
        retryAfterSeconds: Math.ceil((1 - tokens) / rule.refillPerSecond),
      });
    }

    this.#buckets.set(key, { tokens: tokens - 1, updatedAtMs: now });
    return Promise.resolve(ALLOWED);
  }

  close(): Promise<void> {
    this.#buckets.clear();
    return Promise.resolve();
  }
}

/**
 * Atomic refill-and-consume. Returning `-1` means "allowed"; a non-negative
 * value is the retry-after in seconds.
 */
const CONSUME_SCRIPT = `
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill = tonumber(ARGV[2])
local nowMs = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

local state = redis.call('HMGET', key, 'tokens', 'updated')
local tokens = tonumber(state[1])
local updated = tonumber(state[2])
if tokens == nil or updated == nil then
  tokens = capacity
  updated = nowMs
end

local elapsed = math.max(0, (nowMs - updated) / 1000)
tokens = math.min(capacity, tokens + elapsed * refill)

local retryAfter = -1
if tokens < 1 then
  retryAfter = math.ceil((1 - tokens) / refill)
else
  tokens = tokens - 1
end

redis.call('HSET', key, 'tokens', tokens, 'updated', nowMs)
redis.call('EXPIRE', key, ttl)
return retryAfter
`;

export class RedisRateLimiter implements RateLimiter {
  readonly #redis: Redis;
  readonly #now: () => number;

  constructor(redis: Redis, now: () => number = Date.now) {
    this.#redis = redis;
    this.#now = now;
  }

  async consume(key: string, rule: RateLimitRule): Promise<RateLimitResult> {
    const raw = await this.#redis.eval(
      CONSUME_SCRIPT,
      1,
      bucketKey(key),
      String(rule.capacity),
      String(rule.refillPerSecond),
      String(this.#now()),
      String(bucketTtlSeconds(rule)),
    );
    const retryAfter = Number(raw);
    if (retryAfter < 0) return ALLOWED;
    return { allowed: false, retryAfterSeconds: retryAfter };
  }

  async close(): Promise<void> {
    await this.#redis.quit();
  }
}
