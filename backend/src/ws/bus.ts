/**
 * Cross-instance message bus for signaling (backend.md §2: "Redis pub/sub
 * bridge so two peers connected to different instances can exchange
 * messages").
 *
 * The API is stateless, so the two peers of a pairing routinely land on
 * different instances. Every routed message and presence event is published on
 * a per-pairing channel; each instance delivers what its own connections are
 * addressed by. Publishers receive their own messages back, so local and
 * remote delivery share one code path.
 *
 * Payloads cross the bus exactly as they arrived: `blob` is opaque base64 and
 * is never decoded here either.
 */

import type { Redis } from 'ioredis';
import type { Address } from './protocol.ts';

export interface BusEnvelope {
  readonly kind: 'envelope';
  readonly from: Address;
  readonly to: Address;
  readonly seq: number;
  readonly blob: string;
}

export interface BusPresence {
  readonly kind: 'presence';
  readonly event: 'peer-online' | 'peer-offline';
  readonly peer: Address;
  /**
   * When set, only the connection at this address receives the event. Used for
   * the directed announce-back that tells a joining peer who is already
   * online, without a shared presence store.
   */
  readonly to?: Address;
}

export type BusMessage = BusEnvelope | BusPresence;

export type BusHandler = (pairingId: string, message: BusMessage) => void;

export interface MessageBus {
  setHandler(handler: BusHandler): void;
  subscribe(pairingId: string): Promise<void>;
  unsubscribe(pairingId: string): Promise<void>;
  publish(pairingId: string, message: BusMessage): Promise<void>;
  close(): Promise<void>;
}

export function channelFor(pairingId: string): string {
  return `cribwire:signal:${pairingId}`;
}

function pairingFromChannel(channel: string): string | null {
  const prefix = 'cribwire:signal:';
  return channel.startsWith(prefix) ? channel.slice(prefix.length) : null;
}

/** Rejects anything that is not one of the two bus shapes. */
export function decodeBusMessage(raw: string): BusMessage | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) return null;
  const record = parsed as Record<string, unknown>;

  if (record['kind'] === 'envelope') {
    const { from, to, seq, blob } = record;
    if (
      typeof from === 'string' &&
      typeof to === 'string' &&
      typeof seq === 'number' &&
      typeof blob === 'string'
    ) {
      return { kind: 'envelope', from, to, seq, blob };
    }
    return null;
  }

  if (record['kind'] === 'presence') {
    const { event, peer, to } = record;
    if (
      (event === 'peer-online' || event === 'peer-offline') &&
      typeof peer === 'string'
    ) {
      return typeof to === 'string'
        ? { kind: 'presence', event, peer, to }
        : { kind: 'presence', event, peer };
    }
  }
  return null;
}

/**
 * Delivery fabric for `MemoryMessageBus`. One broker stands in for the Redis
 * server: every bus client registered with it, including the publisher, sees
 * what any of them publishes, exactly as pub/sub does.
 */
export class MemoryBusBroker {
  readonly #clients = new Set<MemoryMessageBus>();

  register(client: MemoryMessageBus): void {
    this.#clients.add(client);
  }

  unregister(client: MemoryMessageBus): void {
    this.#clients.delete(client);
  }

  deliver(pairingId: string, message: BusMessage): void {
    for (const client of [...this.#clients]) {
      client.receive(pairingId, message);
    }
  }
}

/**
 * Single-process bus: correct for a one-instance deployment and for tests,
 * useless across processes. `app.ts` refuses to use it in production. Give
 * several instances the same `MemoryBusBroker` to model a multi-instance
 * deployment without Redis.
 */
export class MemoryMessageBus implements MessageBus {
  readonly #subscribed = new Set<string>();
  readonly #broker: MemoryBusBroker;
  #handler: BusHandler | null = null;

  constructor(broker: MemoryBusBroker = new MemoryBusBroker()) {
    this.#broker = broker;
    this.#broker.register(this);
  }

  setHandler(handler: BusHandler): void {
    this.#handler = handler;
  }

  subscribe(pairingId: string): Promise<void> {
    this.#subscribed.add(pairingId);
    return Promise.resolve();
  }

  unsubscribe(pairingId: string): Promise<void> {
    this.#subscribed.delete(pairingId);
    return Promise.resolve();
  }

  publish(pairingId: string, message: BusMessage): Promise<void> {
    this.#broker.deliver(pairingId, message);
    return Promise.resolve();
  }

  /** Called by the broker; delivers only what this client subscribed to. */
  receive(pairingId: string, message: BusMessage): void {
    if (!this.#subscribed.has(pairingId) || this.#handler === null) return;
    this.#handler(pairingId, message);
  }

  close(): Promise<void> {
    this.#broker.unregister(this);
    this.#subscribed.clear();
    this.#handler = null;
    return Promise.resolve();
  }
}

/**
 * Redis pub/sub bridge. Uses a dedicated subscriber connection because a
 * subscribed Redis client cannot serve other commands.
 */
export class RedisMessageBus implements MessageBus {
  readonly #publisher: Redis;
  readonly #subscriber: Redis;
  #handler: BusHandler | null = null;

  constructor(publisher: Redis, subscriber: Redis) {
    this.#publisher = publisher;
    this.#subscriber = subscriber;
    this.#subscriber.on('message', (channel: string, payload: string) => {
      const pairingId = pairingFromChannel(channel);
      const message = decodeBusMessage(payload);
      if (pairingId === null || message === null || this.#handler === null) {
        return;
      }
      this.#handler(pairingId, message);
    });
  }

  setHandler(handler: BusHandler): void {
    this.#handler = handler;
  }

  async subscribe(pairingId: string): Promise<void> {
    await this.#subscriber.subscribe(channelFor(pairingId));
  }

  async unsubscribe(pairingId: string): Promise<void> {
    await this.#subscriber.unsubscribe(channelFor(pairingId));
  }

  async publish(pairingId: string, message: BusMessage): Promise<void> {
    await this.#publisher.publish(
      channelFor(pairingId),
      JSON.stringify(message),
    );
  }

  async close(): Promise<void> {
    this.#handler = null;
    await this.#subscriber.quit().catch(() => undefined);
  }
}
