/**
 * Loads the cross-implementation fixtures from `shared/test-vectors`.
 *
 * The file is read at runtime, never copied into source: the iOS suite loads
 * the same bytes, so a drift on either side fails a test instead of shipping.
 */

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export interface AuthVector {
  /** `bootstrap` or a device UUID (protocol.md 1.1). */
  readonly principal: string;
  readonly method: string;
  readonly path: string;
  readonly timestamp: string;
  readonly bodyUtf8: string;
  readonly bodySha256Hex: string;
  readonly canonicalString: string;
  readonly macHex: string;
  readonly authorizationHeader: string;
}

/** The four examples the vector file pins, by name. */
export type AuthVectorName =
  | 'bootstrapCreate'
  | 'bootstrapClaim'
  | 'deviceCameraRevoke'
  | 'deviceViewerTurnCredentials';

export interface TestVectors {
  readonly version: number;
  readonly revision: string;
  readonly hkdf: {
    readonly rootSecretHex: string;
    readonly keys: Record<
      string,
      { readonly info: string; readonly keyHex: string }
    >;
  };
  readonly sas: { readonly code: string };
  readonly deviceKeys: {
    readonly cameraDeviceId: string;
    readonly viewerDeviceId: string;
    readonly cameraDeviceKeyBase64: string;
    readonly viewerDeviceKeyBase64: string;
  };
  readonly requestAuth: {
    readonly pairingId: string;
    readonly examples: Readonly<Record<AuthVectorName, AuthVector>>;
  };
}

export const VECTORS_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../../shared/test-vectors/kidscam-v1.json',
);

export function loadVectors(): TestVectors {
  return JSON.parse(readFileSync(VECTORS_PATH, 'utf8')) as TestVectors;
}

/** `K_auth` from the vectors, as the server would have stored it. */
export function vectorKAuth(vectors: TestVectors): Buffer {
  const key = vectors.hkdf.keys['k_auth'];
  if (key === undefined) throw new Error('k_auth missing from test vectors');
  return Buffer.from(key.keyHex, 'hex');
}

export function vectorCameraDeviceKey(vectors: TestVectors): Buffer {
  return Buffer.from(vectors.deviceKeys.cameraDeviceKeyBase64, 'base64');
}

export function vectorViewerDeviceKey(vectors: TestVectors): Buffer {
  return Buffer.from(vectors.deviceKeys.viewerDeviceKeyBase64, 'base64');
}

/** The key each pinned example is signed with. */
export function signingKeyFor(
  vectors: TestVectors,
  name: AuthVectorName,
): Buffer {
  switch (name) {
    case 'bootstrapCreate':
    case 'bootstrapClaim':
      return vectorKAuth(vectors);
    case 'deviceCameraRevoke':
      return vectorCameraDeviceKey(vectors);
    case 'deviceViewerTurnCredentials':
      return vectorViewerDeviceKey(vectors);
  }
}

export const AUTH_VECTOR_NAMES: readonly AuthVectorName[] = [
  'bootstrapCreate',
  'bootstrapClaim',
  'deviceCameraRevoke',
  'deviceViewerTurnCredentials',
];
