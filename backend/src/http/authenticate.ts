/**
 * Fastify glue for `KidsCam-HMAC` (see `auth/verify.ts` for the protocol).
 *
 * Two shapes of caller exist, and they are deliberately separate functions:
 *
 * - **bootstrap** — `POST /v1/pairings` and `POST /v1/pairings/:id/claim`,
 *   signed with the pairing-wide `K_auth`. These establish a device and prove
 *   membership of the pairing, nothing more.
 * - **device** — everything else, signed with the calling device's own key.
 *   The device row that key belongs to is the caller's identity *and* the only
 *   source of its role; nothing about authority is read from the request.
 *
 * Every failure mode answers `401` with a distinct code but no hint about
 * whether the pairing or the device exists.
 */

import type { FastifyReply, FastifyRequest } from 'fastify';
import type { AuthContext, AuthFailureCode, KeyResolver } from '../auth/verify.ts';
import { verifyRequest } from '../auth/verify.ts';
import { isBootstrapPrincipal } from '../auth/canonical.ts';
import type { Device } from '../domain/types.ts';
import { isUuid } from '../domain/types.ts';
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
 * Verifies a bootstrap request and, on success, returns the auth context. On
 * failure the reply has already been sent and the caller must return
 * immediately.
 */
export async function authenticateBootstrap(
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
    // A device principal can never sign a bootstrap call: no key is resolved
    // for it, so it fails exactly like an unknown credential.
    resolveKey: (parts) =>
      isBootstrapPrincipal(parts.principal)
        ? resolveKey(parts)
        : Promise.resolve(null),
    nonceStore: ctx.nonceStore,
    windowSeconds: ctx.config.authWindowSeconds,
    nowMs: ctx.now().getTime(),
  });

  if (!result.ok) {
    rejectionLog(ctx, request.method, request.routeOptions.url, result.code);
    await sendError(reply, 401, result.code, FAILURE_MESSAGE);
    return null;
  }

  request.auth = result.auth;
  return result.auth;
}

export interface DeviceAuth {
  readonly auth: AuthContext;
  /** The row the signing key belongs to — the caller's identity and role. */
  readonly device: Device;
}

export type DeviceAuthResult =
  | { readonly ok: true; readonly auth: AuthContext; readonly device: Device }
  | { readonly ok: false; readonly code: AuthFailureCode };

export interface DeviceRequestInput {
  readonly method: string;
  /** Path only, no query string. */
  readonly path: string;
  readonly authorization: string | undefined;
  readonly rawBody: Buffer;
}

/**
 * Transport-independent device authentication, shared by REST routes and the
 * WebSocket upgrade. The device row is fetched once, inside the key resolver,
 * and handed back so callers do not re-read it.
 */
export async function verifyDeviceRequest(
  ctx: AppContext,
  input: DeviceRequestInput,
): Promise<DeviceAuthResult> {
  let device: Device | null = null;

  const result = await verifyRequest({
    method: input.method,
    path: input.path,
    authorization: input.authorization,
    rawBody: input.rawBody,
    resolveKey: async (parts) => {
      if (!isUuid(parts.principal)) return null;
      const pairing = await ctx.repository.getPairing(parts.pairingId);
      // A revoked pairing keeps no valid credentials.
      if (pairing === null || pairing.status === 'revoked') return null;
      const found = await ctx.repository.getDevice(
        parts.pairingId,
        parts.principal,
      );
      if (found === null) return null;
      device = found;
      return found.deviceKey;
    },
    nonceStore: ctx.nonceStore,
    windowSeconds: ctx.config.authWindowSeconds,
    nowMs: ctx.now().getTime(),
  });

  if (!result.ok) return { ok: false, code: result.code };
  if (device === null) {
    // Unreachable: a MAC only verifies once a device key has been resolved.
    return { ok: false, code: 'unknown_principal' };
  }
  return { ok: true, auth: result.auth, device };
}

/**
 * Fastify wrapper around `verifyDeviceRequest`. On failure the reply has
 * already been sent and the caller must return immediately.
 */
export async function authenticateDevice(
  ctx: AppContext,
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<DeviceAuth | null> {
  const result = await verifyDeviceRequest(ctx, {
    method: request.method,
    path: canonicalPath(request.url),
    authorization: request.headers.authorization,
    rawBody: rawBodyOf(request),
  });

  if (!result.ok) {
    rejectionLog(ctx, request.method, request.routeOptions.url, result.code);
    await sendError(reply, 401, result.code, FAILURE_MESSAGE);
    return null;
  }

  request.auth = result.auth;
  return { auth: result.auth, device: result.device };
}

/** Key resolver for the claim call, backed by the pairings table. */
export function pairingKeyResolver(ctx: AppContext): KeyResolver {
  return async (parts) => {
    const pairing = await ctx.repository.getPairing(parts.pairingId);
    if (pairing === null) return null;
    if (pairing.status === 'revoked') return null;
    return pairing.kAuth;
  };
}

function rejectionLog(
  ctx: AppContext,
  method: string,
  route: string | undefined,
  code: AuthFailureCode,
): void {
  // Codes and routes only: never the header, the MAC, or the body.
  ctx.logger.warn('auth rejected', { code, method, route: route ?? 'unknown' });
}
