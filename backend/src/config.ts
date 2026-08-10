/**
 * Runtime configuration, sourced from the environment only.
 *
 * No secret value defined here is ever logged (see `logger.ts`): the database
 * URL may embed credentials and is therefore never serialised into a log line.
 */

export interface RateLimitRule {
  /** Bucket capacity — the maximum burst. */
  readonly capacity: number;
  /** Tokens refilled per second. */
  readonly refillPerSecond: number;
}

export interface Config {
  readonly nodeEnv: 'development' | 'test' | 'production';
  readonly host: string;
  readonly port: number;
  readonly databaseUrl: string;
  readonly redisUrl: string | undefined;
  readonly logLevel: string;
  /** Age at which an unclaimed pairing stops being claimable, in seconds. */
  readonly pairingTtlSeconds: number;
  /** Accepted clock skew for `KidsCam-HMAC` timestamps, in seconds. */
  readonly authWindowSeconds: number;
  /** Maximum viewers that may claim a single pairing. */
  readonly maxViewersPerPairing: number;
  /** Maximum accepted request body size, in bytes. */
  readonly maxBodyBytes: number;
  /** Maximum accepted WebSocket message size, in bytes (Phase 2). */
  readonly maxWebSocketMessageBytes: number;
  readonly rateLimits: {
    readonly pairingCreatePerIp: RateLimitRule;
    readonly claimPerIp: RateLimitRule;
    readonly perPairing: RateLimitRule;
  };
}

function intFromEnv(
  env: NodeJS.ProcessEnv,
  key: string,
  fallback: number,
): number {
  const raw = env[key];
  if (raw === undefined || raw === '') return fallback;
  const value = Number.parseInt(raw, 10);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`Invalid integer for ${key}`);
  }
  return value;
}

function nodeEnvFromEnv(
  env: NodeJS.ProcessEnv,
): 'development' | 'test' | 'production' {
  switch (env['NODE_ENV']) {
    case 'production':
      return 'production';
    case 'test':
      return 'test';
    default:
      return 'development';
  }
}

/** A budget of `perHour` requests, refilling smoothly across the hour. */
function hourlyRule(perHour: number): RateLimitRule {
  return { capacity: perHour, refillPerSecond: perHour / 3600 };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    nodeEnv: nodeEnvFromEnv(env),
    host: env['HOST'] ?? '0.0.0.0',
    port: intFromEnv(env, 'PORT', 8080),
    databaseUrl:
      env['DATABASE_URL'] ??
      'postgres://kidscam:kidscam@localhost:5432/kidscam',
    redisUrl: env['REDIS_URL'],
    logLevel: env['LOG_LEVEL'] ?? 'info',
    pairingTtlSeconds: intFromEnv(env, 'PAIRING_TTL_SECONDS', 600),
    authWindowSeconds: intFromEnv(env, 'AUTH_WINDOW_SECONDS', 60),
    maxViewersPerPairing: intFromEnv(env, 'MAX_VIEWERS_PER_PAIRING', 5),
    maxBodyBytes: intFromEnv(env, 'MAX_BODY_BYTES', 16 * 1024),
    maxWebSocketMessageBytes: intFromEnv(
      env,
      'MAX_WS_MESSAGE_BYTES',
      16 * 1024,
    ),
    rateLimits: {
      // Pairing creation is limited per IP per hour (backend.md §6); the
      // bucket capacity is the hourly budget and refills over that hour.
      pairingCreatePerIp: hourlyRule(
        intFromEnv(env, 'RATE_LIMIT_PAIRING_CREATE_PER_HOUR', 10),
      ),
      claimPerIp: hourlyRule(intFromEnv(env, 'RATE_LIMIT_CLAIM_PER_HOUR', 20)),
      perPairing: hourlyRule(
        intFromEnv(env, 'RATE_LIMIT_PER_PAIRING_PER_HOUR', 30),
      ),
    },
  };
}
