/**
 * Daily hard-delete job (backend.md §5): revoked pairings and pairings that
 * were never claimed within the TTL are removed, taking their device tokens
 * with them via the FK cascade.
 *
 * Invoked manually or from cron/Kubernetes CronJob; no in-process scheduler.
 */

import type { PurgeResult, Repository } from '../repositories/types.ts';

export async function purgeStalePairings(
  repository: Repository,
  ttlSeconds: number,
  now: Date = new Date(),
): Promise<PurgeResult> {
  const expiredBefore = new Date(now.getTime() - ttlSeconds * 1000);
  return repository.purge(expiredBefore);
}
