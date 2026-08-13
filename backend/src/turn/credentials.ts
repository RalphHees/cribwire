/**
 * TURN credentials handed to a paired device — backend.md §4, shape pinned in
 * protocol.md. Two relay flavours produce the same response body:
 *
 *   coturn (`use-auth-secret`), the relay we run ourselves:
 *     username   = <expiry-unix>:<pairingId>
 *     credential = base64(HMAC-SHA1(turn_shared_secret, username))
 *   coturn recomputes that HMAC from the shared secret, so no credential is
 *   ever stored and the username's expiry bounds its lifetime.
 *
 *   A hosted relay (metered.ca and the like), which issued its own pair:
 *     username   = TURN_STATIC_USERNAME
 *     credential = TURN_STATIC_CREDENTIAL
 *   It shares no secret with us and cannot recompute anything, so its pair is
 *   passed through unchanged. The credential is only as scoped as the relay
 *   made it — see the note on `ttlSeconds` below.
 *
 * Either way TURN sees SRTP ciphertext only.
 */

import { createHmac } from 'node:crypto';
import type { TurnSettings } from '../config.ts';
import { turnScheme } from '../config.ts';

export type TurnConfig = TurnSettings;

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
  if (turnScheme(config) === 'static') {
    return {
      username: config.staticUsername,
      credential: config.staticCredential,
      // Not an expiry the relay agreed to — a hosted pair lives as long as the
      // provider says it does, and the API is told nothing about that. It is
      // how long a client may cache this answer before asking again, which is
      // what makes rotating the pair take effect within one TTL.
      ttlSeconds: config.ttlSeconds,
      uris: config.uris,
    };
  }

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
