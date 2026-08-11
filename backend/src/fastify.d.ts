import type { AuthContext } from './auth/verify.ts';

declare module 'fastify' {
  interface FastifyRequest {
    /**
     * Exact bytes received, kept for `CribWire-HMAC` canonicalisation. Never
     * logged and never inspected beyond JSON parsing of our own envelopes.
     */
    rawBody: Buffer | null;
    /** Set once `authenticate()` has verified the request. */
    auth: AuthContext | null;
  }
}
