/**
 * Runtime configuration, sourced from the environment only.
 *
 * No secret value defined here is ever logged (see `logger.ts`): the database
 * URL may embed credentials, the TURN shared secret and the APNs `.p8` key are
 * credentials outright, and none of them is ever serialised into a log line.
 */

export interface RateLimitRule {
  /** Bucket capacity — the maximum burst. */
  readonly capacity: number;
  /** Tokens refilled per second. */
  readonly refillPerSecond: number;
}

export interface TurnSettings {
  /** coturn `use-auth-secret` shared secret; empty when TURN is unconfigured. */
  readonly sharedSecret: string;
  readonly ttlSeconds: number;
  readonly uris: readonly string[];
}

export interface ApnsSettings {
  /** Contents of the `.p8` key. Empty when push is unconfigured. */
  readonly privateKeyPem: string;
  readonly keyId: string;
  readonly teamId: string;
  readonly topic: string;
  readonly requestTimeoutMs: number;
}

export interface Config {
  readonly nodeEnv: 'development' | 'test' | 'production';
  readonly host: string;
  readonly port: number;
  /** Port for `/metrics`; equal to `port` serves it on the main listener. */
  readonly metricsPort: number;
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
  /** Maximum accepted WebSocket message size, in bytes. */
  readonly maxWebSocketMessageBytes: number;
  /** Ping interval on signaling sockets, in seconds. */
  readonly wsHeartbeatSeconds: number;
  /** Idle (no client message) timeout on signaling sockets, in seconds. */
  readonly wsIdleTimeoutSeconds: number;
  readonly turn: TurnSettings;
  readonly apns: ApnsSettings;
  readonly rateLimits: {
    readonly pairingCreatePerIp: RateLimitRule;
    readonly claimPerIp: RateLimitRule;
    readonly perPairing: RateLimitRule;
    readonly signalUpgradePerIp: RateLimitRule;
    /** Detection events: 1 per 30 s per pairing (backend.md §3). */
    readonly eventsPerPairing: RateLimitRule;
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

function listFromEnv(env: NodeJS.ProcessEnv, key: string): readonly string[] {
  const raw = env[key];
  if (raw === undefined || raw === '') return [];
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const port = intFromEnv(env, 'PORT', 8080);
  const eventIntervalSeconds = intFromEnv(env, 'EVENT_MIN_INTERVAL_SECONDS', 30);

  return {
    nodeEnv: nodeEnvFromEnv(env),
    host: env['HOST'] ?? '0.0.0.0',
    port,
    metricsPort: intFromEnv(env, 'METRICS_PORT', port),
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
    wsHeartbeatSeconds: intFromEnv(env, 'WS_HEARTBEAT_SECONDS', 30),
    wsIdleTimeoutSeconds: intFromEnv(env, 'WS_IDLE_TIMEOUT_SECONDS', 300),
    turn: {
      sharedSecret: env['TURN_SHARED_SECRET'] ?? '',
      ttlSeconds: intFromEnv(env, 'TURN_TTL_SECONDS', 3600),
      uris: listFromEnv(env, 'TURN_URIS'),
    },
    apns: {
      privateKeyPem: env['APNS_KEY_P8'] ?? '',
      keyId: env['APNS_KEY_ID'] ?? '',
      teamId: env['APNS_TEAM_ID'] ?? '',
      topic: env['APNS_TOPIC'] ?? '',
      requestTimeoutMs: intFromEnv(env, 'APNS_TIMEOUT_MS', 5000),
    },
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
      signalUpgradePerIp: hourlyRule(
        intFromEnv(env, 'RATE_LIMIT_SIGNAL_UPGRADE_PER_HOUR', 120),
      ),
      // One event per 30 s, no burst: the bucket holds a single token and
      // refills over the interval.
      eventsPerPairing: {
        capacity: 1,
        refillPerSecond: 1 / eventIntervalSeconds,
      },
    },
  };
}

/** True when TURN credentials can actually be issued. */
export function turnConfigured(config: Config): boolean {
  return config.turn.sharedSecret !== '' && config.turn.uris.length > 0;
}

/** True when the APNs provider credentials are complete. */
export function apnsConfigured(config: Config): boolean {
  const { privateKeyPem, keyId, teamId, topic } = config.apns;
  return (
    privateKeyPem !== '' && keyId !== '' && teamId !== '' && topic !== ''
  );
}
