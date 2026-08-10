#!/usr/bin/env node
/** `npm run purge` — one-shot hard delete of revoked/expired pairings. */

import { loadConfig } from '../config.ts';
import { createPool } from '../db/pool.ts';
import { PostgresRepository } from '../repositories/postgres.ts';
import { purgeStalePairings } from './purge.ts';

const config = loadConfig();
const pool = createPool(config.databaseUrl);
const repository = new PostgresRepository(pool);

try {
  const result = await purgeStalePairings(repository, config.pairingTtlSeconds);
  console.log(
    `purged ${result.revokedPairings} revoked and ${result.expiredPairings} expired pairings`,
  );
} catch (error) {
  console.error(
    'purge failed:',
    error instanceof Error ? error.message : error,
  );
  process.exitCode = 1;
} finally {
  await repository.close();
}
