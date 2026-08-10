/**
 * Pairing lifecycle — backend.md §3, bodies pinned in protocol.md.
 *
 * Authorization model (protocol.md 1.1): `K_auth` authenticates only the two
 * bootstrap calls below, which register a device and its own key. Every other
 * route authenticates that device key and reads the caller's role from the
 * device row — the client never asserts a role, so a viewer cannot revoke a
 * pairing or evict another viewer.
 */

import { randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { isUuid } from '../domain/types.ts';
import type { AppContext } from '../http/context.ts';
import {
  authenticateBootstrap,
  authenticateDevice,
  pairingKeyResolver,
} from '../http/authenticate.ts';
import {
  requireCameraRole,
  requirePairingMatch,
} from '../http/authorize.ts';
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

export function registerPairingRoutes(
  app: FastifyInstance,
  ctx: AppContext,
): void {
  /**
   * Camera registers a pairing before rendering the QR.
   *
   * This is the one endpoint whose key cannot come from the database: the
   * pairing does not exist yet. The request is therefore self-authenticating —
   * the body carries the `K_auth` being registered and the MAC must verify
   * under that same key, with the header's `pairingId` matching the body's. It
   * proves the caller holds the key it is uploading, not that the caller is a
   * known device; abuse is bounded by the per-IP rate limit and the 10-minute
   * unclaimed TTL. The camera's own device key travels in the same body and is
   * what authenticates every later call from that device.
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

      const auth = await authenticateBootstrap(ctx, request, reply, (parts) =>
        Promise.resolve(parts.pairingId === body.pairingId ? body.kAuth : null),
      );
      if (auth === null) return reply;

      if (!(await enforcePerPairingLimit(ctx, reply, auth.pairingId))) {
        return reply;
      }

      const now = ctx.now();
      const created = await ctx.repository.createPairing({
        pairingId: body.pairingId,
        kAuth: body.kAuth,
        cameraDeviceId: randomUUID(),
        cameraDeviceKey: body.deviceKey,
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

  /**
   * Viewer proves possession of `K_auth`, registers its own device key and
   * APNs token, and activates the pairing.
   */
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

      const auth = await authenticateBootstrap(
        ctx,
        request,
        reply,
        pairingKeyResolver(ctx),
      );
      if (auth === null) return reply;

      if (!(await requirePairingMatch(reply, auth, pairingId))) return reply;
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) return reply;

      const parsed = parseClaimBody(request.body);
      if (!parsed.ok) {
        return sendError(reply, 400, 'invalid_body', parsed.message);
      }

      const now = ctx.now();
      const claimed = await ctx.repository.claimPairing({
        pairingId,
        viewerDeviceId: randomUUID(),
        viewerDeviceKey: parsed.value.deviceKey,
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
   * every device row, key, and token) rather than marked `revoked`:
   * security.md §6 requires `K_auth` and tokens to be gone server-side, and a
   * tombstone would keep them.
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

      const authenticated = await authenticateDevice(ctx, request, reply);
      if (authenticated === null) return reply;

      if (!(await requirePairingMatch(reply, authenticated.auth, pairingId))) {
        return reply;
      }
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) return reply;
      if (!(await requireCameraRole(reply, authenticated.device))) return reply;

      const deleted = await ctx.repository.deletePairing(pairingId);
      if (!deleted) {
        return sendError(reply, 404, 'pairing_not_found', 'Unknown pairing');
      }

      ctx.signaling?.closePairing(pairingId, 'pairing_revoked');
      ctx.logger.info('pairing revoked', { pairingId });
      return reply.status(204).send();
    },
  );

  /** Camera evicts a single viewer; its key and token are deleted at once. */
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

      const authenticated = await authenticateDevice(ctx, request, reply);
      if (authenticated === null) return reply;

      if (!(await requirePairingMatch(reply, authenticated.auth, pairingId))) {
        return reply;
      }
      if (!(await enforcePerPairingLimit(ctx, reply, pairingId))) return reply;
      if (!(await requireCameraRole(reply, authenticated.device))) return reply;

      const device = await ctx.repository.getDevice(pairingId, deviceId);
      if (device === null || device.role !== 'viewer') {
        return sendError(reply, 404, 'device_not_found', 'Unknown viewer');
      }

      await ctx.repository.deleteDevice(pairingId, deviceId);
      await ctx.repository.touchDevice(authenticated.device.id, ctx.now());

      ctx.signaling?.closeDevice(pairingId, deviceId, 'device_revoked');
      ctx.logger.info('viewer revoked', { pairingId });
      return reply.status(204).send();
    },
  );
}
