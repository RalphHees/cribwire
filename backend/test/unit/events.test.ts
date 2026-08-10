/**
 * `POST /v1/events`: camera-only, opaque passthrough, the 1-per-30 s
 * per-pairing limit, and APNs fan-out including the 410 cleanup.
 */

import { randomBytes } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { EVENT_ALERT_LOC_KEY } from '../../src/push/apns.ts';
import { MAX_CIPHERTEXT_BASE64_CHARS } from '../../src/http/validation.ts';
import type {
  CameraCredentials,
  TestApp,
  ViewerCredentials,
} from '../helpers/app.ts';
import {
  bootstrapCamera,
  bootstrapViewer,
  createTestApp,
  errorCode,
  secondsOf,
  signRequest,
} from '../helpers/app.ts';

let harness: TestApp;
let camera: CameraCredentials;
let viewer: ViewerCredentials;

/** A sealed envelope as the camera produces it; opaque to this server. */
function sealed(bytes = 48): string {
  return randomBytes(bytes).toString('base64');
}

function tick(seconds = 1): void {
  harness.setNow(new Date(harness.now().getTime() + seconds * 1000));
}

async function postEvent(
  ciphertext: string,
  credentials: { deviceKey: Buffer; deviceId: string } = camera,
): Promise<ReturnType<TestApp['app']['inject']>> {
  return harness.app.inject(
    signRequest({
      method: 'POST',
      path: '/v1/events',
      key: credentials.deviceKey,
      pairingId: camera.pairingId,
      principal: credentials.deviceId,
      timestampSeconds: secondsOf(harness.now()),
      body: JSON.stringify({ ciphertext }),
    }),
  );
}

beforeEach(async () => {
  harness = createTestApp();
  camera = await bootstrapCamera(harness);
  tick();
  viewer = await bootstrapViewer(harness, camera);
  tick();
});

afterEach(async () => {
  await harness.close();
});

describe('POST /v1/events', () => {
  it('accepts a camera event and fans it out unchanged', async () => {
    const ciphertext = sealed(120);
    const response = await postEvent(ciphertext);

    expect(response.statusCode).toBe(202);
    expect(response.body).toBe('');

    expect(harness.apns.sent).toHaveLength(1);
    const delivered = harness.apns.sent[0];
    expect(delivered?.notification.deviceToken).toBe(viewer.apnsToken);
    expect(delivered?.notification.environment).toBe('sandbox');
    // Byte-for-byte: the server neither decrypts nor re-encodes.
    expect(delivered?.payload.ciphertext).toBe(ciphertext);
    expect(delivered?.payload.pairingId).toBe(camera.pairingId);
    expect(delivered?.payload.aps).toEqual({
      alert: { 'loc-key': EVENT_ALERT_LOC_KEY },
      'mutable-content': 1,
    });
  });

  it('fans out to every viewer but never to the camera', async () => {
    const second = await bootstrapViewer(harness, camera, 'c'.repeat(64));
    tick();

    await postEvent(sealed());
    expect(harness.apns.tokens().sort()).toEqual(
      [viewer.apnsToken, second.apnsToken].sort(),
    );
  });

  it('accepts an event on a pairing with no viewers yet', async () => {
    const lonely = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: lonely.deviceKey,
        pairingId: lonely.pairingId,
        principal: lonely.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({ ciphertext: sealed() }),
      }),
    );
    expect(response.statusCode).toBe(202);
    expect(harness.apns.sent).toHaveLength(0);
  });

  it('rejects a viewer posting an event', async () => {
    const response = await postEvent(sealed(), viewer);
    expect(response.statusCode).toBe(403);
    expect(errorCode(response)).toBe('role_not_permitted');
    expect(harness.apns.sent).toHaveLength(0);
  });

  it('rejects an unauthenticated event', async () => {
    const response = await harness.app.inject({
      method: 'POST',
      url: '/v1/events',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ ciphertext: sealed() }),
    });
    expect(response.statusCode).toBe(401);
    expect(harness.apns.sent).toHaveLength(0);
  });

  it('rejects a malformed or oversized ciphertext', async () => {
    const cases = [
      '',
      'not base64!!',
      'AA==',
      'A'.repeat(MAX_CIPHERTEXT_BASE64_CHARS + 4),
    ];
    for (const ciphertext of cases) {
      tick();
      const response = await postEvent(ciphertext);
      expect(response.statusCode, ciphertext.slice(0, 16)).toBe(400);
      expect(errorCode(response)).toBe('invalid_body');
    }
    expect(harness.apns.sent).toHaveLength(0);
  });

  it('rejects a body with an unknown field', async () => {
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: camera.deviceKey,
        pairingId: camera.pairingId,
        principal: camera.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({ ciphertext: sealed(), pairingId: camera.pairingId }),
      }),
    );
    expect(response.statusCode).toBe(400);
  });

  it('allows one event per 30 s per pairing', async () => {
    expect((await postEvent(sealed())).statusCode).toBe(202);

    tick(5);
    const tooSoon = await postEvent(sealed());
    expect(tooSoon.statusCode).toBe(429);
    expect(errorCode(tooSoon)).toBe('rate_limited');
    expect(Number(tooSoon.headers['retry-after'])).toBeGreaterThan(0);
    expect(harness.apns.sent).toHaveLength(1);

    tick(30);
    expect((await postEvent(sealed())).statusCode).toBe(202);
    expect(harness.apns.sent).toHaveLength(2);
  });

  it('limits each pairing separately', async () => {
    expect((await postEvent(sealed())).statusCode).toBe(202);

    const other = await bootstrapCamera(harness);
    tick();
    const response = await harness.app.inject(
      signRequest({
        method: 'POST',
        path: '/v1/events',
        key: other.deviceKey,
        pairingId: other.pairingId,
        principal: other.deviceId,
        timestampSeconds: secondsOf(harness.now()),
        body: JSON.stringify({ ciphertext: sealed() }),
      }),
    );
    expect(response.statusCode).toBe(202);
  });

  it('deletes a token APNs reports as unregistered', async () => {
    harness.apns.markUnregistered(viewer.apnsToken);

    const response = await postEvent(sealed());
    expect(response.statusCode).toBe(202);

    expect(
      await harness.repository.getDevice(camera.pairingId, viewer.deviceId),
    ).toBeNull();
    const remaining = await harness.repository.listDevices(camera.pairingId);
    expect(remaining.map((device) => device.role)).toEqual(['camera']);
  });

  it('keeps the pairing when a delivery merely fails', async () => {
    harness.apns.markFailing(viewer.apnsToken);

    const response = await postEvent(sealed());
    expect(response.statusCode).toBe(202);
    expect(
      await harness.repository.getDevice(camera.pairingId, viewer.deviceId),
    ).not.toBeNull();
    expect(harness.metrics.apnsCount('failed')).toBe(1);
  });

  it('counts fan-out results in the metrics', async () => {
    await postEvent(sealed());
    expect(harness.metrics.apnsCount('sent')).toBe(1);
    expect(harness.metrics.render()).toContain(
      'kidscam_apns_notifications_total{result="sent"} 1',
    );
    expect(harness.metrics.render()).toContain('kidscam_event_fanout_seconds_count 1');
  });
});
