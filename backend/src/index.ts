import { createAppResources } from './app.ts';
import { loadConfig } from './config.ts';
import { createLogger } from './logger.ts';
import { buildMetricsServer, buildServer } from './server.ts';
import { attachSignaling } from './ws/attach.ts';

const config = loadConfig();
const logger = createLogger(config.logLevel);
const resources = createAppResources(config, logger);
const app = buildServer(resources.ctx);
const signaling = attachSignaling(app, resources.ctx, resources.bus);
const metricsApp =
  config.metricsPort === config.port ? null : buildMetricsServer(resources.ctx);

async function shutdown(signal: string): Promise<void> {
  logger.info('shutting down', { signal });
  try {
    await signaling.close();
    await app.close();
    if (metricsApp !== null) await metricsApp.close();
    await resources.close();
  } finally {
    process.exit(0);
  }
}

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    void shutdown(signal);
  });
}

try {
  await app.listen({ host: config.host, port: config.port });
  logger.info('listening', { host: config.host, port: config.port });
  if (metricsApp !== null) {
    await metricsApp.listen({ host: config.host, port: config.metricsPort });
    logger.info('metrics listening', { port: config.metricsPort });
  }
} catch (error) {
  logger.error('failed to start', {
    reason: error instanceof Error ? error.message : 'unknown',
  });
  process.exit(1);
}
