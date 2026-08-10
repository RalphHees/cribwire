/**
 * Postgres `Repository`. Claim and create run in transactions so the
 * max-viewers and claim-once rules cannot be raced by concurrent requests.
 */

import type pg from 'pg';
import type { Device, Pairing } from '../domain/types.ts';
import type { PgPool } from '../db/pool.ts';
import type {
  ClaimPairingInput,
  ClaimPairingResult,
  CreatePairingInput,
  CreatePairingResult,
  PurgeResult,
  Repository,
  UpdateDeviceTokenInput,
} from './types.ts';

interface PairingRow {
  id: string;
  k_auth: Buffer;
  status: string;
  created_at: Date;
  claimed_at: Date | null;
}

interface DeviceRow {
  id: string;
  pairing_id: string;
  role: string;
  apns_token: string;
  apns_environment: string;
  created_at: Date;
  last_seen_at: Date | null;
}

const UNIQUE_VIOLATION = '23505';

function toPairing(row: PairingRow): Pairing {
  return {
    id: row.id,
    kAuth: row.k_auth,
    status: row.status as Pairing['status'],
    createdAt: row.created_at,
    claimedAt: row.claimed_at,
  };
}

function toDevice(row: DeviceRow): Device {
  return {
    id: row.id,
    pairingId: row.pairing_id,
    role: row.role as Device['role'],
    apnsToken: row.apns_token,
    apnsEnvironment: row.apns_environment as Device['apnsEnvironment'],
    createdAt: row.created_at,
    lastSeenAt: row.last_seen_at,
  };
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { code?: unknown }).code === UNIQUE_VIOLATION
  );
}

const PAIRING_COLUMNS = 'id, k_auth, status, created_at, claimed_at';
const DEVICE_COLUMNS =
  'id, pairing_id, role, apns_token, apns_environment, created_at, last_seen_at';

export class PostgresRepository implements Repository {
  readonly #pool: PgPool;

  constructor(pool: PgPool) {
    this.#pool = pool;
  }

  async getPairing(pairingId: string): Promise<Pairing | null> {
    const result = await this.#pool.query<PairingRow>(
      `select ${PAIRING_COLUMNS} from pairings where id = $1`,
      [pairingId],
    );
    const row = result.rows[0];
    return row === undefined ? null : toPairing(row);
  }

  async listDevices(pairingId: string): Promise<Device[]> {
    const result = await this.#pool.query<DeviceRow>(
      `select ${DEVICE_COLUMNS} from devices
       where pairing_id = $1 order by created_at asc, id asc`,
      [pairingId],
    );
    return result.rows.map(toDevice);
  }

  async getDevice(pairingId: string, deviceId: string): Promise<Device | null> {
    const result = await this.#pool.query<DeviceRow>(
      `select ${DEVICE_COLUMNS} from devices where pairing_id = $1 and id = $2`,
      [pairingId, deviceId],
    );
    const row = result.rows[0];
    return row === undefined ? null : toDevice(row);
  }

  async createPairing(input: CreatePairingInput): Promise<CreatePairingResult> {
    return this.#withTransaction(async (client) => {
      let pairingRow: PairingRow;
      try {
        const inserted = await client.query<PairingRow>(
          `insert into pairings (id, k_auth, status, created_at)
           values ($1, $2, 'pending', $3)
           returning ${PAIRING_COLUMNS}`,
          [input.pairingId, input.kAuth, input.now],
        );
        const row = inserted.rows[0];
        if (row === undefined) return { ok: false, reason: 'conflict' };
        pairingRow = row;
      } catch (error) {
        if (isUniqueViolation(error)) return { ok: false, reason: 'conflict' };
        throw error;
      }

      const device = await client.query<DeviceRow>(
        `insert into devices
           (id, pairing_id, role, apns_token, apns_environment,
            created_at, last_seen_at)
         values ($1, $2, 'camera', $3, $4, $5, $5)
         returning ${DEVICE_COLUMNS}`,
        [
          input.cameraDeviceId,
          input.pairingId,
          input.apnsToken,
          input.apnsEnvironment,
          input.now,
        ],
      );
      const deviceRow = device.rows[0];
      if (deviceRow === undefined) {
        throw new Error('camera device insert returned no row');
      }
      return {
        ok: true,
        pairing: toPairing(pairingRow),
        device: toDevice(deviceRow),
      };
    });
  }

  async claimPairing(input: ClaimPairingInput): Promise<ClaimPairingResult> {
    return this.#withTransaction(async (client) => {
      const selected = await client.query<PairingRow>(
        `select ${PAIRING_COLUMNS} from pairings where id = $1 for update`,
        [input.pairingId],
      );
      const pairingRow = selected.rows[0];
      if (pairingRow === undefined) return { ok: false, reason: 'not_found' };

      const pairing = toPairing(pairingRow);
      if (pairing.status === 'revoked') return { ok: false, reason: 'revoked' };
      if (
        pairing.status === 'pending' &&
        pairing.createdAt.getTime() <= input.expiredBefore.getTime()
      ) {
        return { ok: false, reason: 'expired' };
      }

      const viewers = await client.query<{ count: string }>(
        `select count(*)::text as count from devices
         where pairing_id = $1 and role = 'viewer'`,
        [input.pairingId],
      );
      const viewerCount = Number.parseInt(viewers.rows[0]?.count ?? '0', 10);
      if (viewerCount >= input.maxViewers) {
        return { ok: false, reason: 'too_many_viewers' };
      }

      const device = await client.query<DeviceRow>(
        `insert into devices
           (id, pairing_id, role, apns_token, apns_environment,
            created_at, last_seen_at)
         values ($1, $2, 'viewer', $3, $4, $5, $5)
         returning ${DEVICE_COLUMNS}`,
        [
          input.viewerDeviceId,
          input.pairingId,
          input.apnsToken,
          input.apnsEnvironment,
          input.now,
        ],
      );
      const deviceRow = device.rows[0];
      if (deviceRow === undefined) {
        throw new Error('viewer device insert returned no row');
      }

      const updated = await client.query<PairingRow>(
        `update pairings
         set status = 'active', claimed_at = coalesce(claimed_at, $2)
         where id = $1
         returning ${PAIRING_COLUMNS}`,
        [input.pairingId, input.now],
      );
      const updatedRow = updated.rows[0];
      if (updatedRow === undefined) {
        throw new Error('pairing activation returned no row');
      }

      return {
        ok: true,
        pairing: toPairing(updatedRow),
        device: toDevice(deviceRow),
      };
    });
  }

  async deletePairing(pairingId: string): Promise<boolean> {
    const result = await this.#pool.query(
      'delete from pairings where id = $1',
      [pairingId],
    );
    return (result.rowCount ?? 0) > 0;
  }

  async deleteDevice(pairingId: string, deviceId: string): Promise<boolean> {
    const result = await this.#pool.query(
      'delete from devices where pairing_id = $1 and id = $2',
      [pairingId, deviceId],
    );
    return (result.rowCount ?? 0) > 0;
  }

  async deleteDevicesByApnsToken(apnsToken: string): Promise<number> {
    const result = await this.#pool.query(
      'delete from devices where apns_token = $1',
      [apnsToken],
    );
    return result.rowCount ?? 0;
  }

  async updateDeviceToken(
    input: UpdateDeviceTokenInput,
  ): Promise<Device | null> {
    const result = await this.#pool.query<DeviceRow>(
      `update devices
       set apns_token = $4, apns_environment = $5, last_seen_at = $6
       where pairing_id = $1 and id = $2 and role = $3
       returning ${DEVICE_COLUMNS}`,
      [
        input.pairingId,
        input.deviceId,
        input.role,
        input.apnsToken,
        input.apnsEnvironment,
        input.now,
      ],
    );
    const row = result.rows[0];
    return row === undefined ? null : toDevice(row);
  }

  async touchDevice(deviceId: string, now: Date): Promise<void> {
    await this.#pool.query(
      'update devices set last_seen_at = $2 where id = $1',
      [deviceId, now],
    );
  }

  async purge(expiredBefore: Date): Promise<PurgeResult> {
    const revoked = await this.#pool.query(
      `delete from pairings where status = 'revoked'`,
    );
    const expired = await this.#pool.query(
      `delete from pairings where status = 'pending' and created_at <= $1`,
      [expiredBefore],
    );
    return {
      revokedPairings: revoked.rowCount ?? 0,
      expiredPairings: expired.rowCount ?? 0,
    };
  }

  async close(): Promise<void> {
    await this.#pool.end();
  }

  async #withTransaction<T>(
    fn: (client: pg.PoolClient) => Promise<T>,
  ): Promise<T> {
    const client = await this.#pool.connect();
    try {
      await client.query('begin');
      const result = await fn(client);
      await client.query('commit');
      return result;
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }
}
