/**
 * APNs over HTTP/2 with token-based (`.p8`) authentication — backend.md §3.
 *
 * Implemented on `node:http2` and `node:crypto` rather than a client library:
 * the protocol surface we need is one POST and one JWT, and an APNs library
 * would be a dependency holding the push credential.
 *
 * The provider token is an ES256 JWT `{alg, kid}` / `{iss, iat}`, valid for up
 * to an hour; Apple rejects tokens refreshed more often than once every 20
 * minutes, so it is cached and rotated on a 50-minute clock.
 */

import { createPrivateKey, sign as cryptoSign } from 'node:crypto';
import type { KeyObject } from 'node:crypto';
import http2 from 'node:http2';
import type { Logger } from '../logger.ts';
import type { ApnsNotification, ApnsResult, ApnsSender } from './apns.ts';
import { buildApnsPayload } from './apns.ts';

export const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
} as const;

const TOKEN_LIFETIME_MS = 50 * 60 * 1000;

export interface ApnsCredentials {
  /** Contents of the `.p8` file (PKCS#8 PEM). Never logged. */
  readonly privateKeyPem: string;
  /** Key id from the Apple Developer portal. */
  readonly keyId: string;
  readonly teamId: string;
  /** The app's bundle identifier, sent as `apns-topic`. */
  readonly topic: string;
  readonly requestTimeoutMs: number;
}

function base64url(input: Buffer | string): string {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/** ES256 JWT. `ieee-p1363` yields the raw r||s signature JWS requires. */
export function signProviderToken(
  key: KeyObject,
  keyId: string,
  teamId: string,
  issuedAtSeconds: number,
): string {
  const header = base64url(
    JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }),
  );
  const payload = base64url(
    JSON.stringify({ iss: teamId, iat: issuedAtSeconds }),
  );
  const signingInput = `${header}.${payload}`;
  const signature = cryptoSign('sha256', Buffer.from(signingInput, 'utf8'), {
    key,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}

interface CachedToken {
  readonly value: string;
  readonly issuedAtMs: number;
}

export class Http2ApnsSender implements ApnsSender {
  readonly #credentials: ApnsCredentials;
  readonly #privateKey: KeyObject;
  readonly #logger: Logger;
  readonly #now: () => number;
  readonly #sessions = new Map<string, http2.ClientHttp2Session>();
  #token: CachedToken | null = null;
  #closed = false;

  constructor(
    credentials: ApnsCredentials,
    logger: Logger,
    now: () => number = Date.now,
  ) {
    this.#credentials = credentials;
    this.#privateKey = createPrivateKey(credentials.privateKeyPem);
    this.#logger = logger;
    this.#now = now;
  }

  async send(notification: ApnsNotification): Promise<ApnsResult> {
    if (this.#closed) {
      return { status: 'failed', reason: 'sender_closed' };
    }
    const body = Buffer.from(
      JSON.stringify(buildApnsPayload(notification)),
      'utf8',
    );

    try {
      const session = this.#session(APNS_HOSTS[notification.environment]);
      return await this.#request(session, notification.deviceToken, body);
    } catch (error) {
      return {
        status: 'failed',
        reason: error instanceof Error ? error.message : 'unknown',
      };
    }
  }

  async close(): Promise<void> {
    this.#closed = true;
    for (const session of this.#sessions.values()) {
      session.close();
    }
    this.#sessions.clear();
    await Promise.resolve();
  }

  #providerToken(): string {
    const nowMs = this.#now();
    if (this.#token !== null && nowMs - this.#token.issuedAtMs < TOKEN_LIFETIME_MS) {
      return this.#token.value;
    }
    const value = signProviderToken(
      this.#privateKey,
      this.#credentials.keyId,
      this.#credentials.teamId,
      Math.floor(nowMs / 1000),
    );
    this.#token = { value, issuedAtMs: nowMs };
    return value;
  }

  #session(origin: string): http2.ClientHttp2Session {
    const existing = this.#sessions.get(origin);
    if (existing !== undefined && !existing.closed && !existing.destroyed) {
      return existing;
    }
    const session = http2.connect(origin);
    session.on('error', (error: Error) => {
      // Message only — never the token or the payload.
      this.#logger.error('apns session error', { reason: error.message });
      this.#sessions.delete(origin);
    });
    session.on('close', () => {
      this.#sessions.delete(origin);
    });
    this.#sessions.set(origin, session);
    return session;
  }

  #request(
    session: http2.ClientHttp2Session,
    deviceToken: string,
    body: Buffer,
  ): Promise<ApnsResult> {
    return new Promise<ApnsResult>((resolve) => {
      const stream = session.request({
        ':method': 'POST',
        ':path': `/3/device/${deviceToken}`,
        authorization: `bearer ${this.#providerToken()}`,
        'apns-push-type': 'alert',
        'apns-topic': this.#credentials.topic,
        'apns-priority': '10',
        'content-type': 'application/json',
        'content-length': body.length,
      });

      let status = 0;
      const chunks: Buffer[] = [];
      let settled = false;
      const settle = (result: ApnsResult): void => {
        if (settled) return;
        settled = true;
        resolve(result);
      };

      stream.setTimeout(this.#credentials.requestTimeoutMs, () => {
        stream.close(http2.constants.NGHTTP2_CANCEL);
        settle({ status: 'failed', reason: 'timeout' });
      });
      stream.on('response', (headers) => {
        status = Number(headers[':status'] ?? 0);
      });
      stream.on('data', (chunk: Buffer) => chunks.push(chunk));
      stream.on('error', (error: Error) => {
        settle({ status: 'failed', reason: error.message });
      });
      stream.on('end', () => {
        if (status === 200) {
          settle({ status: 'sent' });
          return;
        }
        if (status === 410) {
          settle({ status: 'unregistered' });
          return;
        }
        // APNs answers `{"reason": "..."}`; the reason is an Apple-defined
        // enum, safe to record, and carries nothing about the payload.
        settle({
          status: 'failed',
          reason: apnsReason(Buffer.concat(chunks), status),
        });
      });

      stream.end(body);
    });
  }
}

function apnsReason(body: Buffer, status: number): string {
  try {
    const parsed: unknown = JSON.parse(body.toString('utf8'));
    if (
      typeof parsed === 'object' &&
      parsed !== null &&
      typeof (parsed as { reason?: unknown }).reason === 'string'
    ) {
      return `${status}:${(parsed as { reason: string }).reason}`;
    }
  } catch {
    // Fall through to the bare status.
  }
  return `status_${status}`;
}
