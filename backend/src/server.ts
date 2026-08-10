/**
 * Fastify application assembly.
 *
 * Request logging is disabled: Fastify's default logger would record URLs and
 * headers, and backend.md §6 forbids logging payloads and tokens. What we do
 * log goes through `logger.ts`, which redacts by key name.
 */

import Fastify from 'fastify';
import type { FastifyInstance } from 'fastify';
import type { AppContext } from './http/context.ts';
import { sendError } from './http/errors.ts';
import { registerDeviceRoutes } from './routes/devices.ts';
import { registerEventRoutes } from './routes/events.ts';
import { registerHealthRoutes } from './routes/health.ts';
import { registerMetricsRoute } from './routes/metrics.ts';
import { registerPairingRoutes } from './routes/pairings.ts';
import { registerTurnRoutes } from './routes/turn.ts';

function baseServer(ctx: AppContext): FastifyInstance {
  return Fastify({
    // No Fastify request logging: it would record URLs and headers.
    logger: false,
    bodyLimit: ctx.config.maxBodyBytes,
    trustProxy: true,
    routerOptions: {
      // Paths are signed byte-for-byte by the client; Fastify must not rewrite
      // them before we canonicalise.
      ignoreTrailingSlash: false,
      caseSensitive: true,
    },
  });
}

export function buildServer(ctx: AppContext): FastifyInstance {
  const app = baseServer(ctx);

  app.decorateRequest('rawBody', null);
  app.decorateRequest('auth', null);

  // Keep the exact bytes for HMAC canonicalisation, then parse JSON ourselves.
  app.addContentTypeParser(
    'application/json',
    { parseAs: 'buffer' },
    (request, payload, done) => {
      const raw = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
      request.rawBody = raw;
      if (raw.length === 0) {
        done(null, {});
        return;
      }
      try {
        done(null, JSON.parse(raw.toString('utf8')) as unknown);
      } catch {
        done(new SyntaxError('invalid JSON body'), undefined);
      }
    },
  );

  // Bodies on other content types are still hashed verbatim; nothing parses
  // them, which is what keeps opaque payloads opaque.
  app.addContentTypeParser(
    '*',
    { parseAs: 'buffer' },
    (request, payload, done) => {
      request.rawBody = Buffer.isBuffer(payload)
        ? payload
        : Buffer.from(payload);
      done(null, undefined);
    },
  );

  app.setNotFoundHandler((_request, reply) =>
    sendError(reply, 404, 'not_found', 'Unknown endpoint'),
  );

  app.setErrorHandler(
    (error: Error & { statusCode?: number }, request, reply) => {
      const status = error.statusCode ?? 500;
      if (status === 413) {
        return sendError(
          reply,
          413,
          'body_too_large',
          'Request body too large',
        );
      }
      if (status >= 400 && status < 500) {
        return sendError(reply, status, 'invalid_request', 'Malformed request');
      }
      ctx.logger.error('unhandled error', {
        route: request.routeOptions.url ?? 'unknown',
        method: request.method,
        // Message only: never the body, never the stack in the response.
        reason: error.message,
      });
      return sendError(reply, 500, 'internal_error', 'Internal error');
    },
  );

  registerHealthRoutes(app);
  registerPairingRoutes(app, ctx);
  registerDeviceRoutes(app, ctx);
  registerTurnRoutes(app, ctx);
  registerEventRoutes(app, ctx);

  // A dedicated metrics port keeps the scrape endpoint off the public
  // listener; when they are the same port it is served here.
  if (ctx.config.metricsPort === ctx.config.port) {
    registerMetricsRoute(app, ctx);
  }

  return app;
}

/** Standalone `/metrics` listener, used when `METRICS_PORT` differs. */
export function buildMetricsServer(ctx: AppContext): FastifyInstance {
  const app = baseServer(ctx);
  app.setNotFoundHandler((_request, reply) =>
    sendError(reply, 404, 'not_found', 'Unknown endpoint'),
  );
  registerMetricsRoute(app, ctx);
  return app;
}
