/**
 * `PUT /v1/devices/token` — APNs token rotation (backend.md §3).
 *
 * The pairing comes from the authenticated header, never from the body, so a
 * device can only rotate a token inside its own pairing.
 */

import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../http/context.ts';
import { authenticate, repositoryKeyResolver } from '../http/authenticate.ts';
import { sendError } from '../http/errors.ts';
import { enforcePerPairingLimit } from '../http/rate-limit.ts';
import { parseUpdateTokenBody } from '../http/validation.ts';

export function registerDeviceRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.put('/v1/devices/token', async (request, reply) => {
    const auth = await authenticate(
      ctx,
      request,
      reply,
      repositoryKeyResolver(ctx),
    );
    if (auth === null) return reply;

    if (!(await enforcePerPairingLimit(ctx, reply, auth.pairingId))) {
      return reply;
    }

    const parsed = parseUpdateTokenBody(request.body);
    if (!parsed.ok) {
      return sendError(reply, 400, 'invalid_body', parsed.message);
    }

    const updated = await ctx.repository.updateDeviceToken({
      pairingId: auth.pairingId,
      deviceId: parsed.value.deviceId,
      role: auth.role,
      apnsToken: parsed.value.apnsToken,
      apnsEnvironment: parsed.value.apnsEnvironment,
      now: ctx.now(),
    });

    if (updated === null) {
      return sendError(
        reply,
        404,
        'device_not_found',
        'No such device in this pairing for the authenticated role',
      );
    }

    ctx.logger.info('device token rotated', {
      pairingId: auth.pairingId,
      role: auth.role,
    });

    return reply.status(200).send({
      deviceId: updated.id,
      role: updated.role,
      apnsEnvironment: updated.apnsEnvironment,
    });
  });
}
