/**
 * Request body validation.
 *
 * Only the routing envelope is ever validated — sizes, shapes, and encodings.
 * Nothing here inspects ciphertext (backend.md §1, security.md §4).
 */

import type { ApnsEnvironment } from '../domain/types.ts';
import { isApnsEnvironment, isUuid } from '../domain/types.ts';

export type ParseResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

/** `K_auth` is an HKDF-SHA256 output: exactly 32 bytes (protocol.md). */
export const K_AUTH_BYTES = 32;

/** APNs device tokens are lowercase/uppercase hex; 32 bytes today, bounded here. */
const APNS_TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

function asRecord(body: unknown): Record<string, unknown> | null {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    return null;
  }
  return body as Record<string, unknown>;
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

export interface CreatePairingBody extends ApnsRegistration {
  readonly pairingId: string;
  readonly kAuth: Buffer;
}

export function parseCreatePairingBody(
  body: unknown,
): ParseResult<CreatePairingBody> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

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

  const apns = parseApnsFields(record);
  if (!apns.ok) return apns;

  return { ok: true, value: { pairingId, kAuth, ...apns.value } };
}

export function parseClaimBody(body: unknown): ParseResult<ApnsRegistration> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };
  return parseApnsFields(record);
}

export interface UpdateTokenBody extends ApnsRegistration {
  readonly deviceId: string;
}

export function parseUpdateTokenBody(
  body: unknown,
): ParseResult<UpdateTokenBody> {
  const record = asRecord(body);
  if (record === null) return { ok: false, message: 'body must be an object' };

  const deviceId = record['deviceId'];
  if (!isUuid(deviceId)) {
    return { ok: false, message: 'deviceId must be a lowercase UUID' };
  }

  const apns = parseApnsFields(record);
  if (!apns.ok) return apns;

  return { ok: true, value: { deviceId, ...apns.value } };
}
