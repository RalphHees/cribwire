/**
 * Signaling connection registry and router — backend.md §3 "WebSocket".
 *
 * What the hub knows about a message: who sent it, which address it is for,
 * its `seq`, and its size. What it never knows: what is inside `blob`. Routing
 * decisions are made from the envelope and the `devices` table only.
 *
 * Every message and presence event goes out over the bus and comes back to the
 * instances that hold the addressed connections, so a camera on instance A and
 * a viewer on instance B talk exactly as if they shared a process.
 */

import type { Config } from '../config.ts';
import type { Device } from '../domain/types.ts';
import type { Logger } from '../logger.ts';
import type { Metrics } from '../metrics/registry.ts';
import type { Repository } from '../repositories/types.ts';
import type { BusMessage, MessageBus } from './bus.ts';
import type { Address, ServerFrame } from './protocol.ts';
import {
  CLOSE_CODES,
  addressOf,
  encodeFrame,
  parseClientEnvelope,
  parseTarget,
} from './protocol.ts';

/** The part of a WebSocket the hub uses; keeps `ws` out of the router. */
export interface SignalingSocket {
  send(data: string): void;
  ping(): void;
  close(code?: number, reason?: string): void;
  terminate(): void;
}

export interface Connection {
  readonly socket: SignalingSocket;
  readonly pairingId: string;
  readonly deviceId: string;
  readonly address: Address;
  readonly cameraDeviceId: string | null;
  /** Highest `seq` accepted from this connection; regressions are rejected. */
  lastSeq: number | null;
  lastActivityMs: number;
  awaitingPong: boolean;
  closed: boolean;
}

export interface HubDependencies {
  readonly config: Config;
  readonly repository: Repository;
  readonly bus: MessageBus;
  readonly logger: Logger;
  readonly metrics: Metrics;
  readonly now: () => Date;
}

/**
 * Lets REST routes drop live sockets the moment their credentials die, so a
 * revoked viewer does not keep an already-open channel.
 */
export interface SignalingControl {
  closePairing(pairingId: string, reason: string): void;
  closeDevice(pairingId: string, deviceId: string, reason: string): void;
}

export class SignalingHub implements SignalingControl {
  readonly #deps: HubDependencies;
  /** pairingId → address → connection, for this instance only. */
  readonly #connections = new Map<string, Map<Address, Connection>>();
  #timer: NodeJS.Timeout | null = null;

  constructor(deps: HubDependencies) {
    this.#deps = deps;
    this.#deps.bus.setHandler((pairingId, message) => {
      this.#onBusMessage(pairingId, message);
    });
  }

  /** Starts the heartbeat/idle sweep. Unref'd: it never holds the process up. */
  start(): void {
    if (this.#timer !== null) return;
    const intervalMs = this.#deps.config.wsHeartbeatSeconds * 1000;
    this.#timer = setInterval(() => {
      this.sweep();
    }, intervalMs);
    this.#timer.unref();
  }

  connectionCount(): number {
    let total = 0;
    for (const byAddress of this.#connections.values()) {
      total += byAddress.size;
    }
    return total;
  }

  /**
   * Registers an authenticated socket. The camera device id is resolved once
   * here: a pairing has exactly one camera row for its whole life, so `to:
   * "camera"` needs no further lookups.
   */
  async attach(
    socket: SignalingSocket,
    device: Device,
  ): Promise<Connection> {
    const address = addressOf(device);
    const devices = await this.#deps.repository.listDevices(device.pairingId);
    const camera = devices.find((candidate) => candidate.role === 'camera');

    const connection: Connection = {
      socket,
      pairingId: device.pairingId,
      deviceId: device.id,
      address,
      cameraDeviceId: camera?.id ?? null,
      lastSeq: null,
      lastActivityMs: this.#deps.now().getTime(),
      awaitingPong: false,
      closed: false,
    };

    let byAddress = this.#connections.get(device.pairingId);
    if (byAddress === undefined) {
      byAddress = new Map<Address, Connection>();
      this.#connections.set(device.pairingId, byAddress);
      await this.#deps.bus.subscribe(device.pairingId);
    }

    // One live connection per device: a reconnect supersedes the stale socket.
    const previous = byAddress.get(address);
    if (previous !== undefined) {
      previous.closed = true;
      byAddress.delete(address);
      previous.socket.close(CLOSE_CODES.policyViolation, 'replaced');
      this.#deps.metrics.wsConnectionClosed();
    }
    byAddress.set(address, connection);
    this.#deps.metrics.wsConnectionOpened();

    this.#send(connection, {
      type: 'ready',
      self: address,
      pairingId: device.pairingId,
      heartbeatSeconds: this.#deps.config.wsHeartbeatSeconds,
      idleTimeoutSeconds: this.#deps.config.wsIdleTimeoutSeconds,
      maxMessageBytes: this.#deps.config.maxWebSocketMessageBytes,
    });

    await this.#deps.repository.touchDevice(device.id, this.#deps.now());
    await this.#deps.bus.publish(device.pairingId, {
      kind: 'presence',
      event: 'peer-online',
      peer: address,
    });

    this.#deps.logger.info('signal connected', {
      pairingId: device.pairingId,
      role: device.role,
    });
    return connection;
  }

  /** Handles one client frame. `raw` is never logged and never decoded. */
  async handleMessage(connection: Connection, raw: string): Promise<void> {
    if (connection.closed) return;
    connection.lastActivityMs = this.#deps.now().getTime();

    const limit = this.#deps.config.maxWebSocketMessageBytes;
    if (Buffer.byteLength(raw, 'utf8') > limit) {
      // `ws` enforces the same cap at the frame level; this covers any path
      // that reaches the router without it.
      this.#deps.metrics.wsMessage('too_large');
      this.#fail(
        connection,
        'message_too_large',
        `Messages are limited to ${limit} bytes`,
        CLOSE_CODES.messageTooBig,
      );
      return;
    }

    const parsed = parseClientEnvelope(raw, limit);
    if (!parsed.ok) {
      this.#deps.metrics.wsMessage('malformed');
      this.#error(connection, 'invalid_envelope', `Envelope ${parsed.code}`);
      return;
    }
    const envelope = parsed.envelope;

    if (connection.lastSeq !== null && envelope.seq <= connection.lastSeq) {
      this.#deps.metrics.wsMessage('seq_regression');
      this.#error(
        connection,
        'seq_regression',
        'seq must increase strictly per sender',
      );
      return;
    }

    const target = parseTarget(envelope.to);
    if (target === null || !(await this.#targetExists(connection, target))) {
      this.#deps.metrics.wsMessage('unknown_target');
      this.#error(
        connection,
        'unknown_target',
        'No such peer in this pairing',
      );
      return;
    }

    connection.lastSeq = envelope.seq;
    this.#deps.metrics.wsMessage('routed');
    await this.#deps.bus.publish(connection.pairingId, {
      kind: 'envelope',
      from: connection.address,
      to: envelope.to,
      seq: envelope.seq,
      blob: envelope.blob,
    });
  }

  handlePong(connection: Connection): void {
    connection.awaitingPong = false;
  }

  /** Removes a closed socket and tells the pairing it went away. */
  async detach(connection: Connection): Promise<void> {
    const byAddress = this.#connections.get(connection.pairingId);
    if (byAddress === undefined) return;
    if (byAddress.get(connection.address) !== connection) return;

    byAddress.delete(connection.address);
    connection.closed = true;
    this.#deps.metrics.wsConnectionClosed();

    await this.#deps.bus.publish(connection.pairingId, {
      kind: 'presence',
      event: 'peer-offline',
      peer: connection.address,
    });

    if (byAddress.size === 0) {
      this.#connections.delete(connection.pairingId);
      await this.#deps.bus.unsubscribe(connection.pairingId);
    }
  }

  closePairing(pairingId: string, reason: string): void {
    const byAddress = this.#connections.get(pairingId);
    if (byAddress === undefined) return;
    for (const connection of [...byAddress.values()]) {
      this.#closeConnection(connection, reason);
    }
  }

  closeDevice(pairingId: string, deviceId: string, reason: string): void {
    const byAddress = this.#connections.get(pairingId);
    if (byAddress === undefined) return;
    for (const connection of [...byAddress.values()]) {
      if (connection.deviceId === deviceId) {
        this.#closeConnection(connection, reason);
      }
    }
  }

  /** Heartbeat and idle enforcement; exposed for tests to drive directly. */
  sweep(): void {
    const nowMs = this.#deps.now().getTime();
    const idleMs = this.#deps.config.wsIdleTimeoutSeconds * 1000;
    for (const byAddress of [...this.#connections.values()]) {
      for (const connection of [...byAddress.values()]) {
        if (nowMs - connection.lastActivityMs >= idleMs) {
          this.#closeConnection(connection, 'idle_timeout');
          continue;
        }
        if (connection.awaitingPong) {
          // Missed a whole heartbeat interval: the peer is gone.
          connection.socket.terminate();
          continue;
        }
        connection.awaitingPong = true;
        connection.socket.ping();
      }
    }
  }

  async close(): Promise<void> {
    if (this.#timer !== null) {
      clearInterval(this.#timer);
      this.#timer = null;
    }
    for (const [pairingId, byAddress] of this.#connections) {
      for (const connection of byAddress.values()) {
        connection.closed = true;
        connection.socket.close(CLOSE_CODES.normal, 'server_shutdown');
        this.#deps.metrics.wsConnectionClosed();
      }
      await this.#deps.bus.unsubscribe(pairingId);
    }
    this.#connections.clear();
  }

  async #targetExists(
    connection: Connection,
    target: { kind: 'camera' } | { kind: 'viewer'; deviceId: string },
  ): Promise<boolean> {
    if (target.kind === 'camera') {
      return connection.cameraDeviceId !== null;
    }
    // Cross-pairing addressing is impossible: the lookup is scoped to the
    // sender's own pairing, so a viewer id from another pairing simply is not
    // found.
    const device = await this.#deps.repository.getDevice(
      connection.pairingId,
      target.deviceId,
    );
    return device !== null && device.role === 'viewer';
  }

  #onBusMessage(pairingId: string, message: BusMessage): void {
    const byAddress = this.#connections.get(pairingId);
    if (byAddress === undefined) return;

    if (message.kind === 'envelope') {
      const target = byAddress.get(message.to);
      if (target === undefined || target.closed) return;
      this.#send(target, {
        type: 'message',
        from: message.from,
        to: message.to,
        seq: message.seq,
        blob: message.blob,
      });
      return;
    }

    if (message.to !== undefined) {
      // Directed announce-back: only the joining peer hears it.
      const target = byAddress.get(message.to);
      if (target !== undefined && !target.closed) {
        this.#send(target, { type: message.event, peer: message.peer });
      }
      return;
    }

    for (const connection of byAddress.values()) {
      if (connection.address === message.peer || connection.closed) continue;
      this.#send(connection, { type: message.event, peer: message.peer });
      if (message.event === 'peer-online') {
        // Tell the joiner that this connection is already online. Directed, so
        // it triggers no further announcements.
        void this.#deps.bus.publish(pairingId, {
          kind: 'presence',
          event: 'peer-online',
          peer: connection.address,
          to: message.peer,
        });
      }
    }
  }

  #closeConnection(connection: Connection, reason: string): void {
    if (connection.closed) return;
    connection.closed = true;
    connection.socket.close(CLOSE_CODES.policyViolation, reason);
  }

  #error(connection: Connection, code: string, message: string): void {
    this.#send(connection, { type: 'error', error: code, message });
  }

  #fail(
    connection: Connection,
    code: string,
    message: string,
    closeCode: number,
  ): void {
    this.#error(connection, code, message);
    connection.closed = true;
    connection.socket.close(closeCode, code);
  }

  #send(connection: Connection, frame: ServerFrame): void {
    try {
      connection.socket.send(encodeFrame(frame));
    } catch (error) {
      this.#deps.logger.warn('signal send failed', {
        reason: error instanceof Error ? error.message : 'unknown',
      });
    }
  }
}
