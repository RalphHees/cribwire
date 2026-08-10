/** Abuse cases for `KidsCam-HMAC` verification. */

import { describe, expect, it } from 'vitest';
import { randomBytes } from 'node:crypto';
import {
  bodySha256Hex,
  buildAuthHeader,
  canonicalString,
  computeMac,
  macsEqual,
  parseAuthHeader,
} from '../../src/auth/canonical.ts';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import type { VerifyRequestInput } from '../../src/auth/verify.ts';
import { verifyRequest } from '../../src/auth/verify.ts';
import { loadVectors, vectorKAuth } from '../helpers/vectors.ts';

const vectors = loadVectors();
const kAuth = vectorKAuth(vectors);
const pairingId = vectors.requestAuth.pairingId;
const TIMESTAMP = 1_754_850_000;

function signedInput(
  overrides: Partial<VerifyRequestInput> & {
    method?: string;
    path?: string;
    body?: string;
    role?: 'camera' | 'viewer';
    timestamp?: number;
    signingKey?: Buffer;
  } = {},
): VerifyRequestInput {
  const method = overrides.method ?? 'POST';
  const path = overrides.path ?? `/v1/pairings/${pairingId}/claim`;
  const body = overrides.body ?? '{"apnsToken":"aa"}';
  const timestamp = String(overrides.timestamp ?? TIMESTAMP);
  const macHex = computeMac(
    overrides.signingKey ?? kAuth,
    canonicalString(method, path, timestamp, bodySha256Hex(body)),
  );

  return {
    method,
    path,
    authorization: buildAuthHeader({
      pairingId,
      role: overrides.role ?? 'viewer',
      timestamp,
      macHex,
    }),
    rawBody: Buffer.from(body, 'utf8'),
    resolveKey: () => Promise.resolve(kAuth),
    nonceStore: new MemoryNonceStore(),
    windowSeconds: 60,
    nowMs: TIMESTAMP * 1000,
    ...overrides,
  };
}

describe('parseAuthHeader', () => {
  it('rejects malformed headers', () => {
    const mac = 'f'.repeat(64);
    const cases = [
      undefined,
      '',
      'Bearer abc',
      `KidsCam-HMAC ${pairingId}:viewer:1754850000`,
      `KidsCam-HMAC ${pairingId}:viewer:1754850000:${mac}:extra`,
      `KidsCam-HMAC ${pairingId}:admin:1754850000:${mac}`,
      `KidsCam-HMAC not-a-uuid:viewer:1754850000:${mac}`,
      `KidsCam-HMAC ${pairingId}:viewer:not-a-number:${mac}`,
      `KidsCam-HMAC ${pairingId}:viewer:1754850000:XYZ`,
      `KidsCam-HMAC ${pairingId}:viewer:1754850000:${'F'.repeat(64)}`,
      `kidscam-hmac ${pairingId}:viewer:1754850000:${mac}`,
    ];
    for (const header of cases) {
      expect(parseAuthHeader(header), header ?? 'undefined').toBeNull();
    }
  });
});

describe('macsEqual', () => {
  it('is true only for identical MACs', () => {
    const a = computeMac(kAuth, 'x');
    expect(macsEqual(a, a)).toBe(true);
    expect(macsEqual(a, computeMac(kAuth, 'y'))).toBe(false);
    expect(macsEqual(a, a.slice(0, 32))).toBe(false);
    expect(macsEqual(a, '')).toBe(false);
  });
});

describe('verifyRequest', () => {
  it('accepts a well-formed request', async () => {
    const result = await verifyRequest(signedInput());
    expect(result.ok).toBe(true);
  });

  it('rejects a missing Authorization header', async () => {
    const result = await verifyRequest(
      signedInput({ authorization: undefined }),
    );
    expect(result).toEqual({ ok: false, code: 'missing_authorization' });
  });

  it('rejects a timestamp older than the window', async () => {
    const result = await verifyRequest(
      signedInput({ nowMs: (TIMESTAMP + 61) * 1000 }),
    );
    expect(result).toEqual({ ok: false, code: 'timestamp_out_of_window' });
  });

  it('rejects a timestamp too far in the future', async () => {
    const result = await verifyRequest(
      signedInput({ nowMs: (TIMESTAMP - 61) * 1000 }),
    );
    expect(result).toEqual({ ok: false, code: 'timestamp_out_of_window' });
  });

  it('accepts a timestamp at the edge of the window', async () => {
    const result = await verifyRequest(
      signedInput({ nowMs: (TIMESTAMP + 59) * 1000 }),
    );
    expect(result.ok).toBe(true);
  });

  it('rejects an unknown pairing', async () => {
    const result = await verifyRequest(
      signedInput({ resolveKey: () => Promise.resolve(null) }),
    );
    expect(result).toEqual({ ok: false, code: 'unknown_pairing' });
  });

  it('rejects a MAC computed with a different key', async () => {
    const result = await verifyRequest(
      signedInput({ signingKey: randomBytes(32) }),
    );
    expect(result).toEqual({ ok: false, code: 'invalid_signature' });
  });

  it('rejects a tampered body', async () => {
    const input = signedInput({ body: '{"apnsToken":"aa"}' });
    const tampered: VerifyRequestInput = {
      ...input,
      rawBody: Buffer.from('{"apnsToken":"bb"}', 'utf8'),
    };
    expect(await verifyRequest(tampered)).toEqual({
      ok: false,
      code: 'invalid_signature',
    });
  });

  it('rejects a tampered path', async () => {
    const input = signedInput();
    expect(
      await verifyRequest({ ...input, path: '/v1/pairings/other/claim' }),
    ).toEqual({ ok: false, code: 'invalid_signature' });
  });

  it('rejects a tampered method', async () => {
    const input = signedInput();
    expect(await verifyRequest({ ...input, method: 'DELETE' })).toEqual({
      ok: false,
      code: 'invalid_signature',
    });
  });

  it('rejects a replayed request within the window', async () => {
    const nonceStore = new MemoryNonceStore();
    const input = signedInput({ nonceStore });
    expect((await verifyRequest(input)).ok).toBe(true);
    expect(await verifyRequest(input)).toEqual({
      ok: false,
      code: 'replayed_request',
    });
  });

  it('does not record a nonce for a request that fails its MAC check', async () => {
    const nonceStore = new MemoryNonceStore();
    const forged = signedInput({ nonceStore, signingKey: randomBytes(32) });
    expect(await verifyRequest(forged)).toEqual({
      ok: false,
      code: 'invalid_signature',
    });

    const parsed = parseAuthHeader(forged.authorization);
    expect(parsed).not.toBeNull();
    // The forged MAC must still be usable as a fresh nonce, i.e. it was never
    // written to the cache by the failed attempt.
    await expect(
      nonceStore.checkAndRecord(pairingId, parsed!.macHex, 120),
    ).resolves.toBe(true);
  });

  it('role is carried by the header, unbound by the MAC (documented limitation)', async () => {
    // The canonical string pinned in shared/protocol.md does not cover the
    // role, so any holder of K_auth can present either role. Route-level
    // authorization must therefore not treat the header role as an identity.
    const asCamera = await verifyRequest(signedInput({ role: 'camera' }));
    expect(asCamera.ok).toBe(true);
    if (asCamera.ok) expect(asCamera.auth.role).toBe('camera');
  });
});

describe('MemoryNonceStore', () => {
  it('forgets entries once their TTL has passed', async () => {
    const store = new MemoryNonceStore();
    const mac = 'a'.repeat(64);
    expect(await store.checkAndRecord(pairingId, mac, 1)).toBe(true);
    expect(await store.checkAndRecord(pairingId, mac, 1)).toBe(false);
    await new Promise((resolve) => setTimeout(resolve, 1100));
    expect(await store.checkAndRecord(pairingId, mac, 1)).toBe(true);
  });

  it('scopes nonces per pairing', async () => {
    const store = new MemoryNonceStore();
    const mac = 'c'.repeat(64);
    expect(await store.checkAndRecord(pairingId, mac, 60)).toBe(true);
    expect(
      await store.checkAndRecord(
        '00000000-0000-4000-8000-000000000000',
        mac,
        60,
      ),
    ).toBe(true);
  });
});
