/**
 * APNs sender port (backend.md §3 "Push notifications").
 *
 * The payload is assembled here, but the `ciphertext` inside it is copied
 * verbatim from the camera's request: the server cannot read it, and Apple
 * cannot either. The visible alert is a fixed localizable key.
 *
 * A port with a fake keeps the test suite free of any dependency on Apple
 * connectivity; `Http2ApnsSender` is exercised only in production and staging.
 */

import type { ApnsEnvironment } from '../domain/types.ts';

export interface ApnsNotification {
  readonly deviceToken: string;
  readonly environment: ApnsEnvironment;
  readonly pairingId: string;
  /** Opaque sealed envelope, forwarded byte-for-byte. */
  readonly ciphertext: string;
}

export type ApnsResult =
  | { readonly status: 'sent' }
  /** APNs answered 410: the token is dead and its device row must go. */
  | { readonly status: 'unregistered' }
  | { readonly status: 'failed'; readonly reason: string };

export interface ApnsSender {
  send(notification: ApnsNotification): Promise<ApnsResult>;
  close(): Promise<void>;
}

/**
 * Localizable alert key. This is the only text APNs and the lock screen ever
 * see: the app opens the ciphertext and replaces it with the specific sentence
 * once it is running.
 */
export const EVENT_ALERT_LOC_KEY = 'EVENT_GENERIC';

export interface ApnsPayload {
  readonly aps: {
    readonly alert: { readonly 'loc-key': string };
  };
  readonly pairingId: string;
  readonly ciphertext: string;
}

/**
 * The exact payload pinned in backend.md §3.
 *
 * No `mutable-content`: that flag exists to hand a push to a Notification
 * Service Extension before display, and the iOS app has no extension — it
 * decrypts the payload in-process. Sending the flag anyway would be inert, and
 * would suggest a delivery-time rewrite that does not happen.
 */
export function buildApnsPayload(notification: ApnsNotification): ApnsPayload {
  return {
    aps: {
      alert: { 'loc-key': EVENT_ALERT_LOC_KEY },
    },
    pairingId: notification.pairingId,
    ciphertext: notification.ciphertext,
  };
}

/**
 * Used when no APNs credentials are configured (local development, and any
 * environment where pushing would be meaningless). Counts as a failure rather
 * than silently succeeding, so a misconfigured deployment shows up in metrics.
 */
export class DisabledApnsSender implements ApnsSender {
  send(): Promise<ApnsResult> {
    return Promise.resolve({ status: 'failed', reason: 'apns_not_configured' });
  }

  close(): Promise<void> {
    return Promise.resolve();
  }
}
