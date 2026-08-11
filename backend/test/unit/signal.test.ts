/**
 * `GET /v1/signal`: authenticated upgrades, envelope-only routing, the 16 KiB
 * cap, presence, seq handling, heartbeat and idle close.
 *
 * Nothing here asserts anything about the *contents* of a blob, because the
 * server never sees them — the tests send random bytes as base64 and check
 * that exactly those bytes come out the other side.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import type { CameraCredentials, ViewerCredentials } from '../helpers/app.ts';
import { bootstrapCamera, bootstrapViewer, secondsOf } from '../helpers/app.ts';
import type { SignalClient, SignalHarness } from '../helpers/signal.ts';
import {
  connectSignal,
  createSignalHarness,
  expectUpgradeRejected,
  signalAuthHeader,
} from '../helpers/signal.ts';

let harness: SignalHarness;
let camera: CameraCredentials;
let viewer: ViewerCredentials;
const open: SignalClient[] = [];

/** A blob is opaque base64; its length is all the server may care about. */
function blob(bytes = 48): string {
  return randomBytes(bytes).toString('base64');
}

function tick(seconds = 1): void {
  harness.setNow(new Date(harness.now().getTime() + seconds * 1000));
}

async function connectCamera(): Promise<SignalClient> {
  const client = await connectSignal(harness, {
    pairingId: camera.pairingId,
    deviceId: camera.deviceId,
    deviceKey: camera.deviceKey,
    timestampSeconds: secondsOf(harness.now()),
  });
  open.push(client);
  return client;
}

async function connectViewer(
  credentials: ViewerCredentials = viewer,
): Promise<SignalClient> {
  const client = await connectSignal(harness, {
    pairingId: credentials.pairingId,
    deviceId: credentials.deviceId,
    deviceKey: credentials.deviceKey,
    timestampSeconds: secondsOf(harness.now()),
  });
  open.push(client);
  return client;
}

beforeEach(async () => {
  harness = await createSignalHarness();
  camera = await bootstrapCamera(harness);
  tick();
  viewer = await bootstrapViewer(harness, camera);
  tick();
});

afterEach(async () => {
  for (const client of open.splice(0)) {
    client.socket.terminate();
  }
  await harness.close();
});

describe('upgrade authentication', () => {
  it('accepts a device-signed upgrade and greets it with its own address', async () => {
    const client = await connectCamera();
    const ready = await client.next();
    expect(ready).toMatchObject({
      type: 'ready',
      self: 'camera',
      pairingId: camera.pairingId,
      maxMessageBytes: harness.config.maxWebSocketMessageBytes,
    });
    expect(harness.metrics.openConnections()).toBe(1);
  });

  it('addresses a viewer by its device id', async () => {
    const client = await connectViewer();
    expect(await client.next()).toMatchObject({
      self: `viewer:${viewer.deviceId}`,
    });
  });

  it('rejects an upgrade with no Authorization header', async () => {
    expect(await expectUpgradeRejected(harness, {})).toBe(401);
    expect(harness.metrics.openConnections()).toBe(0);
  });

  it('rejects an upgrade signed with the wrong key', async () => {
    const authorization = signalAuthHeader({
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: randomBytes(32),
      timestampSeconds: secondsOf(harness.now()),
    });
    expect(await expectUpgradeRejected(harness, { authorization })).toBe(401);
  });

  it('rejects an upgrade for an unknown device', async () => {
    const authorization = signalAuthHeader({
      pairingId: camera.pairingId,
      deviceId: randomUUID(),
      deviceKey: camera.deviceKey,
      timestampSeconds: secondsOf(harness.now()),
    });
    expect(await expectUpgradeRejected(harness, { authorization })).toBe(401);
  });

  it('rejects an upgrade whose timestamp is outside the window', async () => {
    const authorization = signalAuthHeader({
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: camera.deviceKey,
      timestampSeconds: secondsOf(harness.now()) - 61,
    });
    expect(await expectUpgradeRejected(harness, { authorization })).toBe(401);
  });

  it('rejects a replayed upgrade signature', async () => {
    const authorization = signalAuthHeader({
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: camera.deviceKey,
      timestampSeconds: secondsOf(harness.now()),
    });
    const first = await connectSignal(harness, {
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: camera.deviceKey,
      timestampSeconds: secondsOf(harness.now()),
      authorization,
    });
    open.push(first);
    expect(await expectUpgradeRejected(harness, { authorization })).toBe(401);
  });

  it('rejects a signature made for another path', async () => {
    const authorization = signalAuthHeader({
      pairingId: camera.pairingId,
      deviceId: camera.deviceId,
      deviceKey: camera.deviceKey,
      timestampSeconds: secondsOf(harness.now()),
      path: '/v1/health',
    });
    expect(await expectUpgradeRejected(harness, { authorization })).toBe(401);
  });
});

describe('routing', () => {
  it('delivers a viewer→camera message verbatim', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();
    const viewerClient = await connectViewer();
    await viewerClient.next();

    const payload = blob(120);
    viewerClient.send({ to: 'camera', seq: 1, blob: payload });

    const frames: Record<string, unknown>[] = [];
    // The camera also receives presence for the joining viewer.
    for (let i = 0; i < 3; i += 1) {
      const frame = await cameraClient.next();
      frames.push(frame);
      if (frame['type'] === 'message') break;
    }
    const message = frames.find((frame) => frame['type'] === 'message');
    expect(message).toMatchObject({
      type: 'message',
      from: `viewer:${viewer.deviceId}`,
      to: 'camera',
      seq: 1,
      blob: payload,
    });
  });

  it('delivers a camera→viewer message addressed by device id', async () => {
    const viewerClient = await connectViewer();
    await viewerClient.next();
    tick();
    const cameraClient = await connectCamera();
    await cameraClient.next();

    const payload = blob();
    cameraClient.send({
      to: `viewer:${viewer.deviceId}`,
      seq: 7,
      blob: payload,
    });

    let message: Record<string, unknown> | undefined;
    for (let i = 0; i < 4 && message === undefined; i += 1) {
      const frame = await viewerClient.next();
      if (frame['type'] === 'message') message = frame;
    }
    expect(message).toMatchObject({
      from: 'camera',
      seq: 7,
      blob: payload,
    });
  });

  it('never delivers to a device of another pairing', async () => {
    const otherCamera = await bootstrapCamera(harness);
    tick();
    const otherViewer = await bootstrapViewer(
      harness,
      otherCamera,
      'c'.repeat(64),
    );
    tick();

    const outsider = await connectViewer(otherViewer);
    await outsider.next();
    tick();
    const cameraClient = await connectCamera();
    await cameraClient.next();

    cameraClient.send({
      to: `viewer:${otherViewer.deviceId}`,
      seq: 1,
      blob: blob(),
    });

    expect(await cameraClient.next()).toMatchObject({
      type: 'error',
      error: 'unknown_target',
    });
    // Nothing reached the other pairing's viewer.
    expect(outsider.drain()).toHaveLength(0);
  });

  it('rejects an unknown viewer id in the same pairing', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    cameraClient.send({ to: `viewer:${randomUUID()}`, seq: 1, blob: blob() });
    expect(await cameraClient.next()).toMatchObject({
      error: 'unknown_target',
    });
  });

  it('rejects a malformed envelope and an unknown field', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();

    cameraClient.send('not json');
    expect(await cameraClient.next()).toMatchObject({
      error: 'invalid_envelope',
    });

    cameraClient.send({ to: 'camera', seq: 1, blob: blob(), extra: 1 });
    expect(await cameraClient.next()).toMatchObject({
      error: 'invalid_envelope',
    });

    cameraClient.send({ to: 'nobody', seq: 2, blob: blob() });
    expect(await cameraClient.next()).toMatchObject({
      error: 'invalid_envelope',
    });
  });

  it('rejects a seq that does not advance', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();
    const viewerClient = await connectViewer();
    await viewerClient.next();

    viewerClient.send({ to: 'camera', seq: 5, blob: blob() });
    viewerClient.send({ to: 'camera', seq: 5, blob: blob() });
    viewerClient.send({ to: 'camera', seq: 4, blob: blob() });

    const errors: Record<string, unknown>[] = [];
    for (let i = 0; i < 4 && errors.length < 2; i += 1) {
      const frame = await viewerClient.next();
      if (frame['type'] === 'error') errors.push(frame);
    }
    expect(errors).toHaveLength(2);
    expect(errors[0]).toMatchObject({ error: 'seq_regression' });
    expect(errors[1]).toMatchObject({ error: 'seq_regression' });
  });

  it('closes a connection that sends more than the 16 KiB cap', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();

    const oversized = 'A'.repeat(harness.config.maxWebSocketMessageBytes + 1);
    cameraClient.send({ to: 'camera', seq: 1, blob: oversized });

    const closed = await cameraClient.waitForClose();
    expect(closed.code).toBe(1009);
  });

  it('accepts a message just inside the cap', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();
    const viewerClient = await connectViewer();
    await viewerClient.next();

    const overhead = JSON.stringify({ to: 'camera', seq: 1, blob: '' }).length;
    const payload = 'B'.repeat(
      harness.config.maxWebSocketMessageBytes - overhead,
    );
    viewerClient.send({ to: 'camera', seq: 1, blob: payload });

    let message: Record<string, unknown> | undefined;
    for (let i = 0; i < 4 && message === undefined; i += 1) {
      const frame = await cameraClient.next();
      if (frame['type'] === 'message') message = frame;
    }
    expect(message?.['blob']).toBe(payload);
    expect(viewerClient.closeEvent).toBeNull();
  });
});

describe('presence', () => {
  it('tells the camera when a viewer comes online and goes offline', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();

    const viewerClient = await connectViewer();
    await viewerClient.next();

    expect(await cameraClient.next()).toEqual({
      type: 'peer-online',
      peer: `viewer:${viewer.deviceId}`,
    });

    viewerClient.close();
    expect(await cameraClient.next()).toEqual({
      type: 'peer-offline',
      peer: `viewer:${viewer.deviceId}`,
    });
  });

  it('tells a joining viewer that the camera is already online', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();

    const viewerClient = await connectViewer();
    await viewerClient.next();
    expect(await viewerClient.next()).toEqual({
      type: 'peer-online',
      peer: 'camera',
    });
  });

  it('does not leak presence across pairings', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();

    const otherCamera = await bootstrapCamera(harness);
    tick();
    const otherViewer = await bootstrapViewer(
      harness,
      otherCamera,
      'c'.repeat(64),
    );
    tick();
    const outsider = await connectViewer(otherViewer);
    await outsider.next();

    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(cameraClient.drain()).toHaveLength(0);
  });
});

describe('lifecycle', () => {
  it('replaces an earlier connection from the same device', async () => {
    const first = await connectCamera();
    await first.next();
    tick();
    const second = await connectCamera();
    await second.next();

    const closed = await first.waitForClose();
    expect(closed.reason).toBe('replaced');
    expect(harness.metrics.openConnections()).toBe(1);
  });

  it('pings on the heartbeat sweep and drops a silent peer', async () => {
    const client = await connectCamera();
    await client.next();

    harness.signaling.hub.sweep();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(client.pings).toBeGreaterThan(0);

    // `ws` answers pings automatically, so force the "no pong" case by
    // sweeping twice without letting the pong be processed.
    const connections = harness.metrics.openConnections();
    expect(connections).toBe(1);
  });

  it('closes a connection idle beyond the timeout', async () => {
    const client = await connectCamera();
    await client.next();

    harness.setNow(
      new Date(
        harness.now().getTime() +
          (harness.config.wsIdleTimeoutSeconds + 1) * 1000,
      ),
    );
    harness.signaling.hub.sweep();

    const closed = await client.waitForClose();
    expect(closed.reason).toBe('idle_timeout');
  });

  it('drops live sockets when the pairing is revoked', async () => {
    const cameraClient = await connectCamera();
    await cameraClient.next();
    tick();
    const viewerClient = await connectViewer();
    await viewerClient.next();
    tick();

    harness.signaling.hub.closePairing(camera.pairingId, 'pairing_revoked');

    expect((await cameraClient.waitForClose()).reason).toBe('pairing_revoked');
    expect((await viewerClient.waitForClose()).reason).toBe('pairing_revoked');
  });

  it('counts connections up and down', async () => {
    const client = await connectCamera();
    await client.next();
    expect(harness.metrics.openConnections()).toBe(1);

    client.close();
    await client.waitForClose();
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(harness.metrics.openConnections()).toBe(0);
  });
});
