# CribWire — Operations Runbook

On-call reference for the CribWire backend. Written to be read at 3 a.m. by
someone who did not write the code.

**The product context that should shape every decision here**: CribWire is a baby
monitor. An outage does not cost a page view — it means a parent is not watching
their child and, worse, may not know they have stopped watching. Prefer failing
loudly and visibly over degrading quietly.

**What the server cannot do for you**: the backend cannot read any stream, event,
or notification. Every payload it handles is sealed with a key it never sees
(`docs/specs/security.md` §4–5). No amount of server-side debugging will tell you
what a user saw or heard, and no support request can be answered by looking. This
is by design and is not a bug to be worked around.

---

## 1. Service map

| Component | What it does | Failure blast radius |
|---|---|---|
| API (Fastify, `/v1/*`) | Pairing create/claim/revoke, TURN credentials, event fan-out | No new pairings; no new events. **Existing streams keep running.** |
| WebSocket (`/v1/signal`) | Sealed signaling envelope routing, presence | No new connections; no reconnects. Established WebRTC media keeps flowing until ICE fails. |
| Postgres | `pairings`, `devices` | Total: auth resolves no keys, so everything 401s. |
| Redis | Nonce cache (replay defence), rate limits, cross-instance signaling bus | Auth fails closed. Cross-instance routing stops. |
| coturn | TURN relay for peers that cannot connect directly | LAN pairs unaffected. Cross-network pairs cannot connect. |
| APNs | Detection alerts | Silent alerts. Live viewing unaffected. |

**The dependency that surprises people**: Redis holds the nonce cache, and
authentication *fails closed* without it. Redis down is a full outage, not a
degradation. See §4.2.

---

## 2. First five minutes

```bash
curl -fsS https://<host>/v1/health     # {"status":"ok"}
curl -fsS https://<host>/v1/version    # build actually deployed
curl -fsS https://<host>/metrics | head -40
```

Then classify. The single most useful question is **"can existing streams still
run?"**, because that decides whether this is an emergency or a degradation:

- API 5xx but WebSocket healthy → new pairings fail, **live viewing is fine**. Degradation.
- WebSocket down → reconnects fail. Users lose video within ~30 s of any network blip. Emergency.
- Postgres or Redis down → everything 401s. Emergency.
- APNs failing → alerts silent, video fine. Serious: the product's *other* half is dead and users will not notice. Treat as an emergency despite the green dashboard.

---

## 3. Key metrics and what they mean

| Metric | Healthy | Investigate |
|---|---|---|
| `ws_connections_open` | Tracks paired-camera count, diurnal | Cliff = mass disconnect; flat zero = upgrades rejected; a **5-minute sawtooth** means the idle sweep is reaping healthy sockets (see `handlePong`) |
| `ws_upgrade_rejected_total{reason}` | Near zero | `rate_limited` spikes = an IP loop; `auth` spikes = clock skew or a bad deploy |
| `ws_messages_total{outcome}` | `routed` dominant | `seq_regression` / `malformed` = client bug or tampering |
| `apns_send_total{status}` | `sent` dominant | `unregistered` is normal churn; `failed` spikes = cert/key problem |
| `auth_rejected_total{code}` | Low, flat | `timestamp_outside_window` = **clock skew**, see §4.3; `replayed_request` = a client reusing a signing second, see §4.7 |
| `rate_limit_hit_total{bucket}` | Low | Sustained = an abusive client or a limit set too tight |

---

## 4. Incidents

### 4.1 "Nobody can pair" / everything 401s

Almost always Redis or Postgres, not the API.

```bash
redis-cli -u "$REDIS_URL" PING       # expect PONG
psql "$DATABASE_URL" -c 'select 1'
```

Auth resolves device keys from Postgres and nonces from Redis; either being down
produces a blanket 401 with no useful body (deliberately — failures never hint at
whether a pairing exists).

### 4.2 Redis down

Auth fails closed because the nonce cache is what stops replay. **Do not "fix"
this by disabling the nonce check** — that trades an outage for a replayable
authentication scheme.

Restore Redis. The nonce cache is safe to lose: it is a bounded-window cache, and
an empty one is correct-but-forgetful, not insecure, because the timestamp window
(60 s) still bounds replay.

Rate-limit counters and the signaling bus are also in Redis. A cold start
therefore means every client gets a full rate-limit budget at once — expect a
thundering herd of reconnects.

### 4.3 `auth_rejected_total{code="timestamp_outside_window"}` climbing

Clock skew. The HMAC scheme allows 60 s (`AUTH_WINDOW_SECONDS`).

Check the *server's* clock first — one bad server rejects everyone, whereas one
bad phone rejects one user:

```bash
timedatectl status     # or: chronyc tracking
```

Widening the window is a last resort: it directly widens the replay window.

### 4.4 Cross-network calls fail, LAN works

TURN. Check coturn is up, that UDP 3478 and the relay range are open, and that
`TURN_SHARED_SECRET` matches what the API signs with — a mismatch produces
credentials coturn silently refuses.

```bash
curl -fsS -X POST https://<host>/v1/pairings/<id>/turn-credentials  # ...signed
turnutils_uclient -v -u <user> -w <cred> <turn-host>
```

A shared-secret mismatch looks exactly like a network problem from the client
side. Check it before spending time on firewalls.

### 4.5 Alerts stopped, video fine

APNs. Check `apns_send_total{status="failed"}`.

- **`403 InvalidProviderToken`** — the `.p8` JWT is wrong or expired. Provider tokens must be refreshed at least hourly and no more than once every 20 minutes.
- **`400 BadDeviceToken`** — environment mismatch. A sandbox token sent to production is rejected. The app tells the server which environment its token came from; a client built with the wrong `aps-environment` produces exactly this.
- **`410 Unregistered`** — normal. The token is deleted automatically.

**This is the failure mode users do not report**, because the app looks fine.
Alert on it aggressively.

### 4.6 A user says "it says the connection is not private"

That is the DTLS fingerprint check failing (`security.md` §4) — the Viewer refused
to show video because the certificate the handshake produced did not match the one
sealed under the pairing key.

**Do not treat this as a bug to be worked around.** It means either a genuine
man-in-the-middle, or a client/protocol defect. There is no server-side fix and no
setting to relax. Escalate to engineering with the app version and rough time;
the server logs will show the pairing id and nothing else, which is the intended
amount.

### 4.7 `auth_rejected_total{code="replayed_request"}` climbing

A client signing two requests in the same wall-clock second. The `CribWire-HMAC`
MAC covers method, path, timestamp, principal and body hash — and for the
signalling upgrade every one of those is constant except the timestamp, which has
one-second granularity. Two upgrades in one second are byte-identical, so the
second is refused, and the replay entry lives for twice the auth window (120 s).

The app avoids this with `RequestTimestampSequencer`, which never offers the same
second twice. A spike therefore means either an old client build or something
retrying far harder than the backoff ladder should allow. It is **not** an attack
signature on its own.

---

## 5. Deploys and rollback

The API is stateless. Rolling restarts drop WebSocket connections; clients
reconnect on the backoff ladder in `ReconnectPolicy` (1 s → 30 s), so a rolling
deploy produces a reconnect storm proportional to connected cameras. Deploy in the
local small hours where possible — for a baby monitor that is the *worst* time for
an outage but the best time for a brief reconnect.

```bash
# Roll back to the previous image
docker service update --rollback cribwire-api      # or the platform equivalent
curl -fsS https://<host>/v1/version                 # confirm
```

Migrations are forward-only. Check `backend/migrations/` before rolling back a
release that added one — rolling the *image* back while the schema moved forward
is safe only if the migration was additive.

---

## 6. Alerts worth paging for

| Condition | Why |
|---|---|
| `/v1/health` failing 2 min | Total outage |
| Redis or Postgres unreachable | Fails closed → total outage |
| `apns_send_total{status="failed"}` > 10 % for 10 min | Silent alert failure; users will not notice |
| `ws_connections_open` drops > 50 % in 5 min | Mass disconnect |
| `auth_rejected_total{code="timestamp_outside_window"}` > 1 % | Clock skew building |
| TLS certificate expiring < 14 days | Ordinary renewal; see below |

### Certificates are an ordinary ops task

The app does **not** pin certificates (`docs/specs/security.md` §7 records why).
Renewals, intermediate rotations and CA changes are all server-side operations
that need no app release and cannot brick installed apps.

Keep the expiry alert anyway: an expired certificate still takes the whole service
down, it just does so recoverably. Confirm ACME renewal is running rather than
waiting for the alert.

Note that TLS is not what protects the streams. Media is end-to-end encrypted and
event payloads are sealed with keys the server never holds, so a TLS failure is an
availability incident, not a confidentiality one.

---

## 7. Data and privacy

- The server stores pairing rows, device rows and APNs tokens. No media, no event contents, no key that opens anything.
- Revoked and expired rows are hard-deleted by the daily purge job (`src/jobs/purge.ts`).
- `blob` and `ciphertext` fields are never logged, decoded or inspected. If you find yourself wanting to log one to debug something, the answer is no — it would not help (you have no key) and it would break the guarantee the product is sold on.
