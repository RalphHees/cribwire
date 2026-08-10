/**
 * Fastify glue for `KidsCam-HMAC` (see `auth/verify.ts` for the protocol).
 *
 * Every failure mode answers `401` with a distinct code but no hint about
 * whether the pairing exists — an unknown pairing and a bad MAC are
 * indistinguishable in status and timing-relevant work.
 */

import type { FastifyReply, FastifyRequest } from 'fastify';
import type { AuthContext, KeyResolver } from '../auth/verify.ts';
import { verifyRequest } from '../auth/verify.ts';
import type { AppContext } from './context.ts';
import { sendError } from './errors.ts';

const FAILURE_MESSAGE = 'Invalid KidsCam-HMAC credentials';

/** Path used for canonicalisation: the request target without its query. */
export function canonicalPath(url: string): string {
  const queryStart = url.indexOf('?');
  return queryStart < 0 ? url : url.slice(0, queryStart);
}

export function rawBodyOf(request: FastifyRequest): Buffer {
  return request.rawBody ?? Buffer.alloc(0);
}

/**
 * Verifies the request and, on success, returns the auth context. On failure
 * the reply has already been sent and the caller must return immediately.
 */
export async function authenticate(
  ctx: AppContext,
  request: FastifyRequest,
  reply: FastifyReply,
  resolveKey: KeyResolver,
): Promise<AuthContext | null> {
  const result = await verifyRequest({
    method: request.method,
    path: canonicalPath(request.url),
    authorization: request.headers.authorization,
    rawBody: rawBodyOf(request),
    resolveKey,
    nonceStore: ctx.nonceStore,
    windowSeconds: ctx.config.authWindowSeconds,
    nowMs: ctx.now().getTime(),
  });

  if (!result.ok) {
    ctx.logger.warn('auth rejected', {
      code: result.code,
      method: request.method,
      route: request.routeOptions.url ?? 'unknown',
    });
    await sendError(reply, 401, result.code, FAILURE_MESSAGE);
    return null;
  }

  request.auth = result.auth;
  return result.auth;
}

/** Key resolver backed by the pairings table. */
export function repositoryKeyResolver(ctx: AppContext): KeyResolver {
  return async (parts) => {
    const pairing = await ctx.repository.getPairing(parts.pairingId);
    if (pairing === null) return null;
    // A revoked pairing keeps no valid credentials.
    if (pairing.status === 'revoked') return null;
    return pairing.kAuth;
  };
}
