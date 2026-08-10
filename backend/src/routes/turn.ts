/**
 * `POST /v1/pairings/:id/turn-credentials` — backend.md §4.
 *
 * Either role may ask; the credential is scoped to the pairing and expires on
 * its own. Nothing is stored: coturn recomputes the same HMAC from the shared
 * secret it already has.
 */

import type { FastifyInstance } from 'fastify';
import { turnConfigured } from '../config.ts';
import { isUuid } from '../domain/types.ts';
import { authenticateDevice } from '../http/authenticate.ts';
import { requirePairingMatch } from '../http/authorize.ts';
import type { AppContext } from '../http/context.ts';
import { sendError } from '../http/errors.ts';
import { enforcePerPairingLimit } from '../http/rate-limit.ts';
import { issueTurnCredentials } from '../turn/credentials.ts';

interface PairingParams {
  readonly id: string;
}

export function registerTurnRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.post<{ Params: PairingParams }>(
    '/v1/pairings/:id/turn-credentials',
    async (request, reply) => {
      const pairingId = request.params.id;
      if (!isUuid(pairingId)) {
        return sendError(
          reply,
          400,
          'invalid_pairing_id',
          'Malformed pairing id',
        );
      }

      const authenticated = await authenticateDevice(ctx, request, reply);
      if (authenticated === null) return reply;

      if (!(await requirePairingMatch(reply, authenticated.auth, pairingId))) {
        return reply;
      }
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) return reply;

      if (!turnConfigured(ctx.config)) {
        return sendError(
          reply,
          503,
          'turn_unavailable',
          'TURN is not configured on this server',
        );
      }

      const credentials = issueTurnCredentials(
        ctx.config.turn,
        pairingId,
        ctx.now(),
      );
      return reply.status(200).send(credentials);
    },
  );
}
