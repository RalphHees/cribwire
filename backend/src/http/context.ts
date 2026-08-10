import type { Config } from '../config.ts';
import type { Logger } from '../logger.ts';
import type { NonceStore } from '../auth/nonce-store.ts';
import type { Metrics } from '../metrics/registry.ts';
import type { ApnsSender } from '../push/apns.ts';
import type { RateLimiter } from '../ratelimit/token-bucket.ts';
import type { Repository } from '../repositories/types.ts';
import type { SignalingControl } from '../ws/hub.ts';

/** Everything a route handler is allowed to reach for. */
export interface AppContext {
  readonly config: Config;
  readonly repository: Repository;
  readonly nonceStore: NonceStore;
  readonly rateLimiter: RateLimiter;
  readonly logger: Logger;
  readonly metrics: Metrics;
  readonly apns: ApnsSender;
  /**
   * Set once the signaling hub exists, so revocation can drop live sockets.
   * Null on an instance that serves REST only.
   */
  signaling: SignalingControl | null;
  /** Injectable clock so tests can move time without sleeping. */
  readonly now: () => Date;
}
