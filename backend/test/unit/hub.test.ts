/**
 * Router-level tests with fake sockets: the paths that are awkward to force
 * over a real WebSocket — a peer that never answers a ping, and two hubs that
 * stand in for two API instances sharing one bus.
 */

import { beforeEach, describe, expect, it } from 'vitest';
import { randomBytes, randomUUID } from 'node:crypto';
import { loadConfig } from '../../src/config.ts';
import type { Config } from '../../src/config.ts';
import { createLogger } from '../../src/logger.ts';
import { Metrics } from '../../src/metrics/registry.ts';
import { MemoryRepository } from '../../src/repositories/memory.ts';
import type { Device } from '../../src/domain/types.ts';
import { MemoryBusBroker, MemoryMessageBus } from '../../src/ws/bus.ts';
import type { SignalingSocket } from '../../src/ws/hub.ts';
import { SignalingHub } from '../../src/ws/hub.ts';

class FakeSocket implements SignalingSocket {
  readonly frames: Record<string, unknown>[] = [];
  pings = 0;
  terminated = false;
  closedWith: { code: number | undefined; reason: string | undefined } | null =
    null;

  send(data: string): void {
    this.frames.push(JSON.parse(data) as Record<string, unknown>);
  }

  ping(): void {
    this.pings += 1;
  }

  close(code?: number, reason?: string): void {
    this.closedWith = { code, reason };
  }

  terminate(): void {
    this.terminated = true;
  }

  typed(type: string): Record<string, unknown>[] {
    return this.frames.filter((frame) => frame['type'] === type);
  }
}

const config: Config = loadConfig({ NODE_ENV: 'test' });
let clock = new Date('2026-08-10T12:00:00.000Z');
let repository: MemoryRepository;
let broker: MemoryBusBroker;

async function seedPairing(): Promise<{ camera: Device; viewer: Device }> {
  const pairingId = randomUUID();
  const created = await repository.createPairing({
    pairingId,
    kAuth: randomBytes(32),
    cameraDeviceId: randomUUID(),
    cameraDeviceKey: randomBytes(32),
    apnsToken: 'a'.repeat(64),
    apnsEnvironment: 'sandbox',
    now: clock,
  });
  if (!created.ok) throw new Error('seed failed');
  const claimed = await repository.claimPairing({
    pairingId,
    viewerDeviceId: randomUUID(),
    viewerDeviceKey: randomBytes(32),
    apnsToken: 'b'.repeat(64),
    apnsEnvironment: 'sandbox',
    maxViewers: 5,
    expiredBefore: new Date(clock.getTime() - 600_000),
    now: clock,
  });
  if (!claimed.ok) throw new Error('claim failed');
  return { camera: created.device, viewer: claimed.device };
}

/** Each hub gets its own bus client on the shared broker: one API instance. */
function createHub(): SignalingHub {
  return new SignalingHub({
    config,
    repository,
    bus: new MemoryMessageBus(broker),
    logger: createLogger('silent'),
    metrics: new Metrics(),
    now: () => clock,
  });
}

beforeEach(() => {
  clock = new Date('2026-08-10T12:00:00.000Z');
  repository = new MemoryRepository();
  broker = new MemoryBusBroker();
});

describe('heartbeat and idle', () => {
  it('terminates a peer that misses a pong between sweeps', async () => {
    const hub = createHub();
    const { camera } = await seedPairing();
    const socket = new FakeSocket();
    await hub.attach(socket, camera);

    hub.sweep();
    expect(socket.pings).toBe(1);
    expect(socket.terminated).toBe(false);

    // No pong arrived before the next sweep.
    hub.sweep();
    expect(socket.terminated).toBe(true);
  });

  it('keeps a peer that answers the ping', async () => {
    const hub = createHub();
    const { camera } = await seedPairing();
    const socket = new FakeSocket();
    const connection = await hub.attach(socket, camera);

    hub.sweep();
    hub.handlePong(connection);
    hub.sweep();
    expect(socket.terminated).toBe(false);
    expect(socket.pings).toBe(2);
  });

  it('closes a connection idle past the timeout', async () => {
    const hub = createHub();
    const { camera } = await seedPairing();
    const socket = new FakeSocket();
    await hub.attach(socket, camera);

    clock = new Date(clock.getTime() + (config.wsIdleTimeoutSeconds + 1) * 1000);
    hub.sweep();
    expect(socket.closedWith?.reason).toBe('idle_timeout');
  });

  it('an incoming message refreshes the idle clock', async () => {
    const hub = createHub();
    const { camera, viewer } = await seedPairing();
    const socket = new FakeSocket();
    const connection = await hub.attach(socket, camera);

    clock = new Date(clock.getTime() + (config.wsIdleTimeoutSeconds - 1) * 1000);
    await hub.handleMessage(
      connection,
      JSON.stringify({
        to: `viewer:${viewer.id}`,
        seq: 1,
        blob: randomBytes(32).toString('base64'),
      }),
    );

    clock = new Date(clock.getTime() + 2000);
    hub.sweep();
    expect(socket.closedWith).toBeNull();
  });
});

describe('cross-instance routing over the bus', () => {
  it('delivers a message to a peer attached to another hub', async () => {
    const instanceA = createHub();
    const instanceB = createHub();
    const { camera, viewer } = await seedPairing();

    const cameraSocket = new FakeSocket();
    const viewerSocket = new FakeSocket();
    const cameraConnection = await instanceA.attach(cameraSocket, camera);
    await instanceB.attach(viewerSocket, viewer);

    const payload = randomBytes(64).toString('base64');
    await instanceA.handleMessage(
      cameraConnection,
      JSON.stringify({ to: `viewer:${viewer.id}`, seq: 1, blob: payload }),
    );

    expect(viewerSocket.typed('message')).toEqual([
      {
        type: 'message',
        from: 'camera',
        to: `viewer:${viewer.id}`,
        seq: 1,
        blob: payload,
      },
    ]);
    // The sender's own instance must not echo it back to the sender.
    expect(cameraSocket.typed('message')).toHaveLength(0);
  });

  it('announces presence in both directions across instances', async () => {
    const instanceA = createHub();
    const instanceB = createHub();
    const { camera, viewer } = await seedPairing();

    const cameraSocket = new FakeSocket();
    await instanceA.attach(cameraSocket, camera);

    const viewerSocket = new FakeSocket();
    await instanceB.attach(viewerSocket, viewer);

    expect(cameraSocket.typed('peer-online')).toEqual([
      { type: 'peer-online', peer: `viewer:${viewer.id}` },
    ]);
    // The joining viewer is told the camera is already there.
    expect(viewerSocket.typed('peer-online')).toEqual([
      { type: 'peer-online', peer: 'camera' },
    ]);
  });

  it('reports a peer going offline to the other instance', async () => {
    const instanceA = createHub();
    const instanceB = createHub();
    const { camera, viewer } = await seedPairing();

    const cameraSocket = new FakeSocket();
    await instanceA.attach(cameraSocket, camera);
    const viewerSocket = new FakeSocket();
    const viewerConnection = await instanceB.attach(viewerSocket, viewer);

    await instanceB.detach(viewerConnection);
    expect(cameraSocket.typed('peer-offline')).toEqual([
      { type: 'peer-offline', peer: `viewer:${viewer.id}` },
    ]);
  });

  it('keeps pairings isolated on a shared bus', async () => {
    const instanceA = createHub();
    const instanceB = createHub();
    const first = await seedPairing();
    const second = await seedPairing();

    const outsiderSocket = new FakeSocket();
    await instanceB.attach(outsiderSocket, second.viewer);

    const cameraSocket = new FakeSocket();
    const cameraConnection = await instanceA.attach(cameraSocket, first.camera);
    await instanceA.handleMessage(
      cameraConnection,
      JSON.stringify({
        to: `viewer:${second.viewer.id}`,
        seq: 1,
        blob: randomBytes(16).toString('base64'),
      }),
    );

    expect(outsiderSocket.typed('message')).toHaveLength(0);
    expect(cameraSocket.typed('error')).toEqual([
      expect.objectContaining({ error: 'unknown_target' }),
    ]);
  });

  it('unsubscribes from the bus once the last local peer leaves', async () => {
    const hub = createHub();
    const { camera } = await seedPairing();
    const socket = new FakeSocket();
    const connection = await hub.attach(socket, camera);
    await hub.detach(connection);
    expect(hub.connectionCount()).toBe(0);
  });
});

describe('sequence handling', () => {
  it('rejects a repeated or lower seq, even when frames arrive together', async () => {
    const hub = createHub();
    const { camera, viewer } = await seedPairing();
    const socket = new FakeSocket();
    const connection = await hub.attach(socket, camera);

    const frame = (seq: number): string =>
      JSON.stringify({
        to: `viewer:${viewer.id}`,
        seq,
        blob: randomBytes(16).toString('base64'),
      });

    // Fired without awaiting in between: the hub must still serialise them.
    const results = [
      hub.handleMessage(connection, frame(5)),
      hub.handleMessage(connection, frame(5)),
      hub.handleMessage(connection, frame(4)),
      hub.handleMessage(connection, frame(6)),
    ];
    await Promise.all(results);

    const errors = socket.typed('error');
    expect(errors).toHaveLength(2);
    expect(errors.every((error) => error['error'] === 'seq_regression')).toBe(
      true,
    );
    expect(connection.lastSeq).toBe(6);
  });
});
