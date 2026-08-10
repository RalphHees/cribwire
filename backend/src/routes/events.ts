/**
 * `POST /v1/events` — sealed detection events (backend.md §3).
 *
 * The camera seals `{type, ts}` under `K_evt`; this route measures the
 * envelope, checks who sent it, and hands the same bytes to APNs. It cannot
 * decrypt it, and neither can Apple. Only the camera device of the pairing may
 * post, and the role comes from the authenticated device row.
 */

import type { FastifyInstance } from 'fastify';
import { authenticateDevice } from '../http/authenticate.ts';
import { requireCameraRole } from '../http/authorize.ts';
import type { AppContext } from '../http/context.ts';
import { sendError } from '../http/errors.ts';
import { enforceRateLimit } from '../http/rate-limit.ts';
import { parseEventBody } from '../http/validation.ts';
import { fanOutEvent } from '../push/fanout.ts';

export function registerEventRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.post('/v1/events', async (request, reply) => {
    const authenticated = await authenticateDevice(ctx, request, reply);
    if (authenticated === null) return reply;

    const { auth, device } = authenticated;
    if (!(await requireCameraRole(reply, device))) return reply;

    // Abuse protection on top of the client-side debounce: one event per
    // 30 s per pairing, in its own bucket so it cannot be starved by (or
    // starve) the general per-pairing budget.
    if (
      !(await enforceRateLimit(
        ctx,
        reply,
        `events:${auth.pairingId}`,
        ctx.config.rateLimits.eventsPerPairing,
      ))
    ) {
      return reply;
    }

    const parsed = parseEventBody(request.body);
    if (!parsed.ok) {
      return sendError(reply, 400, 'invalid_body', parsed.message);
    }

    ctx.metrics.eventAccepted();
    await fanOutEvent(ctx, auth.pairingId, parsed.value.ciphertext);

    return reply.status(202).send();
  });
}
