/**
 * Contract tests against `shared/test-vectors/kidscam-v1.json`.
 *
 * These are the cross-implementation gate: if the backend and the iOS app
 * disagree about a single byte of the canonical string, this file fails.
 */

import { describe, expect, it } from 'vitest';
import {
  bodySha256Hex,
  buildAuthHeader,
  canonicalString,
  computeMac,
  macsEqual,
  parseAuthHeader,
} from '../../src/auth/canonical.ts';
import { MemoryNonceStore } from '../../src/auth/nonce-store.ts';
import { verifyRequest } from '../../src/auth/verify.ts';
import { loadVectors, vectorKAuth } from '../helpers/vectors.ts';

const vectors = loadVectors();
const kAuth = vectorKAuth(vectors);

describe('KidsCam-HMAC vectors', () => {
  it('loads the shared vector file', () => {
    expect(vectors.version).toBe(1);
    expect(vectors.requestAuth.examples.length).toBeGreaterThanOrEqual(2);
    expect(kAuth).toHaveLength(32);
  });

  for (const vector of vectors.requestAuth.examples) {
    describe(`${vector.method} ${vector.path}`, () => {
      it('reproduces the body hash', () => {
        expect(bodySha256Hex(vector.bodyUtf8)).toBe(vector.bodySha256Hex);
      });

      it('reproduces the canonical string byte-for-byte', () => {
        expect(
          canonicalString(
            vector.method,
            vector.path,
            vector.timestamp,
            vector.bodySha256Hex,
          ),
        ).toBe(vector.canonicalString);
      });

      it('reproduces the MAC', () => {
        expect(computeMac(kAuth, vector.canonicalString)).toBe(vector.macHex);
        expect(
          macsEqual(computeMac(kAuth, vector.canonicalString), vector.macHex),
        ).toBe(true);
      });

      it('reproduces and re-parses the Authorization header', () => {
        const header = buildAuthHeader({
          pairingId: vectors.requestAuth.pairingId,
          role: vector.role,
          timestamp: vector.timestamp,
          macHex: vector.macHex,
        });
        expect(header).toBe(vector.authorizationHeader);

        const parsed = parseAuthHeader(vector.authorizationHeader);
        expect(parsed).toEqual({
          pairingId: vectors.requestAuth.pairingId,
          role: vector.role,
          timestamp: vector.timestamp,
          macHex: vector.macHex,
        });
      });

      it('is accepted end-to-end by verifyRequest', async () => {
        const result = await verifyRequest({
          method: vector.method,
          path: vector.path,
          authorization: vector.authorizationHeader,
          rawBody: Buffer.from(vector.bodyUtf8, 'utf8'),
          resolveKey: () => Promise.resolve(kAuth),
          nonceStore: new MemoryNonceStore(),
          windowSeconds: 60,
          nowMs: Number.parseInt(vector.timestamp, 10) * 1000,
        });
        expect(result).toEqual({
          ok: true,
          auth: {
            pairingId: vectors.requestAuth.pairingId,
            role: vector.role,
            timestamp: Number.parseInt(vector.timestamp, 10),
            macHex: vector.macHex,
          },
        });
      });
    });
  }

  it('empty and absent bodies hash identically', () => {
    const empty = vectors.requestAuth.examples.find(
      (example) => example.bodyUtf8 === '',
    );
    expect(empty).toBeDefined();
    expect(bodySha256Hex(undefined)).toBe(empty?.bodySha256Hex);
    expect(bodySha256Hex(Buffer.alloc(0))).toBe(empty?.bodySha256Hex);
  });
});
