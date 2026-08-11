-- Protocol revision 1.1: per-device authentication keys.
--
-- Under 1.0 every device in a pairing signed with the pairing-wide `k_auth`,
-- so the caller's role had to be taken from the request and any viewer could
-- assert `camera`. From 1.1 each device generates a random 32-byte key, uploads
-- it in its bootstrap-authenticated request body, and signs every later request
-- with it; the server reads the role from the row this key belongs to.
--
-- Device rows created under 1.0 carry no such key and therefore cannot
-- authenticate anything after this migration — their owners must re-pair. They
-- are deleted rather than back-filled with a placeholder, because a placeholder
-- key would be a credential nobody chose. This is a pre-release schema with no
-- deployed data; the cascade also removes the associated APNs tokens, which is
-- the same data-minimising outcome as a revocation.

delete from pairings;

alter table devices
  add column device_key bytea not null;

-- Exactly 32 bytes: the HMAC key size pinned in shared/protocol.md.
alter table devices
  add constraint devices_device_key_length check (octet_length(device_key) = 32);
