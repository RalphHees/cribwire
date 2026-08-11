# cribwire-backend

Helm chart for the CribWire signaling and pairing API — the service behind
<https://apicribwire.ralphhees.nl>.

The chart deploys the stateless API, a Valkey instance for the state the API
cannot keep per-process, and a migration hook. Postgres is **not** part of the
chart: it holds pairing and device rows that must outlive any `helm uninstall`.

```
Ingress (nginx + cert-manager)
  └── Service :8080 ─── Deployment  cribwire-backend        (2+ replicas)
                             │
                             ├── Valkey  :6379              (1 replica, in-memory)
                             └── Postgres                   (external)

  Job cribwire-backend-migrate   pre-install / pre-upgrade hook
```

## What goes where

| Value                     | Lives in         | Why                                                               |
| ------------------------- | ---------------- | ----------------------------------------------------------------- |
| `DATABASE_URL`            | Secret           | Embeds credentials                                                 |
| `TURN_SHARED_SECRET`      | Secret           | coturn `use-auth-secret` key                                       |
| `APNS_KEY_P8` / `KEY_ID` / `TEAM_ID` | Secret | Apple provider token                                             |
| `TURN_URIS`, `APNS_TOPIC` | ConfigMap        | Public configuration                                               |
| `REDIS_URL`               | ConfigMap        | Only for the in-cluster, password-free Valkey                      |
| Rate limits, timeouts     | ConfigMap        | Tunable without a rebuild                                          |

The pod loads both with `envFrom`, ConfigMap first and Secret second, so a key
present in both resolves to the Secret. That is what lets an external Redis
supply `REDIS_URL` through the Secret when the URL carries a password.

## Install

Create the credentials Secret first — the chart refuses to render without one
rather than installing pods that crash-loop on a missing `DATABASE_URL`:

```bash
kubectl create namespace cribwire

kubectl -n cribwire create secret generic cribwire-backend \
  --from-literal=DATABASE_URL='postgres://cribwire:…@db.internal:5432/cribwire' \
  --from-literal=TURN_SHARED_SECRET='…' \
  --from-literal=APNS_KEY_ID='…' \
  --from-literal=APNS_TEAM_ID='…' \
  --from-file=APNS_KEY_P8=AuthKey_XXXXXXXXXX.p8
```

…and the Harbor pull credential, since the project is private:

```bash
kubectl -n cribwire create secret docker-registry harbor-cribwire \
  --docker-server=harbor.aviodata.net \
  --docker-username='robot$cribwire+ci' \
  --docker-password='…'
```

Then roll out, pinned to the digest the publish workflow printed:

```bash
helm upgrade --install cribwire-backend deploy/helm/cribwire-backend \
  --namespace cribwire \
  -f deploy/helm/values-production.yaml \
  --set image.digest=sha256:… \
  --set revision="$(git rev-parse HEAD)" \
  --wait --timeout 10m

helm test cribwire-backend -n cribwire
curl -fsS https://apicribwire.ralphhees.nl/v1/version
```

`values-production.yaml` is the overlay for `apicribwire.ralphhees.nl`; it sets
the host, the cert-manager issuer, autoscaling and the APNs topic.

The chart is also published to Harbor as an OCI artifact, so a cluster that
does not have the repository checked out can install it directly:

```bash
helm upgrade --install cribwire-backend \
  oci://harbor.aviodata.net/ralphhees/cribwire-backend --version 0.1.0_<sha> …
```

## Decisions worth knowing

**Pin by digest, not tag.** `image.tag` exists for convenience, but a tag can be
repointed in the registry after the fact, so a rollback is not guaranteed to
land on the same bytes. `helm install` prints a warning when no digest is set.

**Migrations run as a pre-upgrade hook**, not an init container, so a failed
migration fails the release before any new pod takes traffic. The runner is
forward-only and takes a Postgres advisory lock, so two deploys racing is safe.
The Job is kept until the next deploy replaces it — its logs are the only
record of what failed.

Because hooks run before ordinary resources exist, the bootstrap paths
(`secret.create`, `imagePullSecrets.create`) annotate their Secrets as hooks
too. Hook resources are not tracked in the release, so those Secrets survive a
`helm uninstall`. Pointing at Secrets you manage yourself avoids this entirely,
which is the recommended setup.

**Valkey is single-replica and has no persistence.** It holds the HMAC
replay-nonce cache, the token-bucket rate limits and the pub/sub bus that
routes signaling frames between API pods. Nonces expire inside the 60 s auth
window, buckets refill, and the bus carries no backlog, so none of it is worth
an fsync. `maxmemory-policy` is `noeviction`, not an LRU: evicting a nonce
would reopen the replay window the cache exists to close. Under memory pressure
Valkey rejects writes and the API fails closed — 5xx, never unchecked auth.

The deployment strategy is `Recreate` for the same reason: two Valkey pods would
split the nonce cache and the bus between them.

**`/metrics` binds to its own port** (`service.metricsPort`, default 9090), so
the scrape endpoint is never reachable through the Ingress. `serviceMonitor`
refuses to render if the two ports are made equal.

**`/v1/health` answers from the process, not from Postgres.** It is a liveness
signal only, deliberately: a database outage should not restart every pod at
once.

**No CPU limit** on the API container. Throttling a Node event loop holding
thousands of WebSocket connections shows up directly as signaling latency, and
the spec budgets 200 ms P95.

**WebSocket timeouts.** The app pings every 30 s and drops an idle client after
300 s; the Ingress annotations set nginx's read/send timeouts to 3600 s so nginx
never closes a connection the application still considers live.

## Values

See `values.yaml` — every key is commented. The ones you will actually set:

| Key                        | Default                                  | Notes                                    |
| -------------------------- | ---------------------------------------- | ---------------------------------------- |
| `image.digest`             | `""`                                     | Set this on every production deploy       |
| `secret.existingSecret`    | `""`                                     | Required (or `secret.create`)             |
| `imagePullSecrets.existing`| `[]`                                     | Harbor is private                         |
| `ingress.host`             | `apicribwire.ralphhees.nl`               |                                           |
| `config.apns.topic`        | `com.example.cribwire`                   | Must be the real bundle id                |
| `config.turn.uris`         | `""`                                     | Required in production                    |
| `valkey.enabled`           | `true`                                   | `false` → supply `REDIS_URL`              |
| `networkPolicy.enabled`    | `false`                                  | Enable once the CNI enforces policies     |

## Checks

`.github/workflows/helm.yml` lints the chart, renders it in five configurations,
asserts no credential key reaches a ConfigMap, and validates every manifest with
`kubeconform`. Locally:

```bash
helm lint deploy/helm/cribwire-backend --set secret.existingSecret=cribwire-backend
helm template cribwire-backend deploy/helm/cribwire-backend \
  -f deploy/helm/values-production.yaml --set image.digest=sha256:0000…
```
