/**
 * In-memory `Repository`, used by unit/endpoint tests and by `npm run dev`
 * without a database. Single-process only; it mirrors the Postgres semantics
 * (cascade delete, claim-once, max viewers) but not its durability.
 */

import type { Device, Pairing } from '../domain/types.ts';
import type {
  ClaimPairingInput,
  ClaimPairingResult,
  CreatePairingInput,
  CreatePairingResult,
  PurgeResult,
  Repository,
  UpdateDeviceTokenInput,
} from './types.ts';

export class MemoryRepository implements Repository {
  readonly #pairings = new Map<string, Pairing>();
  readonly #devices = new Map<string, Device>();

  getPairing(pairingId: string): Promise<Pairing | null> {
    return Promise.resolve(this.#pairings.get(pairingId) ?? null);
  }

  listDevices(pairingId: string): Promise<Device[]> {
    const devices = [...this.#devices.values()]
      .filter((device) => device.pairingId === pairingId)
      .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());
    return Promise.resolve(devices);
  }

  getDevice(pairingId: string, deviceId: string): Promise<Device | null> {
    const device = this.#devices.get(deviceId);
    if (device === undefined || device.pairingId !== pairingId) {
      return Promise.resolve(null);
    }
    return Promise.resolve(device);
  }

  createPairing(input: CreatePairingInput): Promise<CreatePairingResult> {
    if (this.#pairings.has(input.pairingId)) {
      return Promise.resolve({ ok: false, reason: 'conflict' });
    }
    const pairing: Pairing = {
      id: input.pairingId,
      kAuth: Buffer.from(input.kAuth),
      status: 'pending',
      createdAt: input.now,
      claimedAt: null,
    };
    const device: Device = {
      id: input.cameraDeviceId,
      pairingId: input.pairingId,
      role: 'camera',
      deviceKey: Buffer.from(input.cameraDeviceKey),
      apnsToken: input.apnsToken,
      apnsEnvironment: input.apnsEnvironment,
      createdAt: input.now,
      lastSeenAt: input.now,
    };
    this.#pairings.set(pairing.id, pairing);
    this.#devices.set(device.id, device);
    return Promise.resolve({ ok: true, pairing, device });
  }

  async claimPairing(input: ClaimPairingInput): Promise<ClaimPairingResult> {
    const pairing = this.#pairings.get(input.pairingId);
    if (pairing === undefined) {
      return { ok: false, reason: 'not_found' };
    }
    if (pairing.status === 'revoked') {
      return { ok: false, reason: 'revoked' };
    }
    if (
      pairing.status === 'pending' &&
      pairing.createdAt.getTime() <= input.expiredBefore.getTime()
    ) {
      return { ok: false, reason: 'expired' };
    }

    const viewers = (await this.listDevices(input.pairingId)).filter(
      (device) => device.role === 'viewer',
    );
    if (viewers.length >= input.maxViewers) {
      return { ok: false, reason: 'too_many_viewers' };
    }

    const device: Device = {
      id: input.viewerDeviceId,
      pairingId: input.pairingId,
      role: 'viewer',
      deviceKey: Buffer.from(input.viewerDeviceKey),
      apnsToken: input.apnsToken,
      apnsEnvironment: input.apnsEnvironment,
      createdAt: input.now,
      lastSeenAt: input.now,
    };
    this.#devices.set(device.id, device);

    const claimed: Pairing = {
      ...pairing,
      status: 'active',
      claimedAt: pairing.claimedAt ?? input.now,
    };
    this.#pairings.set(claimed.id, claimed);
    return { ok: true, pairing: claimed, device };
  }

  deletePairing(pairingId: string): Promise<boolean> {
    const existed = this.#pairings.delete(pairingId);
    for (const [id, device] of this.#devices) {
      if (device.pairingId === pairingId) this.#devices.delete(id);
    }
    return Promise.resolve(existed);
  }

  deleteDevice(pairingId: string, deviceId: string): Promise<boolean> {
    const device = this.#devices.get(deviceId);
    if (device === undefined || device.pairingId !== pairingId) {
      return Promise.resolve(false);
    }
    this.#devices.delete(deviceId);
    return Promise.resolve(true);
  }

  deleteDevicesByApnsToken(apnsToken: string): Promise<number> {
    let deleted = 0;
    for (const [id, device] of this.#devices) {
      if (device.apnsToken === apnsToken) {
        this.#devices.delete(id);
        deleted += 1;
      }
    }
    return Promise.resolve(deleted);
  }

  updateDeviceToken(input: UpdateDeviceTokenInput): Promise<Device | null> {
    const device = this.#devices.get(input.deviceId);
    if (device === undefined || device.pairingId !== input.pairingId) {
      return Promise.resolve(null);
    }
    const updated: Device = {
      ...device,
      apnsToken: input.apnsToken,
      apnsEnvironment: input.apnsEnvironment,
      lastSeenAt: input.now,
    };
    this.#devices.set(updated.id, updated);
    return Promise.resolve(updated);
  }

  touchDevice(deviceId: string, now: Date): Promise<void> {
    const device = this.#devices.get(deviceId);
    if (device !== undefined) {
      this.#devices.set(deviceId, { ...device, lastSeenAt: now });
    }
    return Promise.resolve();
  }

  async purge(expiredBefore: Date): Promise<PurgeResult> {
    let revokedPairings = 0;
    let expiredPairings = 0;
    for (const pairing of [...this.#pairings.values()]) {
      if (pairing.status === 'revoked') {
        await this.deletePairing(pairing.id);
        revokedPairings += 1;
      } else if (
        pairing.status === 'pending' &&
        pairing.createdAt.getTime() <= expiredBefore.getTime()
      ) {
        await this.deletePairing(pairing.id);
        expiredPairings += 1;
      }
    }
    return { revokedPairings, expiredPairings };
  }

  close(): Promise<void> {
    this.#pairings.clear();
    this.#devices.clear();
    return Promise.resolve();
  }
}
