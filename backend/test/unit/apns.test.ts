/**
 * APNs payload construction and provider-token signing.
 *
 * No test here talks to Apple: the payload is checked field by field against
 * backend.md §3, and the JWT is verified locally against the public half of a
 * throwaway P-256 key.
 */

import { generateKeyPairSync, verify } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import type { ApnsSender } from '../../src/push/apns.ts';
import {
  DisabledApnsSender,
  EVENT_ALERT_LOC_KEY,
  buildApnsPayload,
} from '../../src/push/apns.ts';
import { APNS_HOSTS, signProviderToken } from '../../src/push/http2-apns.ts';

function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(
    Buffer.from(
      segment.replace(/-/g, '+').replace(/_/g, '/'),
      'base64',
    ).toString('utf8'),
  ) as Record<string, unknown>;
}

describe('buildApnsPayload', () => {
  it('produces exactly the payload the spec pins', () => {
    const ciphertext = 'c2VhbGVkLWJ5dGVz';
    const payload = buildApnsPayload({
      deviceToken: 'a'.repeat(64),
      environment: 'sandbox',
      pairingId: '7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70',
      ciphertext,
    });

    expect(payload).toEqual({
      aps: {
        alert: { 'loc-key': EVENT_ALERT_LOC_KEY },
        'mutable-content': 1,
      },
      pairingId: '7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70',
      ciphertext,
    });
    // The visible text is a fixed key: no detection detail leaves the device.
    expect(JSON.stringify(payload)).not.toContain('noise');
  });

  it('keeps the ciphertext byte-identical', () => {
    const ciphertext = Buffer.from([0, 1, 2, 250, 251]).toString('base64');
    expect(
      buildApnsPayload({
        deviceToken: 'b'.repeat(64),
        environment: 'production',
        pairingId: 'p',
        ciphertext,
      }).ciphertext,
    ).toBe(ciphertext);
  });
});

describe('signProviderToken', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', {
    namedCurve: 'P-256',
  });

  it('signs a verifiable ES256 JWT with the pinned header and claims', () => {
    const token = signProviderToken(privateKey, 'KEYID12345', 'TEAMID6789', 1);
    const [header, payload, signature] = token.split('.');

    expect(decodeSegment(header!)).toEqual({
      alg: 'ES256',
      kid: 'KEYID12345',
      typ: 'JWT',
    });
    expect(decodeSegment(payload!)).toEqual({ iss: 'TEAMID6789', iat: 1 });

    const verified = verify(
      'sha256',
      Buffer.from(`${header!}.${payload!}`, 'utf8'),
      { key: publicKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(signature!.replace(/-/g, '+').replace(/_/g, '/'), 'base64'),
    );
    expect(verified).toBe(true);
  });

  it('emits base64url without padding', () => {
    const token = signProviderToken(privateKey, 'K', 'T', 1_754_850_000);
    expect(token).not.toContain('=');
    expect(token).not.toContain('+');
    expect(token).not.toContain('/');
  });
});

describe('APNs hosts', () => {
  it('separates sandbox from production', () => {
    expect(APNS_HOSTS.sandbox).toBe('https://api.sandbox.push.apple.com');
    expect(APNS_HOSTS.production).toBe('https://api.push.apple.com');
  });
});

describe('DisabledApnsSender', () => {
  it('reports a configuration failure rather than pretending to send', async () => {
    const sender: ApnsSender = new DisabledApnsSender();
    await expect(
      sender.send({
        deviceToken: 'a'.repeat(64),
        environment: 'sandbox',
        pairingId: 'p',
        ciphertext: 'x',
      }),
    ).resolves.toEqual({ status: 'failed', reason: 'apns_not_configured' });
    await sender.close();
  });
});
