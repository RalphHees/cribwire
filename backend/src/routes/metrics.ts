/**
 * Prometheus scrape endpoint (backend.md §6).
 *
 * Unauthenticated, like `/v1/health`, and safe to be: every series is a
 * counter or gauge over fixed labels chosen in `metrics/registry.ts` — no
 * pairing ids, device ids, tokens, or IPs. It can be bound to a separate port
 * (`METRICS_PORT`) so it need not be exposed publicly at all.
 */

import type { FastifyInstance } from 'fastify';
import { METRICS_CONTENT_TYPE } from '../metrics/registry.ts';
import type { AppContext } from '../http/context.ts';

export const METRICS_PATH = '/metrics';

export function registerMetricsRoute(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.get(METRICS_PATH, (_request, reply) =>
    reply.header('content-type', METRICS_CONTENT_TYPE).send(ctx.metrics.render()),
  );
}
