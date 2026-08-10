import pg from 'pg';

export type PgPool = pg.Pool;

/**
 * `bytea` columns arrive as Buffers by default, which is what `k_auth` needs;
 * no type parser overrides are installed so nothing rewrites key material.
 */
export function createPool(databaseUrl: string): PgPool {
  return new pg.Pool({
    connectionString: databaseUrl,
    max: 10,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
  });
}
