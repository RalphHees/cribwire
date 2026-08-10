/** Domain types mirroring the Postgres schema in backend.md §5. */

export type Role = 'camera' | 'viewer';
export type PairingStatus = 'pending' | 'active' | 'revoked';
export type ApnsEnvironment = 'sandbox' | 'production';

export interface Pairing {
  readonly id: string;
  /** HMAC authentication key. Decrypts nothing; never logged, never returned. */
  readonly kAuth: Buffer;
  readonly status: PairingStatus;
  readonly createdAt: Date;
  readonly claimedAt: Date | null;
}

export interface Device {
  readonly id: string;
  readonly pairingId: string;
  readonly role: Role;
  /**
   * The device's own 32-byte HMAC key (protocol.md 1.1). Generated on-device,
   * uploaded once in the bootstrap-authenticated body, and used to
   * authenticate every later request from this device. Decrypts nothing;
   * never logged, never returned.
   */
  readonly deviceKey: Buffer;
  readonly apnsToken: string;
  readonly apnsEnvironment: ApnsEnvironment;
  readonly createdAt: Date;
  readonly lastSeenAt: Date | null;
}

export function isRole(value: unknown): value is Role {
  return value === 'camera' || value === 'viewer';
}

export function isApnsEnvironment(value: unknown): value is ApnsEnvironment {
  return value === 'sandbox' || value === 'production';
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** Lowercase canonical UUID, as pinned for the QR payload in protocol.md. */
export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID_RE.test(value);
}
