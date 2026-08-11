/**
 * In-process APNs double.
 *
 * The suite must never depend on Apple connectivity, so every test runs
 * against this: it records what would have been sent (including the exact
 * payload, which lets a test prove the ciphertext is forwarded verbatim and
 * never decrypted) and can be told to answer `410 Unregistered` for a token.
 */

import type {
  ApnsNotification,
  ApnsResult,
  ApnsSender,
} from '../../src/push/apns.ts';
import { buildApnsPayload } from '../../src/push/apns.ts';
import type { ApnsPayload } from '../../src/push/apns.ts';

export interface RecordedNotification {
  readonly notification: ApnsNotification;
  readonly payload: ApnsPayload;
}

export class FakeApnsSender implements ApnsSender {
  readonly sent: RecordedNotification[] = [];
  readonly #unregistered = new Set<string>();
  readonly #failing = new Set<string>();
  closed = false;

  /** Answer 410 for this token, as APNs does for a dead installation. */
  markUnregistered(deviceToken: string): void {
    this.#unregistered.add(deviceToken);
  }

  markFailing(deviceToken: string): void {
    this.#failing.add(deviceToken);
  }

  send(notification: ApnsNotification): Promise<ApnsResult> {
    this.sent.push({
      notification,
      payload: buildApnsPayload(notification),
    });
    if (this.#unregistered.has(notification.deviceToken)) {
      return Promise.resolve({ status: 'unregistered' });
    }
    if (this.#failing.has(notification.deviceToken)) {
      return Promise.resolve({
        status: 'failed',
        reason: '429:TooManyRequests',
      });
    }
    return Promise.resolve({ status: 'sent' });
  }

  close(): Promise<void> {
    this.closed = true;
    return Promise.resolve();
  }

  tokens(): string[] {
    return this.sent.map((entry) => entry.notification.deviceToken);
  }

  reset(): void {
    this.sent.length = 0;
  }
}
