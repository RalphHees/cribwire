/**
 * `GET /v1/config` — the values a client is allowed to learn from the server,
 * and the one it must never learn.
 */

import type { LightMyRequestResponse } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Config } from '../../src/config.ts';
import {
  loadConfig,
  spotifyConfigured,
  tidalConfigured,
} from '../../src/config.ts';
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

const TIDAL: Config['tidal'] = {
  clientId: 'tidal-client-id',
  clientSecret: 'tidal-client-secret-never-served',
};

const SPOTIFY: Config['spotify'] = {
  clientId: 'spotify-client-id',
};

interface ConfigResponse {
  ttlSeconds: number;
  tidal?: { clientId: string };
  spotify?: { clientId: string };
}

let harness: TestApp;
let camera: CameraCredentials;

beforeEach(async () => {
  harness = createTestApp({ tidal: TIDAL, spotify: SPOTIFY });
  camera = await bootstrapCamera(harness);
  harness.setNow(new Date(harness.now().getTime() + 1000));
});

afterEach(async () => {
  await harness.close();
});

function get(
  app: TestApp,
  credentials: { deviceKey: Buffer; deviceId: string; pairingId: string },
): Promise<LightMyRequestResponse> {
  return app.app.inject(
    signRequest({
      method: 'GET',
      path: '/v1/config',
      key: credentials.deviceKey,
      pairingId: credentials.pairingId,
      principal: credentials.deviceId,
      timestampSeconds: secondsOf(app.now()),
    }),
  );
}

describe('TIDAL configuration', () => {
  it('needs only the client id to be usable by a camera', () => {
    const base = harness.config;
    expect(tidalConfigured(base)).toBe(true);
    // The sign-in flows a phone uses are public-client flows: a deployment with
    // only the secret has nothing a Camera can use.
    expect(
      tidalConfigured({
        ...base,
        tidal: { clientId: '', clientSecret: 'secret' },
      }),
    ).toBe(false);
  });

  it('reads both halves from the environment', () => {
    const config = loadConfig({
      TIDAL_CLIENT_ID: 'from-env',
      TIDAL_CLIENT_SECRET: 'secret-from-env',
    });
    expect(config.tidal.clientId).toBe('from-env');
    expect(config.tidal.clientSecret).toBe('secret-from-env');
  });

  it('defaults to unconfigured', () => {
    expect(tidalConfigured(loadConfig({}))).toBe(false);
  });
});

describe('Spotify configuration', () => {
  it('reads the client id from the environment', () => {
    const config = loadConfig({ SPOTIFY_CLIENT_ID: 'from-env' });
    expect(config.spotify.clientId).toBe('from-env');
    expect(spotifyConfigured(config)).toBe(true);
  });

  it('defaults to unconfigured', () => {
    expect(spotifyConfigured(loadConfig({}))).toBe(false);
  });

  /**
   * Spotify has no server-side half at all: this process never calls Spotify,
   * so there is no `client_credentials` flow and nothing for a secret to do.
   * Asserted rather than assumed, because "we did it for TIDAL" is exactly the
   * reasoning that would later add one nothing consumes.
   */
  it('holds no secret to leak', () => {
    const config = loadConfig({
      SPOTIFY_CLIENT_ID: 'from-env',
      SPOTIFY_CLIENT_SECRET: 'should-be-ignored',
    });
    expect(Object.keys(config.spotify)).toEqual(['clientId']);
    expect(JSON.stringify(config.spotify)).not.toContain('should-be-ignored');
  });
});

describe('GET /v1/config', () => {
  it('serves the client id and a cache lifetime', async () => {
    const response = await get(harness, camera);

    expect(response.statusCode).toBe(200);
    const body = jsonOf<ConfigResponse>(response);
    expect(body.tidal?.clientId).toBe(TIDAL.clientId);
    expect(body.ttlSeconds).toBe(harness.config.configTtlSeconds);
  });

  // The property that matters most in this file.
  it('never serves the client secret', async () => {
    const response = await get(harness, camera);

    expect(response.body).not.toContain(TIDAL.clientSecret);
    expect(response.body).not.toContain('clientSecret');
    expect(Object.keys(jsonOf<ConfigResponse>(response).tidal ?? {})).toEqual([
      'clientId',
    ]);
  });

  it('serves the Spotify client id alongside TIDAL', async () => {
    const response = await get(harness, camera);

    expect(response.statusCode).toBe(200);
    const body = jsonOf<ConfigResponse>(response);
    expect(body.spotify?.clientId).toBe(SPOTIFY.clientId);
    // Both, independently: a deployment may serve either, both or neither, and
    // one service being present must never decide the other's fate.
    expect(body.tidal?.clientId).toBe(TIDAL.clientId);
  });

  it('serves one service without the other', async () => {
    const spotifyOnly = createTestApp({ spotify: SPOTIFY });
    const spotifyCamera = await bootstrapCamera(spotifyOnly);
    spotifyOnly.setNow(new Date(spotifyOnly.now().getTime() + 1000));

    const response = await get(spotifyOnly, spotifyCamera);

    const body = jsonOf<ConfigResponse>(response);
    expect(body.spotify?.clientId).toBe(SPOTIFY.clientId);
    expect(body.tidal).toBeUndefined();
    await spotifyOnly.close();
  });

  it('omits a service this deployment has not configured', async () => {
    const bare = createTestApp();
    const bareCamera = await bootstrapCamera(bare);
    bare.setNow(new Date(bare.now().getTime() + 1000));

    const response = await get(bare, bareCamera);

    expect(response.statusCode).toBe(200);
    // Absent, not empty: the client reads "this deployment has none" and falls
    // back to what it was built with, rather than to a blank id.
    const body = jsonOf<ConfigResponse>(response);
    expect(body.tidal).toBeUndefined();
    expect(body.spotify).toBeUndefined();
    await bare.close();
  });

  it('answers a viewer the same as a camera', async () => {
    const viewer = await bootstrapViewer(harness, camera);
    harness.setNow(new Date(harness.now().getTime() + 1000));

    const forCamera = await get(harness, camera);
    harness.setNow(new Date(harness.now().getTime() + 1000));
    const forViewer = await get(harness, viewer);

    expect(forViewer.statusCode).toBe(200);
    // Identical for everyone, which is why authenticating it is about keeping
    // the endpoint closed rather than about privacy.
    expect(forViewer.body).toBe(forCamera.body);
  });

  it('refuses an unauthenticated request', async () => {
    const response = await harness.app.inject({
      method: 'GET',
      url: '/v1/config',
    });
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('missing_authorization');
  });

  it('rate-limits per pairing', async () => {
    const capacity = harness.config.rateLimits.perPairing.capacity;
    let lastStatus = 0;
    for (let i = 0; i < capacity + 2; i += 1) {
      harness.setNow(new Date(harness.now().getTime() + 1000));
      lastStatus = (await get(harness, camera)).statusCode;
    }
    expect(lastStatus).toBe(429);
  });
});
