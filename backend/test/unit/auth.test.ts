/** Abuse cases for `CribWire-HMAC` verification (protocol.md 1.1). */

import { describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import {
  BOOTSTRAP_PRINCIPAL,
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
const deviceId = vectors.deviceKeys.viewerDeviceId;
const TIMESTAMP = 1_754_850_000;

function signedInput(
  overrides: Partial<VerifyRequestInput> & {
    method?: string;
    path?: string;
    body?: string;
    principal?: string;
    timestamp?: number;
    signingKey?: Buffer;
  } = {},
): VerifyRequestInput {
  const method = overrides.method ?? 'POST';
  const path = overrides.path ?? `/v1/pairings/${pairingId}/claim`;
  const body = overrides.body ?? '{"apnsToken":"aa"}';
  const timestamp = String(overrides.timestamp ?? TIMESTAMP);
  const principal = overrides.principal ?? BOOTSTRAP_PRINCIPAL;
  const macHex = computeMac(
    overrides.signingKey ?? kAuth,
    canonicalString(method, path, timestamp, principal, bodySha256Hex(body)),
  );

  return {
    method,
    path,
    authorization: buildAuthHeader({
      pairingId,
      principal,
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
  it('accepts the bootstrap literal and a device UUID as principals', () => {
    const mac = 'f'.repeat(64);
    for (const principal of [BOOTSTRAP_PRINCIPAL, deviceId]) {
      const header = `CribWire-HMAC ${pairingId}:${principal}:1754850000:${mac}`;
      expect(parseAuthHeader(header)?.principal).toBe(principal);
    }
  });

  it('rejects malformed headers', () => {
    const mac = 'f'.repeat(64);
    const cases = [
      undefined,
      '',
      'Bearer abc',
      `CribWire-HMAC ${pairingId}:${deviceId}:1754850000`,
      `CribWire-HMAC ${pairingId}:${deviceId}:1754850000:${mac}:extra`,
      // A role is not a principal any more: 1.0 headers must not parse.
      `CribWire-HMAC ${pairingId}:camera:1754850000:${mac}`,
      `CribWire-HMAC ${pairingId}:viewer:1754850000:${mac}`,
      `CribWire-HMAC ${pairingId}:admin:1754850000:${mac}`,
      `CribWire-HMAC ${pairingId}::1754850000:${mac}`,
      `CribWire-HMAC ${pairingId}:BOOTSTRAP:1754850000:${mac}`,
      `CribWire-HMAC not-a-uuid:${deviceId}:1754850000:${mac}`,
      `CribWire-HMAC ${pairingId}:${deviceId}:not-a-number:${mac}`,
      `CribWire-HMAC ${pairingId}:${deviceId}:1754850000:XYZ`,
      `CribWire-HMAC ${pairingId}:${deviceId}:1754850000:${'F'.repeat(64)}`,
      `cribwire-hmac ${pairingId}:${deviceId}:1754850000:${mac}`,
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

  it('returns the principal that signed', async () => {
    const result = await verifyRequest(signedInput({ principal: deviceId }));
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.auth.principal).toBe(deviceId);
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

  it('rejects a principal with no key', async () => {
    const result = await verifyRequest(
      signedInput({ resolveKey: () => Promise.resolve(null) }),
    );
    expect(result).toEqual({ ok: false, code: 'unknown_principal' });
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

  it('rejects a swapped principal: the MAC covers it', async () => {
    // The escalation revision 1.1 closes. The MAC was computed over
    // `bootstrap`; presenting it under a device principal must not verify.
    const signed = signedInput();
    const parts = parseAuthHeader(signed.authorization);
    const forged = buildAuthHeader({
      pairingId,
      principal: randomUUID(),
      timestamp: String(TIMESTAMP),
      macHex: parts!.macHex,
    });
    expect(await verifyRequest({ ...signed, authorization: forged })).toEqual({
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
