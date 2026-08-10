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
  readonly role: 'camera' | 'viewer';
  readonly method: string;
  readonly path: string;
  readonly timestamp: string;
  readonly bodyUtf8: string;
  readonly bodySha256Hex: string;
  readonly canonicalString: string;
  readonly macHex: string;
  readonly authorizationHeader: string;
}

export interface TestVectors {
  readonly version: number;
  readonly hkdf: {
    readonly rootSecretHex: string;
    readonly keys: Record<
      string,
      { readonly info: string; readonly keyHex: string }
    >;
  };
  readonly sas: { readonly code: string };
  readonly requestAuth: {
    readonly pairingId: string;
    readonly examples: readonly AuthVector[];
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
