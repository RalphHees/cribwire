import { createAppResources } from './app.ts';
import { loadConfig } from './config.ts';
import { createLogger } from './logger.ts';
import { buildServer } from './server.ts';

const config = loadConfig();
const logger = createLogger(config.logLevel);
const resources = createAppResources(config, logger);
const app = buildServer(resources.ctx);

async function shutdown(signal: string): Promise<void> {
  logger.info('shutting down', { signal });
  try {
    await app.close();
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
} catch (error) {
  logger.error('failed to start', {
    reason: error instanceof Error ? error.message : 'unknown',
  });
  process.exit(1);
}
