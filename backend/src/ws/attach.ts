/**
 * Wires the signaling hub to a built Fastify instance.
 *
 * Kept apart from `buildServer` so a REST-only test can skip the WebSocket
 * machinery entirely, and so the hub (which owns timers and sockets) has an
 * explicit lifetime the caller closes.
 */

import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../http/context.ts';
import type { MessageBus } from './bus.ts';
import { SignalingHub } from './hub.ts';
import { registerSignaling } from './signal.ts';

export interface Signaling {
  readonly hub: SignalingHub;
  close(): Promise<void>;
}

export function attachSignaling(
  app: FastifyInstance,
  ctx: AppContext,
  bus: MessageBus,
): Signaling {
  const hub = new SignalingHub({
    config: ctx.config,
    repository: ctx.repository,
    bus,
    logger: ctx.logger,
    metrics: ctx.metrics,
    now: ctx.now,
  });
  hub.start();
  // Revocation routes use this to drop live sockets the instant the
  // credentials behind them stop existing.
  ctx.signaling = hub;

  const wss = registerSignaling(app, ctx, hub);

  return {
    hub,
    close: async () => {
      await hub.close();
      ctx.signaling = null;
      await new Promise<void>((resolve) => {
        wss.close(() => {
          resolve();
        });
      });
    },
  };
}
