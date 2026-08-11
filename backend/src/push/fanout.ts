/**
 * Event fan-out to a pairing's viewers.
 *
 * The ciphertext is copied from the request to every notification untouched.
 * A `410 Unregistered` answer means the token is dead: the device row is
 * hard-deleted immediately (backend.md §3, security.md §7 data minimisation),
 * not marked or retried.
 */

import type { AppContext } from '../http/context.ts';

export interface FanOutResult {
  readonly sent: number;
  readonly failed: number;
  readonly unregistered: number;
}

export async function fanOutEvent(
  ctx: AppContext,
  pairingId: string,
  ciphertext: string,
): Promise<FanOutResult> {
  const startedMs = ctx.now().getTime();
  const devices = await ctx.repository.listDevices(pairingId);
  const viewers = devices.filter((device) => device.role === 'viewer');

  let sent = 0;
  let failed = 0;
  let unregistered = 0;

  const results = await Promise.all(
    viewers.map(async (viewer) => {
      const result = await ctx.apns.send({
        deviceToken: viewer.apnsToken,
        environment: viewer.apnsEnvironment,
        pairingId,
        ciphertext,
      });
      ctx.metrics.apnsResult(result.status);
      if (result.status === 'unregistered') {
        const deleted = await ctx.repository.deleteDevicesByApnsToken(
          viewer.apnsToken,
        );
        ctx.metrics.apnsTokenDeleted(deleted);
        ctx.logger.info('apns token unregistered', { pairingId, deleted });
      } else if (result.status === 'failed') {
        // The reason is an APNs status code, never payload-derived.
        ctx.logger.warn('apns delivery failed', {
          pairingId,
          reason: result.reason,
        });
      }
      return result.status;
    }),
  );

  for (const status of results) {
    if (status === 'sent') sent += 1;
    else if (status === 'unregistered') unregistered += 1;
    else failed += 1;
  }

  ctx.metrics.eventFanoutObserved(
    Math.max(0, (ctx.now().getTime() - startedMs) / 1000),
  );

  return { sent, failed, unregistered };
}
