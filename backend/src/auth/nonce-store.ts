/**
 * Replay protection for `KidsCam-HMAC`.
 *
 * A MAC is deterministic in (method, path, timestamp, body), so recording
 * `(pairingId, mac)` for the length of the timestamp window is enough to make
 * every authenticated request single-use — an attacker who captures a request
 * cannot replay it, and after the window the timestamp check rejects it anyway.
 *
 * Redis-backed in production; the in-memory implementation keeps unit tests
 * runnable without a Redis instance (single-process only — it is not a
 * substitute for Redis across instances).
 */

import type { Redis } from 'ioredis';

export interface NonceStore {
  /**
   * Records `(pairingId, macHex)` and reports whether it was previously unseen.
   * Returns `true` for a fresh request, `false` for a replay.
   */
  checkAndRecord(
    pairingId: string,
    macHex: string,
    ttlSeconds: number,
  ): Promise<boolean>;
  close(): Promise<void>;
}

function nonceKey(pairingId: string, macHex: string): string {
  return `kidscam:nonce:${pairingId}:${macHex}`;
}

export class MemoryNonceStore implements NonceStore {
  readonly #seen = new Map<string, number>();

  checkAndRecord(
    pairingId: string,
    macHex: string,
    ttlSeconds: number,
  ): Promise<boolean> {
    const now = Date.now();
    this.#evictExpired(now);
    const key = nonceKey(pairingId, macHex);
    const expiresAt = this.#seen.get(key);
    if (expiresAt !== undefined && expiresAt > now) {
      return Promise.resolve(false);
    }
    this.#seen.set(key, now + ttlSeconds * 1000);
    return Promise.resolve(true);
  }

  close(): Promise<void> {
    this.#seen.clear();
    return Promise.resolve();
  }

  #evictExpired(now: number): void {
    for (const [key, expiresAt] of this.#seen) {
      if (expiresAt <= now) this.#seen.delete(key);
    }
  }
}

export class RedisNonceStore implements NonceStore {
  readonly #redis: Redis;

  constructor(redis: Redis) {
    this.#redis = redis;
  }

  async checkAndRecord(
    pairingId: string,
    macHex: string,
    ttlSeconds: number,
  ): Promise<boolean> {
    const result = await this.#redis.set(
      nonceKey(pairingId, macHex),
      '1',
      'EX',
      Math.max(1, Math.ceil(ttlSeconds)),
      'NX',
    );
    return result === 'OK';
  }

  async close(): Promise<void> {
    await this.#redis.quit();
  }
}
