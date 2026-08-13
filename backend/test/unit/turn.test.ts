/**
 * `POST /v1/pairings/:id/turn-credentials` and the credential format itself:
 * the HMAC coturn must be able to recompute from the shared secret, and the
 * pass-through of a pair issued by a hosted relay.
 */

import { createHmac } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Config } from '../../src/config.ts';
import { loadConfig, turnConfigured, turnScheme } from '../../src/config.ts';
import { issueTurnCredentials } from '../../src/turn/credentials.ts';
import type { CameraCredentials, TestApp } from '../helpers/app.ts';
import {
  bootstrapCamera,
  bootstrapViewer,
  createTestApp,
  errorCode,
  jsonOf,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';

const TURN: Config['turn'] = {
  sharedSecret: 'test-turn-secret',
  staticUsername: '',
  staticCredential: '',
  ttlSeconds: 3600,
  uris: [
    'turn:turn.cribwire.example:3478?transport=udp',
    'turns:turn.cribwire.example:5349?transport=tcp',
  ],
};

/** A hosted relay: it issued the pair, we only forward it. */
const HOSTED_TURN: Config['turn'] = {
  sharedSecret: '',
  staticUsername: 'relay-user',
  staticCredential: 'relay-pass',
  ttlSeconds: 600,
  uris: [
    'turn:global.relay.example:80',
    'turns:global.relay.example:443?transport=tcp',
  ],
};

let harness: TestApp;
let camera: CameraCredentials;

beforeEach(async () => {
  harness = createTestApp({ turn: TURN });
  camera = await bootstrapCamera(harness);
  harness.setNow(new Date(harness.now().getTime() + 1000));
});

afterEach(async () => {
  await harness.close();
});

interface TurnResponse {
  username: string;
  credential: string;
  ttlSeconds: number;
  uris: string[];
}

describe('issueTurnCredentials', () => {
  it('matches the coturn use-auth-secret formula', () => {
    const now = new Date('2026-08-10T12:00:00.000Z');
    const credentials = issueTurnCredentials(TURN, camera.pairingId, now);

    const expiry = Math.floor(now.getTime() / 1000) + TURN.ttlSeconds;
    expect(credentials.username).toBe(`${expiry}:${camera.pairingId}`);
    expect(credentials.credential).toBe(
      createHmac('sha1', TURN.sharedSecret)
        .update(credentials.username, 'utf8')
        .digest('base64'),
    );
    expect(credentials.ttlSeconds).toBe(3600);
  });

  it('passes a hosted relay pair through untouched', () => {
    const now = new Date('2026-08-10T12:00:00.000Z');
    const credentials = issueTurnCredentials(HOSTED_TURN, 'pairing-id', now);

    // No HMAC: the relay never shared a secret and could not verify one.
    expect(credentials.username).toBe('relay-user');
    expect(credentials.credential).toBe('relay-pass');
    expect(credentials.uris).toEqual(HOSTED_TURN.uris);
    // The pairing does not scope a credential the provider issued globally.
    expect(credentials.username).not.toContain('pairing-id');
  });

  it('caps how long a client may cache a hosted pair', () => {
    const first = issueTurnCredentials(
      HOSTED_TURN,
      'pairing-id',
      new Date('2026-08-10T12:00:00.000Z'),
    );
    const later = issueTurnCredentials(
      HOSTED_TURN,
      'pairing-id',
      new Date('2026-08-10T18:00:00.000Z'),
    );

    // Static means static: only the TTL tells the client to come back, which
    // is what makes a rotated pair take effect.
    expect(later).toEqual(first);
    expect(first.ttlSeconds).toBe(600);
  });

  it('reports unconfigured TURN', () => {
    const base = harness.config;
    expect(turnConfigured(base)).toBe(true);
    expect(
      turnConfigured({
        ...base,
        turn: { ...TURN, sharedSecret: '' },
      }),
    ).toBe(false);
    expect(turnConfigured({ ...base, turn: { ...TURN, uris: [] } })).toBe(
      false,
    );
    // A hosted pair configures TURN just as completely as a shared secret.
    expect(turnConfigured({ ...base, turn: HOSTED_TURN })).toBe(true);
    // Half a pair is not a credential.
    expect(
      turnConfigured({
        ...base,
        turn: { ...HOSTED_TURN, staticCredential: '' },
      }),
    ).toBe(false);
  });

  it('names the scheme the relay expects', () => {
    expect(turnScheme(TURN)).toBe('hmac');
    expect(turnScheme(HOSTED_TURN)).toBe('static');
    expect(turnScheme({ ...TURN, sharedSecret: '' })).toBe('none');
  });
});

describe('TURN environment', () => {
  const base = {
    TURN_URIS: 'turn:relay.example:80',
  };

  it('reads a coturn shared secret', () => {
    const config = loadConfig({ ...base, TURN_SHARED_SECRET: 'secret' });
    expect(turnScheme(config.turn)).toBe('hmac');
  });

  it('reads a hosted relay pair', () => {
    const config = loadConfig({
      ...base,
      TURN_STATIC_USERNAME: 'relay-user',
      TURN_STATIC_CREDENTIAL: 'relay-pass',
    });
    expect(turnScheme(config.turn)).toBe('static');
    expect(config.turn.staticUsername).toBe('relay-user');
  });

  it('refuses both schemes at once', () => {
    // Which relay is on the other end decides whether either credential is
    // valid, and holding both says nothing about that.
    expect(() =>
      loadConfig({
        ...base,
        TURN_SHARED_SECRET: 'secret',
        TURN_STATIC_USERNAME: 'relay-user',
        TURN_STATIC_CREDENTIAL: 'relay-pass',
      }),
    ).toThrow(/mutually exclusive/);
  });

  it('refuses half a hosted pair', () => {
    expect(() =>
      loadConfig({ ...base, TURN_STATIC_USERNAME: 'relay-user' }),
    ).toThrow(/must be set together/);
  });
});

describe('POST /v1/pairings/:id/turn-credentials', () => {
  it('issues credentials to the camera', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/turn-credentials`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );

    expect(response.statusCode).toBe(200);
    const body = jsonOf<TurnResponse>(response);
    expect(body.username.endsWith(`:${camera.pairingId}`)).toBe(true);
    expect(body.uris).toEqual(TURN.uris);
    expect(body.ttlSeconds).toBe(3600);
    // The shared secret must never travel to a client.
    expect(response.body).not.toContain(TURN.sharedSecret);
  });

  it('issues credentials to a viewer as well', async () => {
    const viewer = await bootstrapViewer(harness, camera);
    harness.setNow(new Date(harness.now().getTime() + 1000));

    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/turn-credentials`,
        key: viewer.deviceKey,
        pairingId: camera.pairingId,
        principal: viewer.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(200);
  });

  it('serves a hosted relay pair over the same endpoint', async () => {
    const hosted = createTestApp({ turn: HOSTED_TURN });
    const hostedCamera = await bootstrapCamera(hosted);
    hosted.setNow(new Date(hosted.now().getTime() + 1000));

    const response = await hosted.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${hostedCamera.pairingId}/turn-credentials`,
        key: hostedCamera.deviceKey,
        pairingId: hostedCamera.pairingId,
        principal: hostedCamera.deviceId,
        timestampSeconds: secondsOf(hosted.now()),
      }),
    );

    expect(response.statusCode).toBe(200);
    // The response shape is what the iOS client already decodes; only where
    // the pair came from changed.
    const body = jsonOf<TurnResponse>(response);
    expect(body.username).toBe('relay-user');
    expect(body.credential).toBe('relay-pass');
    expect(body.uris).toEqual(HOSTED_TURN.uris);
    await hosted.close();
  });

  it('refuses an unauthenticated request', async () => {
    const response = await harness.app.inject({
      method: 'POST',
      url: `/v1/pairings/${camera.pairingId}/turn-credentials`,
      headers: { 'content-type': 'application/json' },
    });
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('missing_authorization');
  });

  it('refuses credentials for another pairing', async () => {
    const other = await bootstrapCamera(harness);
    harness.setNow(new Date(harness.now().getTime() + 1000));

    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${other.pairingId}/turn-credentials`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('pairing_mismatch');
  });

  it('answers 503 when TURN is not configured', async () => {
    const bare = createTestApp();
    const bareCamera = await bootstrapCamera(bare);
    bare.setNow(new Date(bare.now().getTime() + 1000));

    const response = await bare.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${bareCamera.pairingId}/turn-credentials`,
        key: bareCamera.deviceKey,
        pairingId: bareCamera.pairingId,
        principal: bareCamera.deviceId,
        timestampSeconds: secondsOf(bare.now()),
      }),
    );
    expect(response.statusCode).toBe(503);
    expect(errorCode(response)).toBe('turn_unavailable');
    await bare.close();
  });

  it('rate-limits per pairing', async () => {
    const capacity = harness.config.rateLimits.perPairing.capacity;
    let lastStatus = 0;
    for (let i = 0; i < capacity + 2; i += 1) {
      harness.setNow(new Date(harness.now().getTime() + 1000));
      const response = await harness.app.inject(
        signRequest({
          method: 'POST',
          path: `/v1/pairings/${camera.pairingId}/turn-credentials`,
          key: camera.deviceKey,
          pairingId: camera.pairingId,
          principal: camera.deviceId,
          timestampSeconds: secondsOf(harness.now()),
        }),
      );
      lastStatus = response.statusCode;
    }
    expect(lastStatus).toBe(429);
  });
});
