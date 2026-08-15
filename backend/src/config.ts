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
  /**
   * coturn `use-auth-secret` shared secret. Set when we run the relay: coturn
   * recomputes every credential we issue, so nothing is stored on either side.
   * Empty when a hosted relay issues its own credentials instead.
   */
  readonly sharedSecret: string;
  /**
   * Credential pair issued by a hosted relay (metered.ca and the like). Such a
   * relay never shared a secret with us and so cannot recompute an HMAC; the
   * pair it handed out is passed through to clients verbatim. Both empty when
   * the relay is our own coturn.
   */
  readonly staticUsername: string;
  readonly staticCredential: string;
  readonly ttlSeconds: number;
  readonly uris: readonly string[];
}

/** Which credential scheme the configured relay expects. */
export type TurnScheme = 'hmac' | 'static' | 'none';

/**
 * TIDAL application credentials.
 *
 * The two halves are treated completely differently, and the difference is the
 * whole reason this lives here rather than in the app's Info.plist.
 *
 * `clientId` is public by construction — every OAuth flow puts it on the wire —
 * and it is what a Camera needs to sign a parent in. It is served to
 * authenticated devices over `GET /v1/config` so it can be rotated without an
 * App Store release.
 *
 * `clientSecret` **never leaves this process.** It belongs to the confidential
 * client flows (`client_credentials`, for catalogue calls made by this server),
 * and an app that shipped it would be publishing it: an IPA is a zip, and
 * `Info.plist` inside it is plain text. There is deliberately no code path that
 * puts it in a response — see the test that asserts exactly that.
 */
export interface TidalSettings {
  readonly clientId: string;
  readonly clientSecret: string;
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
  /** Accepted clock skew for `CribWire-HMAC` timestamps, in seconds. */
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
  /**
   * How long the hub may reuse a pairing's cached device roster before
   * reloading it. Bounds how long a revocation performed on another instance
   * can stay invisible to this one.
   */
  readonly wsRosterTtlSeconds: number;
  /**
   * How long a client may cache `GET /v1/config` before asking again. The lever
   * that decides how fast a rotated client id reaches the fleet.
   */
  readonly configTtlSeconds: number;
  readonly turn: TurnSettings;
  readonly apns: ApnsSettings;
  readonly tidal: TidalSettings;
  readonly rateLimits: {
    readonly pairingCreatePerIp: RateLimitRule;
    readonly claimPerIp: RateLimitRule;
    readonly perPairing: RateLimitRule;
    readonly signalUpgradePerIp: RateLimitRule;
    /** Detection events: 1 per 30 s per pairing (backend.md §3). */
    readonly eventsPerPairing: RateLimitRule;
    /** Coarse per-IP budget so malformed posts cannot be free either. */
    readonly eventsPerIp: RateLimitRule;
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

/**
 * The two credential schemes are mutually exclusive. A shared secret means the
 * relay derives the credential itself; a static pair means the relay issued it
 * upstream and knows nothing of ours. Holding both says nothing about which
 * relay is actually on the other end, so it fails here rather than letting the
 * process pick one and hand out credentials the relay will reject.
 */
function turnFromEnv(env: NodeJS.ProcessEnv): TurnSettings {
  const sharedSecret = env['TURN_SHARED_SECRET'] ?? '';
  const staticUsername = env['TURN_STATIC_USERNAME'] ?? '';
  const staticCredential = env['TURN_STATIC_CREDENTIAL'] ?? '';

  if (
    sharedSecret !== '' &&
    (staticUsername !== '' || staticCredential !== '')
  ) {
    throw new Error(
      'TURN_SHARED_SECRET and TURN_STATIC_USERNAME/TURN_STATIC_CREDENTIAL are mutually exclusive',
    );
  }
  if ((staticUsername === '') !== (staticCredential === '')) {
    throw new Error(
      'TURN_STATIC_USERNAME and TURN_STATIC_CREDENTIAL must be set together',
    );
  }

  return {
    sharedSecret,
    staticUsername,
    staticCredential,
    ttlSeconds: intFromEnv(env, 'TURN_TTL_SECONDS', 3600),
    uris: listFromEnv(env, 'TURN_URIS'),
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const port = intFromEnv(env, 'PORT', 8080);
  const eventIntervalSeconds = intFromEnv(
    env,
    'EVENT_MIN_INTERVAL_SECONDS',
    30,
  );

  return {
    nodeEnv: nodeEnvFromEnv(env),
    host: env['HOST'] ?? '0.0.0.0',
    port,
    metricsPort: intFromEnv(env, 'METRICS_PORT', port),
    databaseUrl:
      env['DATABASE_URL'] ??
      'postgres://cribwire:cribwire@localhost:5432/cribwire',
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
    wsRosterTtlSeconds: intFromEnv(env, 'WS_ROSTER_TTL_SECONDS', 30),
    configTtlSeconds: intFromEnv(env, 'CONFIG_TTL_SECONDS', 3600),
    turn: turnFromEnv(env),
    tidal: {
      clientId: env['TIDAL_CLIENT_ID'] ?? '',
      clientSecret: env['TIDAL_CLIENT_SECRET'] ?? '',
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
      eventsPerIp: hourlyRule(
        intFromEnv(env, 'RATE_LIMIT_EVENTS_PER_HOUR', 240),
      ),
    },
  };
}

/**
 * Which scheme the relay behind `TURN_URIS` expects, or `none` when neither
 * set of credentials is present. `turnFromEnv` has already rejected the
 * ambiguous combinations, so the order of these checks never decides anything.
 */
export function turnScheme(turn: TurnSettings): TurnScheme {
  if (turn.sharedSecret !== '') return 'hmac';
  if (turn.staticUsername !== '' && turn.staticCredential !== '') {
    return 'static';
  }
  return 'none';
}

/** True when TURN credentials can actually be issued. */
export function turnConfigured(config: Config): boolean {
  return config.turn.uris.length > 0 && turnScheme(config.turn) !== 'none';
}

/**
 * True when a Camera could actually sign a parent in to TIDAL.
 *
 * The id alone: the secret is not part of the answer, because the sign-in flows
 * a phone uses (device login, authorization code + PKCE) are public-client
 * flows that have no secret in them. A deployment holding only the secret can
 * talk to TIDAL itself and still has nothing to offer a Camera.
 */
export function tidalConfigured(config: Config): boolean {
  return config.tidal.clientId !== '';
}

/** True when the APNs provider credentials are complete. */
export function apnsConfigured(config: Config): boolean {
  const { privateKeyPem, keyId, teamId, topic } = config.apns;
  return privateKeyPem !== '' && keyId !== '' && teamId !== '' && topic !== '';
}
