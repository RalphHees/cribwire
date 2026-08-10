/**
 * `PUT /v1/devices/token` — APNs token rotation (backend.md §3).
 *
 * Both the pairing and the device come from the authenticated principal, never
 * from the body (protocol.md 1.1), so a device can only ever rotate its own
 * token.
 */

import type { FastifyInstance } from 'fastify';
import type { AppContext } from '../http/context.ts';
import { authenticateDevice } from '../http/authenticate.ts';
import { sendError } from '../http/errors.ts';
import { enforcePerPairingLimit } from '../http/rate-limit.ts';
import { parseUpdateTokenBody } from '../http/validation.ts';

export function registerDeviceRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.put('/v1/devices/token', async (request, reply) => {
    const authenticated = await authenticateDevice(ctx, request, reply);
    if (authenticated === null) return reply;

    const { auth, device } = authenticated;
    if (!(await enforcePerPairingLimit(ctx, reply, auth.pairingId))) {
      return reply;
    }

    const parsed = parseUpdateTokenBody(request.body);
    if (!parsed.ok) {
      return sendError(reply, 400, 'invalid_body', parsed.message);
    }

    const updated = await ctx.repository.updateDeviceToken({
      pairingId: device.pairingId,
      deviceId: device.id,
      apnsToken: parsed.value.apnsToken,
      apnsEnvironment: parsed.value.apnsEnvironment,
      now: ctx.now(),
    });

    if (updated === null) {
      // The device authenticated a moment ago, so this only happens if it was
      // revoked concurrently.
      return sendError(reply, 404, 'device_not_found', 'Unknown device');
    }

    ctx.logger.info('device token rotated', {
      pairingId: auth.pairingId,
      role: updated.role,
    });

    return reply.status(204).send();
  });
}
