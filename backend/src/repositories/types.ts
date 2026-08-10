/**
 * Persistence port. Rules that must not race (max viewers, claim-once,
 * pairing expiry) are resolved inside the implementation so Postgres can hold
 * them in a transaction and the in-memory implementation can mirror them.
 */

import type { ApnsEnvironment, Device, Pairing } from '../domain/types.ts';

export interface CreatePairingInput {
  readonly pairingId: string;
  readonly kAuth: Buffer;
  readonly cameraDeviceId: string;
  /** The camera's own HMAC key, uploaded in the bootstrap body. */
  readonly cameraDeviceKey: Buffer;
  readonly apnsToken: string;
  readonly apnsEnvironment: ApnsEnvironment;
  readonly now: Date;
}

export type CreatePairingResult =
  | { readonly ok: true; readonly pairing: Pairing; readonly device: Device }
  | { readonly ok: false; readonly reason: 'conflict' };

export interface ClaimPairingInput {
  readonly pairingId: string;
  readonly viewerDeviceId: string;
  /** The viewer's own HMAC key, uploaded in the bootstrap body. */
  readonly viewerDeviceKey: Buffer;
  readonly apnsToken: string;
  readonly apnsEnvironment: ApnsEnvironment;
  readonly maxViewers: number;
  /** Pending pairings created before this instant are expired. */
  readonly expiredBefore: Date;
  readonly now: Date;
}

export type ClaimPairingResult =
  | { readonly ok: true; readonly pairing: Pairing; readonly device: Device }
  | {
      readonly ok: false;
      readonly reason: 'not_found' | 'revoked' | 'expired' | 'too_many_viewers';
    };

export interface UpdateDeviceTokenInput {
  readonly pairingId: string;
  /** The authenticated device itself; never taken from a request body. */
  readonly deviceId: string;
  readonly apnsToken: string;
  readonly apnsEnvironment: ApnsEnvironment;
  readonly now: Date;
}

export interface PurgeResult {
  readonly revokedPairings: number;
  readonly expiredPairings: number;
}

export interface Repository {
  getPairing(pairingId: string): Promise<Pairing | null>;
  listDevices(pairingId: string): Promise<Device[]>;
  getDevice(pairingId: string, deviceId: string): Promise<Device | null>;

  createPairing(input: CreatePairingInput): Promise<CreatePairingResult>;
  claimPairing(input: ClaimPairingInput): Promise<ClaimPairingResult>;

  /** Hard-deletes the pairing and, by cascade, all of its devices. */
  deletePairing(pairingId: string): Promise<boolean>;
  /** Hard-deletes a single device belonging to the pairing. */
  deleteDevice(pairingId: string, deviceId: string): Promise<boolean>;
  /** Deletes every device registered with this APNs token (APNs 410 cleanup). */
  deleteDevicesByApnsToken(apnsToken: string): Promise<number>;

  updateDeviceToken(input: UpdateDeviceTokenInput): Promise<Device | null>;
  touchDevice(deviceId: string, now: Date): Promise<void>;

  /** Daily hard-delete job: revoked pairings and unclaimed expired ones. */
  purge(expiredBefore: Date): Promise<PurgeResult>;

  close(): Promise<void>;
}
