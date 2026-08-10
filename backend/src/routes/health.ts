import type { FastifyInstance } from 'fastify';

export const SERVICE_NAME = 'kidscam-backend';

export interface VersionInfo {
  readonly service: string;
  readonly version: string;
  readonly api: string;
  readonly commit: string;
}

export function versionInfo(env: NodeJS.ProcessEnv = process.env): VersionInfo {
  return {
    service: SERVICE_NAME,
    version: env['APP_VERSION'] ?? '0.1.0',
    api: 'v1',
    commit: env['GIT_SHA'] ?? 'unknown',
  };
}

/** Ops endpoints: unauthenticated and carrying no pairing or device data. */
export function registerHealthRoutes(app: FastifyInstance): void {
  app.get('/v1/health', (_request, reply) => reply.send({ status: 'ok' }));
  app.get('/v1/version', (_request, reply) => reply.send(versionInfo()));
}
