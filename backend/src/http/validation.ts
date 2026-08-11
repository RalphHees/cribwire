/**
 * Request body validation, conforming to the shapes pinned in
 * `shared/protocol.md` §"REST bodies".
 *
 * Only the routing envelope is ever validated — sizes, shapes, and encodings.
 * Nothing here inspects ciphertext (backend.md §1, security.md §4): the event
 * `ciphertext` is checked for base64-ness and length and is otherwise opaque.
 *
 * Unknown request fields are rejected (protocol.md): a client that sends a
 * field this server does not know is running a different contract, and
 * silently ignoring it would hide the drift.
 */

import type { ApnsEnvironment } from '../domain/types.ts';
import { isApnsEnvironment, isUuid } from '../domain/types.ts';

export type ParseResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

/** `K_auth` is an HKDF-SHA256 output: exactly 32 bytes (protocol.md). */
export const K_AUTH_BYTES = 32;

/** A device key is 32 random bytes generated on-device (protocol.md 1.1). */
export const DEVICE_KEY_BYTES = 32;

/**
 * Upper bound on a sealed event envelope. The plaintext is a tiny JSON
 * document; 4 KiB of base64 leaves room for schema growth while keeping the
 * push payload well inside the 4 KiB APNs limit. The bytes themselves are
 * never inspected.
 */
export const MAX_CIPHERTEXT_BASE64_CHARS = 4096;

/** Sealed envelope floor: 12-byte nonce + 16-byte tag, base64-encoded. */
const MIN_CIPHERTEXT_BASE64_CHARS = 40;

/** APNs device tokens are lowercase/uppercase hex; 32 bytes today, bounded here. */
const APNS_TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function asRecord(body: unknown): Record<string, unknown> | null {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return null;
  }
  return body as Record<string, unknown>;
}

/** Rejects any field the pinned body shape does not define. */
function rejectUnknownFields(
  record: Record<string, unknown>,
  allowed: readonly string[],
): string | null {
  for (const key of Object.keys(record)) {
    if (!allowed.includes(key)) return `unexpected field "${key}"`;
  }
  return null;
}

function parseBase64Key(value: unknown, bytes: number): Buffer | null {
  if (typeof value !== 'string' || value.length === 0) return null;
  let decoded: Buffer;
  try {
    decoded = Buffer.from(value, 'base64');
  } catch {
    return null;
  }
  if (decoded.length !== bytes) return null;
  // Reject non-canonical base64 (trailing garbage is silently dropped by
  // Buffer.from), so the iOS and backend encodings cannot drift.
  if (decoded.toString('base64') !== value) return null;
  return decoded;
}

export interface ApnsRegistration {
  readonly apnsToken: string;
  readonly apnsEnvironment: ApnsEnvironment;
}

function parseApnsFields(
  record: Record<string, unknown>,
): ParseResult<ApnsRegistration> {
  const apnsToken = record['apnsToken'];
  if (typeof apnsToken !== 'string' || !APNS_TOKEN_RE.test(apnsToken)) {
    return { ok: false, message: 'apnsToken must be a hex APNs device token' };
  }
  const apnsEnvironment = record['apnsEnvironment'];
  if (!isApnsEnvironment(apnsEnvironment)) {
    return {
      ok: false,
      message: 'apnsEnvironment must be "sandbox" or "production"',
    };
  }
  return { ok: true, value: { apnsToken, apnsEnvironment } };
}

function parseDeviceKey(record: Record<string, unknown>): Buffer | null {
  return parseBase64Key(record['deviceKey'], DEVICE_KEY_BYTES);
}

export interface CreatePairingBody extends ApnsRegistration {
  readonly pairingId: string;
  readonly kAuth: Buffer;
  readonly deviceKey: Buffer;
}

const CREATE_PAIRING_FIELDS = [
  'pairingId',
  'kAuth',
  'deviceKey',
  'apnsToken',
  'apnsEnvironment',
] as const;

export function parseCreatePairingBody(
  body: unknown,
): ParseResult<CreatePairingBody> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

  const unknown = rejectUnknownFields(record, CREATE_PAIRING_FIELDS);
  if (unknown !== null) return { ok: false, message: unknown };

  const pairingId = record['pairingId'];
  if (!isUuid(pairingId)) {
    return { ok: false, message: 'pairingId must be a lowercase UUID' };
  }

  const kAuth = parseBase64Key(record['kAuth'], K_AUTH_BYTES);
  if (kAuth === null) {
    return {
      ok: false,
      message: `kAuth must be base64 of exactly ${K_AUTH_BYTES} bytes`,
    };
  }

  const deviceKey = parseDeviceKey(record);
  if (deviceKey === null) {
    return {
      ok: false,
      message: `deviceKey must be base64 of exactly ${DEVICE_KEY_BYTES} bytes`,
    };
  }

  const apns = parseApnsFields(record);
  if (!apns.ok) return apns;

  return { ok: true, value: { pairingId, kAuth, deviceKey, ...apns.value } };
}

export interface ClaimBody extends ApnsRegistration {
  readonly deviceKey: Buffer;
}

const CLAIM_FIELDS = ['deviceKey', 'apnsToken', 'apnsEnvironment'] as const;

export function parseClaimBody(body: unknown): ParseResult<ClaimBody> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

  const unknown = rejectUnknownFields(record, CLAIM_FIELDS);
  if (unknown !== null) return { ok: false, message: unknown };

  const deviceKey = parseDeviceKey(record);
  if (deviceKey === null) {
    return {
      ok: false,
      message: `deviceKey must be base64 of exactly ${DEVICE_KEY_BYTES} bytes`,
    };
  }

  const apns = parseApnsFields(record);
  if (!apns.ok) return apns;

  return { ok: true, value: { deviceKey, ...apns.value } };
}

const UPDATE_TOKEN_FIELDS = ['apnsToken', 'apnsEnvironment'] as const;

/**
 * `PUT /v1/devices/token`. The device is the authenticated principal, so the
 * body carries no `deviceId` (protocol.md 1.1).
 */
export function parseUpdateTokenBody(
  body: unknown,
): ParseResult<ApnsRegistration> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

  const unknown = rejectUnknownFields(record, UPDATE_TOKEN_FIELDS);
  if (unknown !== null) return { ok: false, message: unknown };

  return parseApnsFields(record);
}

export interface EventBody {
  /**
   * The sealed event envelope, verbatim. Never decoded, never decrypted, never
   * parsed — only measured and forwarded (backend.md §1).
   */
  readonly ciphertext: string;
}

const EVENT_FIELDS = ['ciphertext'] as const;

export function parseEventBody(body: unknown): ParseResult<EventBody> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

  const unknown = rejectUnknownFields(record, EVENT_FIELDS);
  if (unknown !== null) return { ok: false, message: unknown };

  const ciphertext = record['ciphertext'];
  if (
    typeof ciphertext !== 'string' ||
    ciphertext.length < MIN_CIPHERTEXT_BASE64_CHARS ||
    ciphertext.length > MAX_CIPHERTEXT_BASE64_CHARS ||
    !BASE64_RE.test(ciphertext)
  ) {
    return {
      ok: false,
      message: `ciphertext must be a base64 sealed envelope of at most ${MAX_CIPHERTEXT_BASE64_CHARS} characters`,
    };
  }

  return { ok: true, value: { ciphertext } };
}
