import type { FastifyReply } from 'fastify';

export interface ErrorBody {
  readonly error: {
    readonly code: string;
    readonly message: string;
  };
}

/**
 * Error responses carry a stable machine-readable code and a message that is
 * safe to show a user — never key material, tokens, or body contents.
 */
export function sendError(
  reply: FastifyReply,
  status: number,
  code: string,
  message: string,
): FastifyReply {
  const body: ErrorBody = { error: { code, message } };
  return reply.status(status).send(body);
}
