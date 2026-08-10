/**
 * Contract tests against `shared/test-vectors/kidscam-v1.json` (revision 1.1).
 *
 * These are the cross-implementation gate: if the backend and the iOS app
 * disagree about a single byte of the canonical string, this file fails. All
 * four pinned examples are covered — both bootstrap calls, a camera-principal
 * request, and a viewer-principal request — each verified with the key the
 * protocol says signs it.
 */

import { describe, expect, it } from 'vitest';
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
import { verifyRequest } from '../../src/auth/verify.ts';
import {
  AUTH_VECTOR_NAMES,
  loadVectors,
  signingKeyFor,
  vectorCameraDeviceKey,
  vectorKAuth,
  vectorViewerDeviceKey,
} from '../helpers/vectors.ts';

const vectors = loadVectors();
const pairingId = vectors.requestAuth.pairingId;

describe('KidsCam-HMAC vectors', () => {
  it('loads revision 1.1 of the shared vector file', () => {
    expect(vectors.version).toBe(1);
    expect(vectors.revision).toBe('1.1');
    expect(vectorKAuth(vectors)).toHaveLength(32);
    expect(vectorCameraDeviceKey(vectors)).toHaveLength(32);
    expect(vectorViewerDeviceKey(vectors)).toHaveLength(32);
  });

  it('pins all four auth examples', () => {
    expect(Object.keys(vectors.requestAuth.examples).sort()).toEqual(
      [...AUTH_VECTOR_NAMES].sort(),
    );
  });

  for (const name of AUTH_VECTOR_NAMES) {
    describe(name, () => {
      const vector = vectors.requestAuth.examples[name];
      const key = signingKeyFor(vectors, name);

      it('uses the principal the protocol assigns to this call', () => {
        const bootstrapCall = name.startsWith('bootstrap');
        expect(vector.principal === BOOTSTRAP_PRINCIPAL).toBe(bootstrapCall);
        if (!bootstrapCall) {
          // A device principal is a UUID and must not be a role name.
          expect(vector.principal).toMatch(/^[0-9a-f-]{36}$/);
        }
      });

      it('reproduces the body hash', () => {
        expect(bodySha256Hex(vector.bodyUtf8)).toBe(vector.bodySha256Hex);
      });

      it('reproduces the five-line canonical string byte-for-byte', () => {
        const canonical = canonicalString(
          vector.method,
          vector.path,
          vector.timestamp,
          vector.principal,
          vector.bodySha256Hex,
        );
        expect(canonical).toBe(vector.canonicalString);
        expect(canonical.split('\n')).toHaveLength(5);
      });

      it('reproduces the MAC under the key that signs this call', () => {
        expect(computeMac(key, vector.canonicalString)).toBe(vector.macHex);
        expect(
          macsEqual(computeMac(key, vector.canonicalString), vector.macHex),
        ).toBe(true);
      });

      it('does not verify under any other pinned key', () => {
        const others = [
          vectorKAuth(vectors),
          vectorCameraDeviceKey(vectors),
          vectorViewerDeviceKey(vectors),
        ].filter((candidate) => !candidate.equals(key));
        for (const other of others) {
          expect(computeMac(other, vector.canonicalString)).not.toBe(
            vector.macHex,
          );
        }
      });

      it('reproduces and re-parses the Authorization header', () => {
        const header = buildAuthHeader({
          pairingId,
          principal: vector.principal,
          timestamp: vector.timestamp,
          macHex: vector.macHex,
        });
        expect(header).toBe(vector.authorizationHeader);

        expect(parseAuthHeader(vector.authorizationHeader)).toEqual({
          pairingId,
          principal: vector.principal,
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
          resolveKey: () => Promise.resolve(key),
          nonceStore: new MemoryNonceStore(),
          windowSeconds: 60,
          nowMs: Number.parseInt(vector.timestamp, 10) * 1000,
        });
        expect(result).toEqual({
          ok: true,
          auth: {
            pairingId,
            principal: vector.principal,
            timestamp: Number.parseInt(vector.timestamp, 10),
            macHex: vector.macHex,
          },
        });
      });
    });
  }

  it('binds the principal into the MAC', () => {
    // The escalation 1.0 allowed: swap the principal, keep everything else.
    const vector = vectors.requestAuth.examples.deviceCameraRevoke;
    const viewerId = vectors.deviceKeys.viewerDeviceId;
    const forged = canonicalString(
      vector.method,
      vector.path,
      vector.timestamp,
      viewerId,
      vector.bodySha256Hex,
    );
    expect(computeMac(vectorCameraDeviceKey(vectors), forged)).not.toBe(
      vector.macHex,
    );
  });

  it('empty and absent bodies hash identically', () => {
    const empty = Object.values(vectors.requestAuth.examples).find(
      (example) => example.bodyUtf8 === '',
    );
    expect(empty).toBeDefined();
    expect(bodySha256Hex(undefined)).toBe(empty?.bodySha256Hex);
    expect(bodySha256Hex(Buffer.alloc(0))).toBe(empty?.bodySha256Hex);
  });
});
