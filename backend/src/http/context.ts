import type { Config } from '../config.ts';
import type { Logger } from '../logger.ts';
import type { NonceStore } from '../auth/nonce-store.ts';
import type { RateLimiter } from '../ratelimit/token-bucket.ts';
import type { Repository } from '../repositories/types.ts';

/** Everything a route handler is allowed to reach for. */
export interface AppContext {
  readonly config: Config;
  readonly repository: Repository;
  readonly nonceStore: NonceStore;
  readonly rateLimiter: RateLimiter;
  readonly logger: Logger;
  /** Injectable clock so tests can move time without sleeping. */
  readonly now: () => Date;
}
