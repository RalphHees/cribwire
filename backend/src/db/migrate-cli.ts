#!/usr/bin/env node
/** `npm run migrate` — applies pending SQL migrations and exits. */

import { loadConfig } from '../config.ts';
import { createPool } from './pool.ts';
import { runMigrations } from './migrate.ts';

const config = loadConfig();
const pool = createPool(config.databaseUrl);

try {
  const result = await runMigrations(pool);
  for (const file of result.applied) console.log(`applied ${file}`);
  console.log(
    `migrations: ${result.applied.length} applied, ${result.skipped.length} already present`,
  );
} catch (error) {
  console.error(
    'migration failed:',
    error instanceof Error ? error.message : error,
  );
  process.exitCode = 1;
} finally {
  await pool.end();
}
