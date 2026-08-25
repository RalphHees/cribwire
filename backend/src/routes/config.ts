/**
 * `GET /v1/config` — deployment configuration a client may not hardcode.
 *
 * Everything here has one property in common: it changes on a schedule the App
 * Store cannot keep up with. A TIDAL or Spotify client id gets rotated, or
 * issued for the first time, long after a build has shipped; baking it into
 * `Info.plist` means a release and a review queue between deciding and taking
 * effect.
 *
 * Two rules keep this endpoint boring, which is what it must stay:
 *
 * 1. **Nothing secret is served here, ever.** Not "nothing secret today" — the
 *    response is assembled field by field from values that are public by
 *    construction. A client id is on the wire in every OAuth exchange; a client
 *    secret is not, and does not appear in this file at all.
 * 2. **It says nothing about the caller.** The body is identical for every
 *    device in every pairing, so authenticating it buys no privacy — it is
 *    required because an unauthenticated endpoint is an unauthenticated
 *    endpoint, and this one already knows how to demand a signature.
 *
 * Absent sections mean "this deployment has none", which the client reads as
 * "fall back to whatever was built in". That is what lets a single build serve
 * a deployment with TIDAL, one with Spotify, one with both and one with
 * neither.
 */

import type { FastifyInstance } from 'fastify';
import { spotifyConfigured, tidalConfigured } from '../config.ts';
import { authenticateDevice } from '../http/authenticate.ts';
import type { AppContext } from '../http/context.ts';
import { enforcePerPairingLimit } from '../http/rate-limit.ts';

interface ConfigResponse {
  /** Seconds a client may cache this before asking again. */
  readonly ttlSeconds: number;
  readonly tidal?: {
    readonly clientId: string;
  };
  readonly spotify?: {
    readonly clientId: string;
  };
}

export function registerConfigRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  app.get('/v1/config', async (request, reply) => {
    const authenticated = await authenticateDevice(ctx, request, reply);
    if (authenticated === null) return reply;

    if (
      !(await enforcePerPairingLimit(ctx, reply, authenticated.auth.pairingId))
    ) {
      return reply;
    }

    const body: ConfigResponse = {
      ttlSeconds: ctx.config.configTtlSeconds,
      // Spelled out rather than spread from `ctx.config.tidal`, which also
      // holds the secret. A spread here would ship it the first time anyone
      // added a field, and nothing would fail loudly.
      ...(tidalConfigured(ctx.config)
        ? { tidal: { clientId: ctx.config.tidal.clientId } }
        : {}),
      // Spelled out for the same reason as TIDAL above, even though these
      // settings hold nothing else today: the rule is the habit, and the first
      // field added to `spotify` is exactly when a spread would start leaking.
      ...(spotifyConfigured(ctx.config)
        ? { spotify: { clientId: ctx.config.spotify.clientId } }
        : {}),
    };

    return reply.status(200).send(body);
  });
}
