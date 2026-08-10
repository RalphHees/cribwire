/**
 * `KidsCam-HMAC` wire format — normative definition in `shared/protocol.md`,
 * fixtures in `shared/test-vectors/kidscam-v1.json`. This module is
 * cross-implemented by the iOS app; any change here needs regenerated vectors
 * and a matching change on the iOS side.
 *
 *   canonical = METHOD \n PATH \n TIMESTAMP \n lowercase-hex(SHA-256(body))
 *   mac       = lowercase-hex(HMAC-SHA256(K_auth, canonical))
 *   header    = Authorization: KidsCam-HMAC <pairingId>:<role>:<timestamp>:<mac>
 */

import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { Role } from '../domain/types.ts';
import { isRole, isUuid } from '../domain/types.ts';

export const AUTH_SCHEME = 'KidsCam-HMAC';

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
  bodyHashHex: string,
): string {
  return `${method.toUpperCase()}\n${path}\n${timestamp}\n${bodyHashHex}`;
}

export function computeMac(kAuth: Buffer, canonical: string): string {
  return createHmac('sha256', kAuth).update(canonical, 'utf8').digest('hex');
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
  readonly role: Role;
  readonly timestamp: string;
  readonly macHex: string;
}

const MAC_RE = /^[0-9a-f]{64}$/;
const TIMESTAMP_RE = /^[0-9]{1,15}$/;

/**
 * Parses `KidsCam-HMAC <pairingId>:<role>:<timestamp>:<mac>`.
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
  const [pairingId, role, timestamp, macHex] = parts;

  if (!isUuid(pairingId)) return null;
  if (!isRole(role)) return null;
  if (timestamp === undefined || !TIMESTAMP_RE.test(timestamp)) return null;
  if (macHex === undefined || !MAC_RE.test(macHex)) return null;

  return { pairingId, role, timestamp, macHex };
}

/** Builds the header value. Used by tests and by the iOS-facing docs. */
export function buildAuthHeader(parts: AuthHeaderParts): string {
  return `${AUTH_SCHEME} ${parts.pairingId}:${parts.role}:${parts.timestamp}:${parts.macHex}`;
}
