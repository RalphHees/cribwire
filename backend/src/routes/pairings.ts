/**
 * Pairing lifecycle — backend.md §3.
 *
 * Authorization model: `K_auth` is shared by every device in a pairing, and
 * the role travels in the `Authorization` header. Role-restricted operations
 * additionally require that the claimed role is actually registered for the
 * pairing (a camera-only route needs a camera device row). See the
 * "Role binding" note in backend/README.md.
 */

import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthContext } from '../auth/verify.ts';
import type { Device } from '../domain/types.ts';
import { isUuid } from '../domain/types.ts';
import type { AppContext } from '../http/context.ts';
import { authenticate, repositoryKeyResolver } from '../http/authenticate.ts';
import { sendError } from '../http/errors.ts';
import {
  enforcePerIpLimit,
  enforcePerPairingLimit,
} from '../http/rate-limit.ts';
import { parseClaimBody, parseCreatePairingBody } from '../http/validation.ts';

interface PairingParams {
  readonly id: string;
}

interface ViewerParams extends PairingParams {
  readonly deviceId: string;
}

/** The pairing named in the path must be the one that signed the request. */
function pairingMatches(auth: AuthContext, pairingId: string): boolean {
  return auth.pairingId === pairingId;
}

/**
 * Resolves the camera device of a pairing, or answers 403. A viewer that
 * claims `camera` in the header still fails here unless it also happens to be
 * the registered camera device.
 */
async function requireCameraDevice(
  ctx: AppContext,
  reply: FastifyReply,
  auth: AuthContext,
): Promise<Device | null> {
  if (auth.role !== 'camera') {
    await sendError(
      reply,
      403,
      'role_not_permitted',
      'This operation is restricted to the camera device',
    );
    return null;
  }
  const devices = await ctx.repository.listDevices(auth.pairingId);
  const camera = devices.find((device) => device.role === 'camera');
  if (camera === undefined) {
    await sendError(
      reply,
      403,
      'role_not_permitted',
      'This operation is restricted to the camera device',
    );
    return null;
  }
  return camera;
}

export function registerPairingRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  /**
   * Camera registers a pairing before rendering the QR.
   *
   * This is the one endpoint whose `K_auth` cannot come from the database: the
   * pairing does not exist yet. The request is therefore self-authenticating —
   * the body carries the `K_auth` being registered and the MAC must verify
   * under that same key. It proves the caller holds the key it is uploading
   * (so a stray body cannot register a pairing the caller cannot use), not
   * that the caller is a known device; abuse is bounded by the per-IP rate
   * limit and the 10-minute unclaimed TTL.
   */
  app.post(
    '/v1/pairings',
    async (request: FastifyRequest, reply: FastifyReply) => {
      if (
        !(await enforcePerIpLimit(
          ctx,
          request,
          reply,
          'pairing-create',
          ctx.config.rateLimits.pairingCreatePerIp,
        ))
      ) {
        return reply;
      }

      const parsed = parseCreatePairingBody(request.body);
      if (!parsed.ok) {
        return sendError(reply, 400, 'invalid_body', parsed.message);
      }
      const body = parsed.value;

      const auth = await authenticate(ctx, request, reply, (parts) =>
        Promise.resolve(parts.pairingId === body.pairingId ? body.kAuth : null),
      );
      if (auth === null) return reply;

      if (auth.role !== 'camera') {
        return sendError(
          reply,
          403,
          'role_not_permitted',
          'Only the camera may create a pairing',
        );
      }

      if (!(await enforcePerPairingLimit(ctx, reply, auth.pairingId))) {
        return reply;
      }

      const now = ctx.now();
      const created = await ctx.repository.createPairing({
        pairingId: body.pairingId,
        kAuth: body.kAuth,
        cameraDeviceId: randomUUID(),
        apnsToken: body.apnsToken,
        apnsEnvironment: body.apnsEnvironment,
        now,
      });

      if (!created.ok) {
        return sendError(
          reply,
          409,
          'pairing_exists',
          'A pairing with this id already exists',
        );
      }

      ctx.logger.info('pairing created', { pairingId: body.pairingId });

      const ttlSeconds = ctx.config.pairingTtlSeconds;
      return reply.status(201).send({
        pairingId: created.pairing.id,
        deviceId: created.device.id,
        role: 'camera',
        status: created.pairing.status,
        ttlSeconds,
        expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
      });
    },
  );

  /** Viewer proves possession of `K_auth`, registers its token, activates. */
  app.post<{ Params: PairingParams }>(
    '/v1/pairings/:id/claim',
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

      if (
        !(await enforcePerIpLimit(
          ctx,
          request,
          reply,
          'pairing-claim',
          ctx.config.rateLimits.claimPerIp,
        ))
      ) {
        return reply;
      }

      const auth = await authenticate(
        ctx,
        request,
        reply,
        repositoryKeyResolver(ctx),
      );
      if (auth === null) return reply;

      if (!pairingMatches(auth, pairingId)) {
        return sendError(
          reply,
          403,
          'pairing_mismatch',
          'Credentials are for a different pairing',
        );
      }
      if (auth.role !== 'viewer') {
        return sendError(
          reply,
          403,
          'role_not_permitted',
          'Only a viewer may claim a pairing',
        );
      }

      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) {
        return reply;
      }

      const parsed = parseClaimBody(request.body);
      if (!parsed.ok) {
        return sendError(reply, 400, 'invalid_body', parsed.message);
      }

      const now = ctx.now();
      const claimed = await ctx.repository.claimPairing({
        pairingId,
        viewerDeviceId: randomUUID(),
        apnsToken: parsed.value.apnsToken,
        apnsEnvironment: parsed.value.apnsEnvironment,
        maxViewers: ctx.config.maxViewersPerPairing,
        expiredBefore: new Date(
          now.getTime() - ctx.config.pairingTtlSeconds * 1000,
        ),
        now,
      });

      if (!claimed.ok) {
        switch (claimed.reason) {
          case 'not_found':
            return sendError(
              reply,
              404,
              'pairing_not_found',
              'Unknown pairing',
            );
          case 'revoked':
            return sendError(reply, 409, 'pairing_revoked', 'Pairing revoked');
          case 'expired':
            return sendError(
              reply,
              410,
              'pairing_expired',
              'Pairing expired; scan a fresh QR code',
            );
          case 'too_many_viewers':
            return sendError(
              reply,
              409,
              'viewer_limit_reached',
              `A pairing accepts at most ${ctx.config.maxViewersPerPairing} viewers`,
            );
        }
      }

      ctx.logger.info('pairing claimed', { pairingId });

      return reply.status(201).send({
        pairingId: claimed.pairing.id,
        deviceId: claimed.device.id,
        role: 'viewer',
        status: claimed.pairing.status,
        claimedAt: claimed.pairing.claimedAt?.toISOString() ?? null,
      });
    },
  );

  /**
   * Camera revokes the whole pairing. The row is hard-deleted (cascading to
   * every device token) rather than marked `revoked`: security.md §6 requires
   * `K_auth` and tokens to be gone server-side, and keeping a tombstone would
   * keep the key. The daily purge job still cleans `revoked` rows for any
   * pairing marked that way by other means.
   */
  app.delete<{ Params: PairingParams }>(
    '/v1/pairings/:id',
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

      const auth = await authenticate(
        ctx,
        request,
        reply,
        repositoryKeyResolver(ctx),
      );
      if (auth === null) return reply;

      if (!pairingMatches(auth, pairingId)) {
        return sendError(
          reply,
          403,
          'pairing_mismatch',
          'Credentials are for a different pairing',
        );
      }
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) {
        return reply;
      }
      if ((await requireCameraDevice(ctx, reply, auth)) === null) {
        return reply;
      }

      const deleted = await ctx.repository.deletePairing(pairingId);
      if (!deleted) {
        return sendError(reply, 404, 'pairing_not_found', 'Unknown pairing');
      }

      ctx.logger.info('pairing revoked', { pairingId });
      return reply.status(204).send();
    },
  );

  /** Camera revokes a single viewer; its token is deleted immediately. */
  app.delete<{ Params: ViewerParams }>(
    '/v1/pairings/:id/viewers/:deviceId',
    async (request, reply) => {
      const { id: pairingId, deviceId } = request.params;
      if (!isUuid(pairingId) || !isUuid(deviceId)) {
        return sendError(
          reply,
          400,
          'invalid_pairing_id',
          'Malformed pairing or device id',
        );
      }

      const auth = await authenticate(
        ctx,
        request,
        reply,
        repositoryKeyResolver(ctx),
      );
      if (auth === null) return reply;

      if (!pairingMatches(auth, pairingId)) {
        return sendError(
          reply,
          403,
          'pairing_mismatch',
          'Credentials are for a different pairing',
        );
      }
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) {
        return reply;
      }
      const camera = await requireCameraDevice(ctx, reply, auth);
      if (camera === null) return reply;

      const device = await ctx.repository.getDevice(pairingId, deviceId);
      if (device === null || device.role !== 'viewer') {
        return sendError(reply, 404, 'device_not_found', 'Unknown viewer');
      }

      await ctx.repository.deleteDevice(pairingId, deviceId);
      await ctx.repository.touchDevice(camera.id, ctx.now());

      ctx.logger.info('viewer revoked', { pairingId });
      return reply.status(204).send();
    },
  );
}
