/**
 * `GET /v1/signal` — the WebSocket upgrade (backend.md §3).
 *
 * The upgrade carries the same `CribWire-HMAC` header as every REST call, with
 * a device principal, and is verified before a single frame is read. An
 * unauthenticated upgrade never becomes a WebSocket: it is answered with a
 * plain `401` and the socket is destroyed.
 */

import type { IncomingMessage } from 'node:http';
import type { Duplex } from 'node:stream';
import type { FastifyInstance } from 'fastify';
import { WebSocketServer } from 'ws';
import type { RawData, WebSocket } from 'ws';
import type { Device } from '../domain/types.ts';
import { verifyDeviceRequest } from '../http/authenticate.ts';
import type { AppContext } from '../http/context.ts';
import type { Connection, SignalingHub } from './hub.ts';

export const SIGNAL_PATH = '/v1/signal';

function pathOf(url: string | undefined): string {
  const target = url ?? '/';
  const queryStart = target.indexOf('?');
  return queryStart < 0 ? target : target.slice(0, queryStart);
}

/** Client IP for the per-IP upgrade budget. Not stored, not logged. */
function clientIpOf(request: IncomingMessage): string {
  const forwarded = request.headers['x-forwarded-for'];
  const first = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  if (typeof first === 'string' && first.length > 0) {
    return (first.split(',')[0] ?? '').trim();
  }
  return request.socket.remoteAddress ?? 'unknown';
}

function refuse(
  socket: Duplex,
  status: number,
  code: string,
  message: string,
  extraHeaders: readonly string[] = [],
): void {
  const body = JSON.stringify({ error: code, message });
  const headers = [
    `HTTP/1.1 ${status} ${status === 401 ? 'Unauthorized' : 'Bad Request'}`,
    'content-type: application/json',
    `content-length: ${Buffer.byteLength(body)}`,
    'connection: close',
    ...extraHeaders,
  ];
  socket.write(`${headers.join('\r\n')}\r\n\r\n${body}`);
  socket.destroy();
}

export function registerSignaling(
  app: FastifyInstance,
  ctx: AppContext,
  hub: SignalingHub,
): WebSocketServer {
  const wss = new WebSocketServer({
    noServer: true,
    // Frame-level cap: `ws` closes with 1009 before the router ever sees an
    // oversized message.
    maxPayload: ctx.config.maxWebSocketMessageBytes,
  });

  app.server.on(
    'upgrade',
    (request: IncomingMessage, socket: Duplex, head: Buffer) => {
      void handleUpgrade(request, socket, head);
    },
  );

  async function handleUpgrade(
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ): Promise<void> {
    if (pathOf(request.url) !== SIGNAL_PATH) {
      ctx.metrics.wsUpgradeRejected('unknown_path');
      refuse(socket, 404, 'not_found', 'Unknown endpoint');
      return;
    }

    const limit = await ctx.rateLimiter.consume(
      `ip:signal-upgrade:${clientIpOf(request)}`,
      ctx.config.rateLimits.signalUpgradePerIp,
    );
    if (!limit.allowed) {
      ctx.metrics.wsUpgradeRejected('rate_limited');
      refuse(socket, 429, 'rate_limited', 'Too many connection attempts', [
        `retry-after: ${limit.retryAfterSeconds}`,
      ]);
      return;
    }

    const result = await verifyDeviceRequest(ctx, {
      method: 'GET',
      path: SIGNAL_PATH,
      authorization: request.headers.authorization,
      rawBody: Buffer.alloc(0),
    });
    if (!result.ok) {
      ctx.metrics.wsUpgradeRejected(result.code);
      ctx.logger.warn('signal upgrade rejected', { code: result.code });
      refuse(socket, 401, result.code, 'Invalid CribWire-HMAC credentials');
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws: WebSocket) => {
      attach(ws, result.device);
    });
  }

  function attach(ws: WebSocket, device: Device): void {
    let connection: Connection | null = null;
    // Frames can arrive before `attach` resolves; hold them so ordering
    // survives the await.
    const pending: string[] = [];
    let closedEarly = false;

    ws.on('message', (data: RawData, isBinary: boolean) => {
      if (isBinary) {
        ctx.metrics.wsMessage('malformed');
        ws.close(1003, 'binary_unsupported');
        return;
      }
      const text = Array.isArray(data)
        ? Buffer.concat(data).toString('utf8')
        : Buffer.from(data as ArrayBuffer).toString('utf8');
      if (connection === null) {
        pending.push(text);
        return;
      }
      void hub.handleMessage(connection, text);
    });

    ws.on('pong', () => {
      if (connection !== null) hub.handlePong(connection);
    });

    ws.on('error', (error: Error) => {
      ctx.logger.warn('signal socket error', { reason: error.message });
    });

    ws.on('close', () => {
      closedEarly = true;
      if (connection !== null) void hub.detach(connection);
    });

    void hub
      .attach(ws, device)
      .then((established) => {
        if (closedEarly) {
          void hub.detach(established);
          return;
        }
        connection = established;
        for (const message of pending.splice(0)) {
          void hub.handleMessage(established, message);
        }
      })
      .catch((error: unknown) => {
        ctx.logger.error('signal attach failed', {
          reason: error instanceof Error ? error.message : 'unknown',
        });
        ws.close(1011, 'attach_failed');
      });
  }

  return wss;
}
