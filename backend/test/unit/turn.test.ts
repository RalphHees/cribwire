/**
 * `POST /v1/pairings/:id/turn-credentials` and the credential format itself,
 * which coturn must be able to recompute from the shared secret.
 */

import { createHmac } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Config } from '../../src/config.ts';
import { turnConfigured } from '../../src/config.ts';
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
  ttlSeconds: 3600,
  uris: [
    'turn:turn.cribwire.example:3478?transport=udp',
    'turns:turn.cribwire.example:5349?transport=tcp',
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
