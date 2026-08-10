/**
 * Endpoint behaviour against the in-memory repository: role authorization,
 * limits, revocation, and the HTTP-level abuse cases.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import type { LightMyRequestResponse } from 'fastify';
import type { TestApp } from '../helpers/app.ts';
import {
  CAMERA_TOKEN,
  VIEWER_TOKEN,
  createTestApp,
  errorCode,
  jsonOf,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';

let harness: TestApp;
const kAuth = randomBytes(32);

function createBody(pairingId: string): string {
  return JSON.stringify({
    pairingId,
    kAuth: kAuth.toString('base64'),
    apnsToken: CAMERA_TOKEN,
    apnsEnvironment: 'sandbox',
  });
}

async function createPairing(
  pairingId: string = randomUUID(),
): Promise<{ pairingId: string; deviceId: string }> {
  const response = await harness.app.inject(
    signRequest({
      method: 'POST',
      path: '/v1/pairings',
      kAuth,
      pairingId,
      role: 'camera',
      timestampSeconds: secondsOf(harness.now()),
      body: createBody(pairingId),
    }),
  );
  expect(response.statusCode).toBe(201);
  const body = jsonOf<{ pairingId: string; deviceId: string }>(response);
  return body;
}

async function claim(
  pairingId: string,
  apnsToken = VIEWER_TOKEN,
): Promise<LightMyRequestResponse> {
  return harness.app.inject(
    signRequest({
      method: 'POST',
      path: `/v1/pairings/${pairingId}/claim`,
      kAuth,
      pairingId,
      role: 'viewer',
      timestampSeconds: secondsOf(harness.now()),
      body: JSON.stringify({ apnsToken, apnsEnvironment: 'sandbox' }),
    }),
  );
}

beforeEach(() => {
  harness = createTestApp();
});

afterEach(async () => {
  await harness.close();
});

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
      service: 'kidscam-backend',
    });
  });

  it('answers 404 with a structured error for unknown routes', async () => {
    const response = await harness.app.inject({ method: 'GET', url: '/nope' });
    expect(response.statusCode).toBe(404);
    expect(jsonOf(response)).toEqual({
      error: { code: 'not_found', message: 'Unknown endpoint' },
    });
  });
});

describe('POST /v1/pairings', () => {
  it('registers a pending pairing and a camera device', async () => {
    const pairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: createBody(pairingId),
      }),
    );

    expect(response.statusCode).toBe(201);
    const body = jsonOf<Record<string, unknown>>(response);
    expect(body['pairingId']).toBe(pairingId);
    expect(body['status']).toBe('pending');
    expect(body['ttlSeconds']).toBe(600);
    expect(typeof body['deviceId']).toBe('string');

    const stored = await harness.repository.getPairing(pairingId);
    expect(stored?.status).toBe('pending');
    // The response must never echo key material.
    expect(JSON.stringify(body)).not.toContain(kAuth.toString('base64'));
  });

  it('rejects a body whose pairingId differs from the signed one', async () => {
    const signedPairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId: signedPairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: createBody(randomUUID()),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('unknown_pairing');
  });

  it('rejects a request signed with a key other than the uploaded one', async () => {
    const pairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth: randomBytes(32),
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: createBody(pairingId),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('invalid_signature');
  });

  it('rejects the viewer role', async () => {
    const pairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'viewer',
        timestampSeconds: secondsOf(harness.now()),
        body: createBody(pairingId),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
  });

  it('rejects a K_auth of the wrong length', async () => {
    const pairingId = randomUUID();
    const body = JSON.stringify({
      pairingId,
      kAuth: randomBytes(16).toString('base64'),
      apnsToken: CAMERA_TOKEN,
      apnsEnvironment: 'sandbox',
    });
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body,
      }),
    );
    expect(response.statusCode).toBe(400);
  });

  it('rejects a malformed APNs token', async () => {
    const pairingId = randomUUID();
    const body = JSON.stringify({
      pairingId,
      kAuth: kAuth.toString('base64'),
      apnsToken: 'not-a-token',
      apnsEnvironment: 'sandbox',
    });
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body,
      }),
    );
    expect(response.statusCode).toBe(400);
  });

  it('rejects a duplicate pairing id', async () => {
    const { pairingId } = await createPairing();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        // A different timestamp keeps the replay cache out of the way.
        timestampSeconds: secondsOf(harness.now()) + 1,
        body: createBody(pairingId),
      }),
    );
    expect(response.statusCode).toBe(409);
    expect(errorCode(response)).toBe('pairing_exists');
  });

  it('rate-limits pairing creation per IP', async () => {
    const capacity = harness.config.rateLimits.pairingCreatePerIp.capacity;
    for (let i = 0; i < capacity; i += 1) {
      await createPairing();
    }
    const pairingId = randomUUID();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/pairings',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: createBody(pairingId),
      }),
    );
    expect(response.statusCode).toBe(429);
    expect(response.headers['retry-after']).toBeDefined();
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
  it('activates the pairing and registers the viewer', async () => {
    const { pairingId } = await createPairing();
    const response = await claim(pairingId);

    expect(response.statusCode).toBe(201);
    const body = jsonOf<Record<string, unknown>>(response);
    expect(body['status']).toBe('active');
    expect(body['role']).toBe('viewer');

    const devices = await harness.repository.listDevices(pairingId);
    expect(devices.map((device) => device.role).sort()).toEqual([
      'camera',
      'viewer',
    ]);
  });

  it('accepts at most five viewers', async () => {
    const { pairingId } = await createPairing();
    for (let i = 0; i < harness.config.maxViewersPerPairing; i += 1) {
      harness.setNow(new Date(harness.now().getTime() + 1000));
      const accepted = await claim(pairingId);
      expect(accepted.statusCode, `viewer ${i + 1}`).toBe(201);
    }

    harness.setNow(new Date(harness.now().getTime() + 1000));
    const rejected = await claim(pairingId);
    expect(rejected.statusCode).toBe(409);
    expect(errorCode(rejected)).toBe('viewer_limit_reached');

    const viewers = (await harness.repository.listDevices(pairingId)).filter(
      (device) => device.role === 'viewer',
    );
    expect(viewers).toHaveLength(harness.config.maxViewersPerPairing);
  });

  it('rejects the camera role', async () => {
    const { pairingId } = await createPairing();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${pairingId}/claim`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          apnsToken: VIEWER_TOKEN,
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
  });

  it('rejects credentials issued for a different pairing', async () => {
    const first = await createPairing();
    const second = await createPairing();

    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${second.pairingId}/claim`,
        kAuth,
        // Signed for the first pairing, aimed at the second.
        pairingId: first.pairingId,
        role: 'viewer',
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          apnsToken: VIEWER_TOKEN,
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('pairing_mismatch');

    const devices = await harness.repository.listDevices(second.pairingId);
    expect(devices.filter((device) => device.role === 'viewer')).toHaveLength(
      0,
    );
  });

  it('rejects a claim after the 10-minute TTL', async () => {
    const { pairingId } = await createPairing();
    harness.setNow(
      new Date(
        harness.now().getTime() + (harness.config.pairingTtlSeconds + 1) * 1000,
      ),
    );

    const response = await claim(pairingId);
    expect(response.statusCode).toBe(410);
    expect(errorCode(response)).toBe('pairing_expired');
  });

  it('still accepts a further viewer on an already active pairing after the TTL', async () => {
    const { pairingId } = await createPairing();
    expect((await claim(pairingId)).statusCode).toBe(201);

    harness.setNow(
      new Date(
        harness.now().getTime() + (harness.config.pairingTtlSeconds + 1) * 1000,
      ),
    );
    expect((await claim(pairingId)).statusCode).toBe(201);
  });

  it('rejects an expired request timestamp', async () => {
    const { pairingId } = await createPairing();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: `/v1/pairings/${pairingId}/claim`,
        kAuth,
        pairingId,
        role: 'viewer',
        timestampSeconds: secondsOf(harness.now()) - 61,
        body: JSON.stringify({
          apnsToken: VIEWER_TOKEN,
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('timestamp_out_of_window');
  });

  it('rejects a replayed request', async () => {
    const { pairingId } = await createPairing();
    const request = signRequest({
      method: 'POST',
      path: `/v1/pairings/${pairingId}/claim`,
      kAuth,
      pairingId,
      role: 'viewer',
      timestampSeconds: secondsOf(harness.now()),
      body: JSON.stringify({
        apnsToken: VIEWER_TOKEN,
        apnsEnvironment: 'sandbox',
      }),
    });

    expect((await harness.app.inject(request)).statusCode).toBe(201);
    const replay = await harness.app.inject(request);
    expect(replay.statusCode).toBe(401);
    expect(errorCode(replay)).toBe('replayed_request');

    const viewers = (await harness.repository.listDevices(pairingId)).filter(
      (device) => device.role === 'viewer',
    );
    expect(viewers).toHaveLength(1);
  });

  it('rejects a tampered body', async () => {
    const { pairingId } = await createPairing();
    const request = signRequest({
      method: 'POST',
      path: `/v1/pairings/${pairingId}/claim`,
      kAuth,
      pairingId,
      role: 'viewer',
      timestampSeconds: secondsOf(harness.now()),
      body: JSON.stringify({
        apnsToken: VIEWER_TOKEN,
        apnsEnvironment: 'sandbox',
      }),
    });

    const response = await harness.app.inject({
      ...request,
      payload: JSON.stringify({
        apnsToken: 'c'.repeat(64),
        apnsEnvironment: 'sandbox',
      }),
    });
    expect(response.statusCode).toBe(401);
    expect(errorCode(response)).toBe('invalid_signature');
  });
});

describe('DELETE /v1/pairings/:id', () => {
  it('lets the camera revoke, hard-deleting the pairing and its tokens', async () => {
    const { pairingId } = await createPairing();
    expect((await claim(pairingId)).statusCode).toBe(201);

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(204);

    expect(await harness.repository.getPairing(pairingId)).toBeNull();
    expect(await harness.repository.listDevices(pairingId)).toHaveLength(0);
  });

  it('refuses further authentication once revoked', async () => {
    const { pairingId } = await createPairing();
    await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );

    harness.setNow(new Date(harness.now().getTime() + 1000));
    const after = await claim(pairingId);
    expect(after.statusCode).toBe(401);
    expect(errorCode(after)).toBe('unknown_pairing');
  });

  it('rejects a caller presenting the viewer role', async () => {
    const { pairingId } = await createPairing();
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}`,
        kAuth,
        pairingId,
        role: 'viewer',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
  });
});

describe('DELETE /v1/pairings/:id/viewers/:deviceId', () => {
  it('lets the camera revoke a single viewer', async () => {
    const { pairingId } = await createPairing();
    const claimed = await claim(pairingId);
    const viewerId = jsonOf<{ deviceId: string }>(claimed).deviceId;

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}/viewers/${viewerId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(204);

    const devices = await harness.repository.listDevices(pairingId);
    expect(devices.map((device) => device.role)).toEqual(['camera']);
    expect(await harness.repository.getPairing(pairingId)).not.toBeNull();
  });

  it('refuses to delete the camera device through the viewer route', async () => {
    const { pairingId, deviceId } = await createPairing();
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}/viewers/${deviceId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(404);
    expect(await harness.repository.listDevices(pairingId)).toHaveLength(1);
  });

  it('refuses a viewer removing another viewer', async () => {
    const { pairingId } = await createPairing();
    const first = await claim(pairingId);
    harness.setNow(new Date(harness.now().getTime() + 1000));
    const second = await claim(pairingId, 'd'.repeat(64));
    const targetId = jsonOf<{ deviceId: string }>(second).deviceId;

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}/viewers/${targetId}`,
        kAuth,
        pairingId,
        role: 'viewer',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(403);
    expect(jsonOf<{ deviceId: string }>(first).deviceId).not.toBe(targetId);
    expect(await harness.repository.listDevices(pairingId)).toHaveLength(3);
  });

  it('answers 404 for a viewer of another pairing', async () => {
    const own = await createPairing();
    const other = await createPairing();
    harness.setNow(new Date(harness.now().getTime() + 1000));
    const foreignViewer = jsonOf<{ deviceId: string }>(
      await claim(other.pairingId),
    ).deviceId;

    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${own.pairingId}/viewers/${foreignViewer}`,
        kAuth,
        pairingId: own.pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(404);
    expect(await harness.repository.listDevices(other.pairingId)).toHaveLength(
      2,
    );
  });
});

describe('PUT /v1/devices/token', () => {
  it('rotates the token of the authenticated device', async () => {
    const { pairingId, deviceId } = await createPairing();
    const rotated = 'e'.repeat(64);

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          deviceId,
          apnsToken: rotated,
          apnsEnvironment: 'production',
        }),
      }),
    );

    expect(response.statusCode).toBe(200);
    const device = await harness.repository.getDevice(pairingId, deviceId);
    expect(device?.apnsToken).toBe(rotated);
    expect(device?.apnsEnvironment).toBe('production');
    // The response must not echo the token back.
    expect(response.body).not.toContain(rotated);
  });

  it('refuses to rotate a device of another pairing', async () => {
    const own = await createPairing();
    const other = await createPairing();

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        kAuth,
        pairingId: own.pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          deviceId: other.deviceId,
          apnsToken: 'f'.repeat(64),
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(404);

    const untouched = await harness.repository.getDevice(
      other.pairingId,
      other.deviceId,
    );
    expect(untouched?.apnsToken).toBe(CAMERA_TOKEN);
  });

  it('refuses to rotate a device registered under another role', async () => {
    const { pairingId } = await createPairing();
    const viewerId = jsonOf<{ deviceId: string }>(
      await claim(pairingId),
    ).deviceId;

    const response = await harness.app.inject(
      signRequest({
        method: 'PUT',
        path: '/v1/devices/token',
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({
          deviceId: viewerId,
          apnsToken: 'f'.repeat(64),
          apnsEnvironment: 'sandbox',
        }),
      }),
    );
    expect(response.statusCode).toBe(404);
  });
});

describe('documented protocol limitation', () => {
  it('accepts a camera-role header from any holder of K_auth', async () => {
    // shared/protocol.md does not bind the role into the canonical string, so
    // a revoked-but-not-yet-removed viewer can present `camera`. Recorded here
    // so a future protocol revision that fixes it fails this test loudly.
    const { pairingId } = await createPairing();
    expect((await claim(pairingId)).statusCode).toBe(201);

    harness.setNow(new Date(harness.now().getTime() + 1000));
    const response = await harness.app.inject(
      signRequest({
        method: 'DELETE',
        path: `/v1/pairings/${pairingId}`,
        kAuth,
        pairingId,
        role: 'camera',
        timestampSeconds: secondsOf(harness.now()),
      }),
    );
    expect(response.statusCode).toBe(204);
  });
});
