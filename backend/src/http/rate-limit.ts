import type { FastifyReply, FastifyRequest } from 'fastify';
import type { RateLimitRule } from '../config.ts';
import type { AppContext } from './context.ts';

/**
 * Consumes one token. Returns `true` when the request may proceed; on `false`
 * a `429` has already been sent and the caller must return immediately.
 */
export async function enforceRateLimit(
  ctx: AppContext,
  reply: FastifyReply,
  key: string,
  rule: RateLimitRule,
): Promise<boolean> {
  const result = await ctx.rateLimiter.consume(key, rule);
  if (result.allowed) return true;

  await reply
    .header('retry-after', String(result.retryAfterSeconds))
    .status(429)
    .send({
      error: 'rate_limited',
      message: 'Too many requests; retry later',
    });
  return false;
}

/** Client IP for per-IP buckets. Not persisted, not logged. */
export function clientIp(request: FastifyRequest): string {
  return request.ip;
}

export async function enforcePerIpLimit(
  ctx: AppContext,
  request: FastifyRequest,
  reply: FastifyReply,
  scope: string,
  rule: RateLimitRule,
): Promise<boolean> {
  return enforceRateLimit(ctx, reply, `ip:${scope}:${clientIp(request)}`, rule);
}

export async function enforcePerPairingLimit(
  ctx: AppContext,
  reply: FastifyReply,
  pairingId: string,
): Promise<boolean> {
  return enforceRateLimit(
    ctx,
    reply,
    `pairing:${pairingId}`,
    ctx.config.rateLimits.perPairing,
  );
}
