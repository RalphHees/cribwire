/**
 * Ephemeral TURN credentials — backend.md §4, shape pinned in protocol.md.
 *
 *   username   = <expiry-unix>:<pairingId>
 *   credential = base64(HMAC-SHA1(turn_shared_secret, username))
 *
 * This is coturn's `use-auth-secret` (REST API) mode: coturn recomputes the
 * same HMAC from the shared secret, so no credential is ever stored, and the
 * username's expiry bounds its lifetime. TURN sees SRTP ciphertext only.
 */

import { createHmac } from 'node:crypto';

export interface TurnConfig {
  /** Shared secret, also configured in coturn. Never logged, never returned. */
  readonly sharedSecret: string;
  readonly ttlSeconds: number;
  readonly uris: readonly string[];
}

export interface TurnCredentials {
  readonly username: string;
  readonly credential: string;
  readonly ttlSeconds: number;
  readonly uris: readonly string[];
}

export function issueTurnCredentials(
  config: TurnConfig,
  pairingId: string,
  now: Date,
): TurnCredentials {
  const expiry = Math.floor(now.getTime() / 1000) + config.ttlSeconds;
  const username = `${expiry}:${pairingId}`;
  const credential = createHmac('sha1', config.sharedSecret)
    .update(username, 'utf8')
    .digest('base64');
  return {
    username,
    credential,
    ttlSeconds: config.ttlSeconds,
    uris: config.uris,
  };
}
