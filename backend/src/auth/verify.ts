/**
 * Transport-independent verification of a `CribWire-HMAC` request, so the same
 * code path serves REST and the WebSocket upgrade.
 *
 * Verification answers one question only: *which principal signed this?* The
 * caller's authority (camera or viewer) is never taken from the wire — routes
 * read the role from the device row the principal resolves to.
 */

import type { NonceStore } from './nonce-store.ts';
import type { AuthHeaderParts } from './canonical.ts';
import {
  bodySha256Hex,
  canonicalString,
  computeMac,
  macsEqual,
  parseAuthHeader,
} from './canonical.ts';

export type AuthFailureCode =
  | 'missing_authorization'
  | 'malformed_authorization'
  | 'timestamp_out_of_window'
  | 'unknown_principal'
  | 'invalid_signature'
  | 'replayed_request';

export interface AuthContext {
  readonly pairingId: string;
  /** `bootstrap`, or the authenticated device's UUID. */
  readonly principal: string;
  readonly timestamp: number;
  readonly macHex: string;
}

export type VerifyResult =
  | { readonly ok: true; readonly auth: AuthContext }
  | { readonly ok: false; readonly code: AuthFailureCode };

/**
 * Resolves the signing key for a (pairing, principal) pair, or `null` when no
 * such credential exists — an unknown pairing, an unknown device, and a
 * revoked pairing are deliberately indistinguishable to the caller.
 *
 * `POST /v1/pairings` passes a resolver that returns the key carried in the
 * request body (see `routes/pairings.ts`).
 */
export type KeyResolver = (parts: AuthHeaderParts) => Promise<Buffer | null>;

export interface VerifyRequestInput {
  readonly method: string;
  /** Path only — no scheme, host, or query string (protocol.md). */
  readonly path: string;
  readonly authorization: string | undefined;
  readonly rawBody: Buffer;
  readonly resolveKey: KeyResolver;
  readonly nonceStore: NonceStore;
  /** Accepted clock skew, in seconds, in both directions. */
  readonly windowSeconds: number;
  readonly nowMs: number;
}

export async function verifyRequest(
  input: VerifyRequestInput,
): Promise<VerifyResult> {
  if (input.authorization === undefined || input.authorization === '') {
    return { ok: false, code: 'missing_authorization' };
  }

  const parts = parseAuthHeader(input.authorization);
  if (parts === null) {
    return { ok: false, code: 'malformed_authorization' };
  }

  const timestamp = Number.parseInt(parts.timestamp, 10);
  if (!Number.isSafeInteger(timestamp)) {
    return { ok: false, code: 'malformed_authorization' };
  }
  const skewSeconds = Math.abs(input.nowMs / 1000 - timestamp);
  if (skewSeconds > input.windowSeconds) {
    return { ok: false, code: 'timestamp_out_of_window' };
  }

  const key = await input.resolveKey(parts);
  if (key === null) {
    return { ok: false, code: 'unknown_principal' };
  }

  const canonical = canonicalString(
    input.method,
    input.path,
    parts.timestamp,
    parts.principal,
    bodySha256Hex(input.rawBody),
  );
  if (!macsEqual(computeMac(key, canonical), parts.macHex)) {
    return { ok: false, code: 'invalid_signature' };
  }

  // Only MAC-valid requests may write to the replay cache, so an attacker
  // cannot poison it with guessed MACs.
  const fresh = await input.nonceStore.checkAndRecord(
    parts.pairingId,
    parts.macHex,
    input.windowSeconds * 2,
  );
  if (!fresh) {
    return { ok: false, code: 'replayed_request' };
  }

  return {
    ok: true,
    auth: {
      pairingId: parts.pairingId,
      principal: parts.principal,
      timestamp,
      macHex: parts.macHex,
    },
  };
}
