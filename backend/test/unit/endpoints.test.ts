/**
 * Endpoint behaviour against the in-memory repository: authorization derived
 * from the device row, limits, revocation, and the HTTP-level abuse cases.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import { BOOTSTRAP_PRINCIPAL } from '../../src/auth/canonical.ts';
import type { CameraCredentials, TestApp } from '../helpers/app.ts';
import {
  CAMERA_TOKEN,
  VIEWER_TOKEN,
  bootstrapCamera,
  bootstrapViewer,
  claimBody,
  createPairingBody,
  createTestApp,
  errorCode,
  jsonOf,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';

let harness: TestApp;

beforeEach(() => {
  harness = createTestApp();
});

afterEach(async () => {
  await harness.close();
});

/** Moves the clock so a second signature is not seen as a replay. */
function tick(seconds = 1): void {
  harness.setNow(new Date(harness.now().getTime() + seconds * 1000));
}

describe('ops endpoints', () => {
  it('serves health and version without authentication', async () => {
    const health = await harness.app.inject({
      method: 'GET',
      url: '/v1/health',
    });
    expect(health.statusCode).toBe(200);
    expect(jsonOf(health)).toEqual({ status: 'ok' });

    const version = await harness.app.inject({
      method: 'GET',
      url: '/v1/version',
    });
    expect(version.statusCode).toBe(200);
    expect(jsonOf(version)).toMatchObject({
      api: 'v1',
      service: 'cribwire-backend',
    });
  });

  it('answers 404 with the pinned error body', async () => {
    const response = await harness.app.inject({ method: 'GET', url: '/nope' });
    expect(response.statusCode).toBe(404);
    expect(jsonOf(response)).toEqual({
      error: 'not_found',
      message: 'Unknown endpoint',
    });
  });
});

describe('POST /v1/pairings', () => {
  it('registers a pending pairing, a camera device, and its key', async () => {
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const deviceKey = randomBytes(32);

    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(pairingId, kAuth, deviceKey),
      }),
    );

    expect(response.statusCode).toBe(201);
    const body = jsonOf<Record<string, unknown>>(response);
    expect(body['pairingId']).toBe(pairingId);
    expect(body['role']).toBe('camera');
    expect(body['status']).toBe('pending');
    expect(body['ttlSeconds']).toBe(600);
    expect(typeof body['deviceId']).toBe('string');
    expect(typeof body['expiresAt']).toBe('string');

    const stored = await harness.repository.getDevice(
      pairingId,
      body['deviceId'] as string,
    );
    expect(stored?.deviceKey.equals(deviceKey)).toBe(true);
    // The response must never echo key material.
    expect(response.body).not.toContain(kAuth.toString('base64'));
    expect(response.body).not.toContain(deviceKey.toString('base64'));
  });

  it('rejects a body whose pairingId differs from the signed one', async () => {
    const signedPairingId = randomUUID();
    const kAuth = randomBytes(32);
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId: signedPairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(randomUUID(), kAuth, randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('unknown_principal');
  });

  it('rejects a request signed with a key other than the uploaded one', async () => {
    const pairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: randomBytes(32),
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(pairingId, randomBytes(32), randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('invalid_signature');
  });

  it('rejects a device principal on a bootstrap route', async () => {
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: randomUUID(),
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(pairingId, kAuth, randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('unknown_principal');
  });

  it('rejects a missing or short device key', async () => {
    for (const deviceKeyBase64 of [
      undefined,
      randomBytes(16).toString('base64'),
    ]) {
      const pairingId = randomUUID();
      const kAuth = randomBytes(32);
      const body = JSON.stringify({
        pairingId,
        kAuth: kAuth.toString('base64'),
        ...(deviceKeyBase64 === undefined
          ? {}
          : { deviceKey: deviceKeyBase64 }),
        apnsToken: CAMERA_TOKEN,
        apnsEnvironment: 'sandbox',
      });
      const response = await harness.app.inject(
        signRequest({
          method: 'POST',
          path: '/v1/pairings',
          key: kAuth,
          pairingId,
          principal: BOOTSTRAP_PRINCIPAL,
          timestampSeconds: secondsOf(harness.now()),
          body,
        }),
      );
      expect(response.statusCode).toBe(400);
      expect(errorCode(response)).toBe('invalid_body');
    }
  });

  it('rejects a K_auth of the wrong length', async () => {
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const body = JSON.stringify({
      pairingId,
      kAuth: randomBytes(16).toString('base64'),
      deviceKey: randomBytes(32).toString('base64'),
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
    });
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body,
      }),
    );
    expect(response.statusCode).toBe(400);
  });

  it('rejects a body carrying an unknown field', async () => {
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const body = JSON.stringify({
      pairingId,
      kAuth: kAuth.toString('base64'),
      deviceKey: randomBytes(32).toString('base64'),
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
      role: 'camera',
    });
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body,
      }),
    );
    expect(response.statusCode).toBe(400);
    expect(errorCode(response)).toBe('invalid_body');
  });

  it('rejects a malformed APNs token', async () => {
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const body = JSON.stringify({
      pairingId,
      kAuth: kAuth.toString('base64'),
      deviceKey: randomBytes(32).toString('base64'),
      apnsToken: 'not-a-token',
      apnsEnvironment: 'sandbox',
    });
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body,
      }),
    );
    expect(response.statusCode).toBe(400);
  });

  it('rejects a duplicate pairing id', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(
          camera.pairingId,
          camera.kAuth,
          randomBytes(32),
        ),
      }),
    );
    expect(response.statusCode).toBe(409);
    expect(errorCode(response)).toBe('pairing_exists');
  });

  it('rate-limits pairing creation per IP', async () => {
    const capacity = harness.config.rateLimits.pairingCreatePerIp.capacity;
    for (let i = 0; i < capacity; i += 1) {
      await bootstrapCamera(harness);
    }
    const pairingId = randomUUID();
    const kAuth = randomBytes(32);
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        key: kAuth,
        pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: createPairingBody(pairingId, kAuth, randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(429);
    expect(response.headers['retry-after']).toBeDefined();
    expect(errorCode(response)).toBe('rate_limited');
  });

  it('rejects a body larger than the configured limit', async () => {
    const response = await harness.app.inject({
      method: 'POST',
      url: '/v1/pairings',
      headers: { 'content-type': 'application/json' },
      payload: 'x'.repeat(harness.config.maxBodyBytes + 1),
    });
    expect(response.statusCode).toBe(413);
  });
});

describe('POST /v1/pairings/:id/claim', () => {
  let camera: CameraCredentials;

  beforeEach(async () => {
    camera = await bootstrapCamera(harness);
    tick();
  });

  it('activates the pairing and registers the viewer with its own key', async () => {
    const deviceKey = randomBytes(32);
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/claim`,
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: claimBody(deviceKey),
      }),
    );

    expect(response.statusCode).toBe(201);
    const body = jsonOf<Record<string, unknown>>(response);
    expect(body['status']).toBe('active');
    expect(body['role']).toBe('viewer');
    expect(typeof body['claimedAt']).toBe('string');

    const stored = await harness.repository.getDevice(
      camera.pairingId,
      body['deviceId'] as string,
    );
    expect(stored?.deviceKey.equals(deviceKey)).toBe(true);
    expect(response.body).not.toContain(deviceKey.toString('base64'));
  });

  it('accepts at most five viewers', async () => {
    for (let i = 0; i < harness.config.maxViewersPerPairing; i += 1) {
      tick();
      await bootstrapViewer(harness, camera);
    }

    tick();
    const rejected = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/claim`,
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: claimBody(randomBytes(32)),
      }),
    );
    expect(rejected.statusCode).toBe(409);
    expect(errorCode(rejected)).toBe('viewer_limit_reached');

    const viewers = (
      await harness.repository.listDevices(camera.pairingId)
    ).filter((device) => device.role === 'viewer');
    expect(viewers).toHaveLength(harness.config.maxViewersPerPairing);
  });

  it('rejects credentials issued for a different pairing', async () => {
    const other = await bootstrapCamera(harness);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${other.pairingId}/claim`,
        key: camera.kAuth,
        // Signed for the first pairing, aimed at the second.
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: claimBody(randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('pairing_mismatch');

    const devices = await harness.repository.listDevices(other.pairingId);
    expect(devices.filter((device) => device.role === 'viewer')).toHaveLength(
      0,
    );
  });

  it('rejects a claim after the 10-minute TTL', async () => {
    harness.setNow(
      new Date(
        harness.now().getTime() + (harness.config.pairingTtlSeconds + 1) * 1000,
      ),
    );
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/claim`,
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
        body: claimBody(randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(410);
    expect(errorCode(response)).toBe('pairing_expired');
  });

  it('still accepts a further viewer on an active pairing after the TTL', async () => {
    await bootstrapViewer(harness, camera);
    harness.setNow(
      new Date(
        harness.now().getTime() + (harness.config.pairingTtlSeconds + 1) * 1000,
      ),
    );
    await expect(
      bootstrapViewer(harness, camera, 'c'.repeat(64)),
    ).resolves.toMatchObject({ pairingId: camera.pairingId });
  });

  it('rejects an expired request timestamp', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${camera.pairingId}/claim`,
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()) - 61,
        body: claimBody(randomBytes(32)),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('timestamp_out_of_window');
  });

  it('rejects a replayed request', async () => {
    const request = signRequest({
      method: 'POST',
      path: `/v1/pairings/${camera.pairingId}/claim`,
      key: camera.kAuth,
      pairingId: camera.pairingId,
      principal: BOOTSTRAP_PRINCIPAL,
      timestampSeconds: secondsOf(harness.now()),
      body: claimBody(randomBytes(32)),
    });

    expect((await harness.app.inject(request)).statusCode).toBe(201);
    const replay = await harness.app.inject(request);
    expect(replay.statusCode).toBe(401);
    expect(errorCode(replay)).toBe('replayed_request');

    const viewers = (
      await harness.repository.listDevices(camera.pairingId)
    ).filter((device) => device.role === 'viewer');
    expect(viewers).toHaveLength(1);
  });

  it('rejects a tampered body', async () => {
    const request = signRequest({
      method: 'POST',
      path: `/v1/pairings/${camera.pairingId}/claim`,
      key: camera.kAuth,
      pairingId: camera.pairingId,
      principal: BOOTSTRAP_PRINCIPAL,
      timestampSeconds: secondsOf(harness.now()),
      body: claimBody(randomBytes(32)),
    });

    const response = await harness.app.inject({
      ...request,
      payload: claimBody(randomBytes(32), 'c'.repeat(64)),
    });
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('invalid_signature');
  });
});

describe('DELETE /v1/pairings/:id', () => {
  it('lets the camera revoke, hard-deleting the pairing and its tokens', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    await bootstrapViewer(harness, camera);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(204);

    expect(await harness.repository.getPairing(camera.pairingId)).toBeNull();
    expect(await harness.repository.listDevices(camera.pairingId)).toHaveLength(
      0,
    );
  });

  it('refuses further authentication once revoked', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );

    tick();
    const after = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(after.statusCode).toBe(401);
    expect(errorCode(after)).toBe('unknown_principal');
  });

  it('rejects the bootstrap principal: K_auth cannot revoke', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: camera.kAuth,
        pairingId: camera.pairingId,
        principal: BOOTSTRAP_PRINCIPAL,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('unknown_principal');
    expect(
      await harness.repository.getPairing(camera.pairingId),
    ).not.toBeNull();
  });
});

/**
 * The escalation protocol.md 1.1 closes. Under 1.0 the role travelled in the
 * header and any holder of `K_auth` — every viewer — could present `camera`.
 * Now the role comes from the device row the signing key belongs to, so a
 * viewer's key is a viewer's key on every route, and there is nothing a client
 * can put in a request to change that.
 */
describe('viewer key on camera-only routes', () => {
  let camera: CameraCredentials;
  let viewerId: string;
  let viewerKey: Buffer;
  let secondViewerId: string;

  beforeEach(async () => {
    camera = await bootstrapCamera(harness);
    tick();
    const viewer = await bootstrapViewer(harness, camera);
    viewerId = viewer.deviceId;
    viewerKey = viewer.deviceKey;
    tick();
    secondViewerId = (await bootstrapViewer(harness, camera, 'd'.repeat(64)))
      .deviceId;
    tick();
  });

  it('cannot revoke the pairing', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: viewerKey,
        pairingId: camera.pairingId,
        principal: viewerId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
    expect(
      await harness.repository.getPairing(camera.pairingId),
    ).not.toBeNull();
  });

  it('cannot evict another viewer', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}/viewers/${secondViewerId}`,
        key: viewerKey,
        pairingId: camera.pairingId,
        principal: viewerId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
    expect(
      await harness.repository.getDevice(camera.pairingId, secondViewerId),
    ).not.toBeNull();
  });

  it('cannot post an event', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: viewerKey,
        pairingId: camera.pairingId,
        principal: viewerId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({ ciphertext: 'A'.repeat(64) }),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
    expect(harness.apns.sent).toHaveLength(0);
  });

  it('cannot borrow the camera principal without the camera key', async () => {
    // Claiming to be the camera is not enough: the MAC must verify under the
    // camera's key, which the viewer does not hold.
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}`,
        key: viewerKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('invalid_signature');
    expect(
      await harness.repository.getPairing(camera.pairingId),
    ).not.toBeNull();
  });
});

describe('DELETE /v1/pairings/:id/viewers/:deviceId', () => {
  it('lets the camera evict a single viewer', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const viewer = await bootstrapViewer(harness, camera);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}/viewers/${viewer.deviceId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(204);

    const devices = await harness.repository.listDevices(camera.pairingId);
    expect(devices.map((device) => device.role)).toEqual(['camera']);
    expect(
      await harness.repository.getPairing(camera.pairingId),
    ).not.toBeNull();
  });

  it('refuses to delete the camera device through the viewer route', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${camera.pairingId}/viewers/${camera.deviceId}`,
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(404);
    expect(await harness.repository.listDevices(camera.pairingId)).toHaveLength(
      1,
    );
  });

  it('answers 404 for a viewer of another pairing', async () => {
    const own = await bootstrapCamera(harness);
    tick();
    const other = await bootstrapCamera(harness);
    tick();
    const foreign = await bootstrapViewer(harness, other);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${own.pairingId}/viewers/${foreign.deviceId}`,
        key: own.deviceKey,
        pairingId: own.pairingId,
        principal: own.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(404);
    expect(await harness.repository.listDevices(other.pairingId)).toHaveLength(
      2,
    );
  });

  it('rejects a camera acting on a pairing that is not its own', async () => {
    const own = await bootstrapCamera(harness);
    tick();
    const other = await bootstrapCamera(harness);
    tick();
    const foreign = await bootstrapViewer(harness, other);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${other.pairingId}/viewers/${foreign.deviceId}`,
        key: own.deviceKey,
        pairingId: own.pairingId,
        principal: own.deviceId,
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('pairing_mismatch');
    expect(
      await harness.repository.getDevice(other.pairingId, foreign.deviceId),
    ).not.toBeNull();
  });
});

describe('PUT /v1/devices/token', () => {
  it('rotates the token of the authenticated device and answers 204', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const rotated = 'e'.repeat(64);

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          apnsToken: rotated,
          apnsEnvironment: 'production',
        }),
      }),
    );

    expect(response.statusCode).toBe(204);
    expect(response.body).toBe('');

    const device = await harness.repository.getDevice(
      camera.pairingId,
      camera.deviceId,
    );
    expect(device?.apnsToken).toBe(rotated);
    expect(device?.apnsEnvironment).toBe('production');
  });

  it('rejects a body that still carries a deviceId', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          deviceId: camera.deviceId,
          apnsToken: 'e'.repeat(64),
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(400);
    expect(errorCode(response)).toBe('invalid_body');
  });

  it('touches only the calling device, never another in the pairing', async () => {
    const camera = await bootstrapCamera(harness);
    tick();
    const viewer = await bootstrapViewer(harness, camera);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        key: viewer.deviceKey,
        pairingId: camera.pairingId,
        principal: viewer.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          apnsToken: 'f'.repeat(64),
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(204);

    const cameraDevice = await harness.repository.getDevice(
      camera.pairingId,
      camera.deviceId,
    );
    const viewerDevice = await harness.repository.getDevice(
      camera.pairingId,
      viewer.deviceId,
    );
    expect(cameraDevice?.apnsToken).toBe(CAMERA_TOKEN);
    expect(viewerDevice?.apnsToken).toBe('f'.repeat(64));
    expect(viewerDevice?.apnsToken).not.toBe(VIEWER_TOKEN);
  });

  it('rejects a device key from another pairing', async () => {
    const own = await bootstrapCamera(harness);
    tick();
    const other = await bootstrapCamera(harness);
    tick();

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        key: other.deviceKey,
        // The device belongs to `other`, but the header names `own`.
        pairingId: own.pairingId,
        principal: other.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          apnsToken: 'f'.repeat(64),
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('unknown_principal');

    const untouched = await harness.repository.getDevice(
      other.pairingId,
      other.deviceId,
    );
    expect(untouched?.apnsToken).toBe(CAMERA_TOKEN);
  });
});
