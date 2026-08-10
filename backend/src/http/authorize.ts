/**
 * Route authorization (protocol.md 1.1).
 *
 * The role is read from the authenticated device row and nowhere else. A
 * viewer's key presented to a camera-only route fails here, and no request
 * field can change that outcome.
 */

import type { FastifyReply } from 'fastify';
import type { AuthContext } from '../auth/verify.ts';
import type { Device } from '../domain/types.ts';
import { sendError } from './errors.ts';

/** The pairing named in the path must be the one that signed the request. */
export function pairingMatches(auth: AuthContext, pairingId: string): boolean {
  return auth.pairingId === pairingId;
}

export async function requirePairingMatch(
  reply: FastifyReply,
  auth: AuthContext,
  pairingId: string,
): Promise<boolean> {
  if (pairingMatches(auth, pairingId)) return true;
  await sendError(
    reply,
    403,
    'pairing_mismatch',
    'Credentials are for a different pairing',
  );
  return false;
}

/** Camera-only routes: revoke, evict a viewer, post events. */
export async function requireCameraRole(
  reply: FastifyReply,
  device: Device,
): Promise<boolean> {
  if (device.role === 'camera') return true;
  await sendError(
    reply,
    403,
    'role_not_permitted',
    'This operation is restricted to the camera device',
  );
  return false;
}
