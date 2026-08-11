/**
 * Signaling wire shapes — backend.md §3 "WebSocket".
 *
 * The client envelope is `{to, seq, blob}` and the server routes on `to` and
 * `seq` alone. `blob` is a sealed ChaCha20-Poly1305 message under `K_sig`: it
 * is measured (16 KiB message cap) and forwarded, never decoded, parsed, or
 * logged. Nothing in this file may grow a reader for it.
 */

import type { Device } from '../domain/types.ts';
import { isUuid } from '../domain/types.ts';

/** `camera` or `viewer:<deviceId>` — the only addresses that exist. */
export type Address = string;

export function addressOf(device: Device): Address {
  return device.role === 'camera' ? 'camera' : `viewer:${device.id}`;
}

export type Target =
  | { readonly kind: 'camera' }
  | { readonly kind: 'viewer'; readonly deviceId: string };

export function parseTarget(to: unknown): Target | null {
  if (typeof to !== 'string') return null;
  if (to === 'camera') return { kind: 'camera' };
  if (!to.startsWith('viewer:')) return null;
  const deviceId = to.slice('viewer:'.length);
  return isUuid(deviceId) ? { kind: 'viewer', deviceId } : null;
}

export interface ClientEnvelope {
  readonly to: Address;
  readonly seq: number;
  /** Opaque base64. Never decoded. */
  readonly blob: string;
}

export type EnvelopeParseError =
  | 'not_json'
  | 'not_an_object'
  | 'unexpected_field'
  | 'invalid_to'
  | 'invalid_seq'
  | 'invalid_blob';

export type EnvelopeParseResult =
  | { readonly ok: true; readonly envelope: ClientEnvelope }
  | { readonly ok: false; readonly code: EnvelopeParseError };

const ENVELOPE_FIELDS = ['to', 'seq', 'blob'] as const;
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/;

/**
 * Parses the routing envelope. `blob` is validated as base64 of a bounded
 * length — an encoding and size check, not an inspection of its contents.
 */
export function parseClientEnvelope(
  raw: string,
  maxBlobChars: number,
): EnvelopeParseResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, code: 'not_json' };
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { ok: false, code: 'not_an_object' };
  }
  const record = parsed as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (!ENVELOPE_FIELDS.includes(key as (typeof ENVELOPE_FIELDS)[number])) {
      return { ok: false, code: 'unexpected_field' };
    }
  }

  const to = record['to'];
  if (parseTarget(to) === null) return { ok: false, code: 'invalid_to' };

  const seq = record['seq'];
  if (typeof seq !== 'number' || !Number.isSafeInteger(seq) || seq < 0) {
    return { ok: false, code: 'invalid_seq' };
  }

  const blob = record['blob'];
  if (
    typeof blob !== 'string' ||
    blob.length === 0 ||
    blob.length > maxBlobChars ||
    !BASE64_RE.test(blob)
  ) {
    return { ok: false, code: 'invalid_blob' };
  }

  return { ok: true, envelope: { to: to as string, seq, blob } };
}

/** Frames the server sends. Every frame is tagged with `type`. */
export type ServerFrame =
  | {
      readonly type: 'ready';
      readonly self: Address;
      readonly pairingId: string;
      readonly heartbeatSeconds: number;
      readonly idleTimeoutSeconds: number;
      readonly maxMessageBytes: number;
    }
  | {
      readonly type: 'message';
      readonly from: Address;
      readonly to: Address;
      readonly seq: number;
      readonly blob: string;
    }
  | { readonly type: 'peer-online'; readonly peer: Address }
  | { readonly type: 'peer-offline'; readonly peer: Address }
  | {
      readonly type: 'error';
      readonly error: string;
      readonly message: string;
    };

export function encodeFrame(frame: ServerFrame): string {
  return JSON.stringify(frame);
}

/** Close codes used by the signaling endpoint. */
export const CLOSE_CODES = {
  normal: 1000,
  policyViolation: 1008,
  messageTooBig: 1009,
} as const;
