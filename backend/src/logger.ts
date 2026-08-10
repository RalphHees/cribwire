/**
 * Logging policy (backend.md §6, security.md §7):
 *
 * - Never log request bodies, `K_auth`, APNs tokens, or MACs.
 * - Fastify's own request logging is therefore disabled in `server.ts`; the
 *   redactions below are a second line of defence for hand-written log calls.
 */

/** Keys that must never reach a log sink, whatever the call site passes. */
const FORBIDDEN_KEYS = new Set([
  'k_auth',
  'kauth',
  'kAuth',
  'apnstoken',
  'apns_token',
  'token',
  'authorization',
  'mac',
  'body',
  'ciphertext',
  'blob',
  'secret',
  'password',
]);

export type LogFields = Record<string, unknown>;

export function redact(fields: LogFields): LogFields {
  const out: LogFields = {};
  for (const [key, value] of Object.entries(fields)) {
    out[key] = FORBIDDEN_KEYS.has(key.toLowerCase()) ? '[redacted]' : value;
  }
  return out;
}

export interface Logger {
  info(message: string, fields?: LogFields): void;
  warn(message: string, fields?: LogFields): void;
  error(message: string, fields?: LogFields): void;
}

const LEVELS: Record<string, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
  silent: 100,
};

export function createLogger(level = 'info'): Logger {
  const threshold = LEVELS[level] ?? LEVELS['info'] ?? 20;

  function emit(
    levelName: 'info' | 'warn' | 'error',
    message: string,
    fields: LogFields | undefined,
  ): void {
    if ((LEVELS[levelName] ?? 0) < threshold) return;
    const line = JSON.stringify({
      level: levelName,
      time: new Date().toISOString(),
      msg: message,
      ...(fields ? redact(fields) : {}),
    });
    // Structured logs go to stderr so stdout stays free for CLI output.
    console.error(line);
  }

  return {
    info: (message, fields) => {
      emit('info', message, fields);
    },
    warn: (message, fields) => {
      emit('warn', message, fields);
    },
    error: (message, fields) => {
      emit('error', message, fields);
    },
  };
}
