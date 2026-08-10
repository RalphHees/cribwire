/**
 * `KidsCam-HMAC` wire format — normative definition in `shared/protocol.md`
 * (revision 1.1), fixtures in `shared/test-vectors/kidscam-v1.json`. This
 * module is cross-implemented by the iOS app; any change here needs
 * regenerated vectors and a matching change on the iOS side.
 *
 *   canonical = METHOD \n PATH \n TIMESTAMP \n PRINCIPAL \n hex(SHA-256(body))
 *   mac       = lowercase-hex(HMAC-SHA256(key, canonical))
 *   header    = Authorization: KidsCam-HMAC <pairingId>:<principal>:<ts>:<mac>
 *
 * `PRINCIPAL` is the literal `bootstrap` for the two calls that establish a
 * device (signed with `K_auth`), and the calling device's UUID for every other
 * request (signed with that device's own key). The role is *not* on the wire:
 * the server reads it from the authenticated device row.
 */

import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import { isUuid } from '../domain/types.ts';

export const AUTH_SCHEME = 'KidsCam-HMAC';

/** The principal of the two `K_auth`-authenticated bootstrap calls. */
export const BOOTSTRAP_PRINCIPAL = 'bootstrap';

/** Lowercase hex SHA-256 of the raw body; an absent body hashes as empty. */
export function bodySha256Hex(body: Buffer | string | undefined): string {
  return createHash('sha256')
    .update(body ?? Buffer.alloc(0))
    .digest('hex');
}

export function canonicalString(
  method: string,
  path: string,
  timestamp: string,
  principal: string,
  bodyHashHex: string,
): string {
  return `${method.toUpperCase()}\n${path}\n${timestamp}\n${principal}\n${bodyHashHex}`;
}

export function computeMac(key: Buffer, canonical: string): string {
  return createHmac('sha256', key).update(canonical, 'utf8').digest('hex');
}

/**
 * Constant-time MAC comparison. Both operands are lowercase hex of a fixed
 * length, so a length mismatch is a malformed MAC rather than a secret leak.
 */
export function macsEqual(expectedHex: string, providedHex: string): boolean {
  const expected = Buffer.from(expectedHex, 'utf8');
  const provided = Buffer.from(providedHex, 'utf8');
  if (expected.length !== provided.length) return false;
  return timingSafeEqual(expected, provided);
}

export interface AuthHeaderParts {
  readonly pairingId: string;
  /** `bootstrap`, or the calling device's UUID. */
  readonly principal: string;
  readonly timestamp: string;
  readonly macHex: string;
}

const MAC_RE = /^[0-9a-f]{64}$/;
const TIMESTAMP_RE = /^[0-9]{1,15}$/;

export function isBootstrapPrincipal(principal: string): boolean {
  return principal === BOOTSTRAP_PRINCIPAL;
}

/** The device id a principal names, or `null` for the bootstrap principal. */
export function devicePrincipalId(principal: string): string | null {
  return isUuid(principal) ? principal : null;
}

/**
 * Parses `KidsCam-HMAC <pairingId>:<principal>:<timestamp>:<mac>`.
 * Returns `null` for anything that does not match the pinned shape.
 */
export function parseAuthHeader(
  header: string | undefined,
): AuthHeaderParts | null {
  if (typeof header !== 'string') return null;
  const separator = header.indexOf(' ');
  if (separator < 0) return null;
  if (header.slice(0, separator) !== AUTH_SCHEME) return null;

  const parts = header.slice(separator + 1).split(':');
  if (parts.length !== 4) return null;
  const [pairingId, principal, timestamp, macHex] = parts;

  if (!isUuid(pairingId)) return null;
  if (principal === undefined) return null;
  // A principal is either the bootstrap literal or a device UUID; nothing else
  // (in particular, no role name) is accepted.
  if (!isBootstrapPrincipal(principal) && !isUuid(principal)) return null;
  if (timestamp === undefined || !TIMESTAMP_RE.test(timestamp)) return null;
  if (macHex === undefined || !MAC_RE.test(macHex)) return null;

  return { pairingId, principal, timestamp, macHex };
}

/** Builds the header value. Used by tests and by the iOS-facing docs. */
export function buildAuthHeader(parts: AuthHeaderParts): string {
  return `${AUTH_SCHEME} ${parts.pairingId}:${parts.principal}:${parts.timestamp}:${parts.macHex}`;
}
