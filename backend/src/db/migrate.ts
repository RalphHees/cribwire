/**
 * Minimal forward-only SQL migration runner.
 *
 * Files live in `backend/migrations/NNN_name.sql`, are applied in filename
 * order, each inside its own transaction, and are recorded in
 * `schema_migrations`. A Postgres advisory lock makes concurrent deploys safe.
 */

import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { PgPool } from './pool.ts';

const ADVISORY_LOCK_KEY = 8_142_301;

export function migrationsDir(): string {
  return path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    '../..',
    'migrations',
  );
}

export interface MigrationResult {
  readonly applied: string[];
  readonly skipped: string[];
}

export async function runMigrations(
  pool: PgPool,
  dir: string = migrationsDir(),
): Promise<MigrationResult> {
  const files = (await readdir(dir))
    .filter((name) => name.endsWith('.sql'))
    .sort((a, b) => a.localeCompare(b));

  const client = await pool.connect();
  const applied: string[] = [];
  const skipped: string[] = [];
  try {
    await client.query('select pg_advisory_lock($1)', [ADVISORY_LOCK_KEY]);
    await client.query(`
      create table if not exists schema_migrations (
        version    text primary key,
        applied_at timestamptz not null default now()
      )
    `);

    const existing = await client.query<{ version: string }>(
      'select version from schema_migrations',
    );
    const done = new Set(existing.rows.map((row) => row.version));

    for (const file of files) {
      if (done.has(file)) {
        skipped.push(file);
        continue;
      }
      const sql = await readFile(path.join(dir, file), 'utf8');
      try {
        await client.query('begin');
        await client.query(sql);
        await client.query(
          'insert into schema_migrations (version) values ($1)',
          [file],
        );
        await client.query('commit');
        applied.push(file);
      } catch (error) {
        await client.query('rollback');
        throw error;
      }
    }
  } finally {
    await client.query('select pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY]);
    client.release();
  }

  return { applied, skipped };
}
