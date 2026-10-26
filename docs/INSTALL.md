# Installing SecretSkyDB (PostgreSQL / AlloyDB)

SecretSkyDB is a drop-in PostgreSQL proxy. Your application connects to it exactly
like a normal Postgres server, but every value is split into **sub-threshold secret
shares** across **three AlloyDB instances in three Google Cloud regions**. Plaintext
only ever exists inside the proxy pod, inside your trust boundary — any 2 of 3 shares
reconstruct; any single share reveals nothing.

There are two deployment paths:

| Path | For | Billing |
|---|---|---|
| **A. Scripted install** (this guide) | Direct / private-offer / air-gapped-ish deployments | By contract (metering off) |
| **B. Marketplace 1-click** | Self-serve, usage-metered buyers | Auto-metered (`proxy_time`) |

Both paths offer two homes for the three share stores:

- **In this cluster (quick start, the default of the Marketplace form and `SHARES=incluster`).**
  The chart runs three PostgreSQL share stores in the cluster, each on its own persistent
  volume, with generated passwords. Nothing to prepare, ready in a few minutes. All three
  custodians then share one cluster and one administrator: the "no single party holds
  recoverable data" property holds against a compromised node or disk, not against the
  cluster admin.
- **AlloyDB (three regions recommended).** The custodians are separate managed instances
  you own; `scripts/prepare-shares.sh` (or the Terraform in `terraform/`) creates them and
  the shares Secret. This is the production topology.

---

## Prerequisites (both paths)

- A **GKE cluster** (Standard or Autopilot) in your project, and `kubectl` pointed at it:
  `gcloud container clusters get-credentials <cluster> --region <region>`
- A **VPC with Private Services Access (PSA)** — AlloyDB peers over it. If your VPC
  doesn't have PSA yet, the script can create it (`MANAGE_PSA=true`).
- CLI tools: `gcloud`, `kubectl`, `terraform`, `helm`.
- IAM: rights to create AlloyDB, enable APIs, and manage the cluster namespace.
- An **encrypted-at-rest StorageClass** for the proxy's on-prem cache (recommended —
  the cache holds plaintext at rest inside your boundary).
- **Marketplace path only — service-account keys must be allowed in the project.**
  The Marketplace deployer creates a key for the usage-reporting service account.
  Organizations created since 2024 enforce `iam.disableServiceAccountKeyCreation`
  by default, and Deploy then fails with *"Key creation is not allowed on this
  service account"*. Override it for the deployment project (an Organization
  Policy Administrator runs this):
  ```sh
  cat > /tmp/sa-key-policy.yaml <<EOF
  name: projects/<project-id>/policies/iam.disableServiceAccountKeyCreation
  spec:
    rules:
    - enforce: false
  EOF
  gcloud org-policies set-policy /tmp/sa-key-policy.yaml
  ```
  then reload the Deploy page. The scripted install (Path A) does not need this.
- **Terraform from a laptop:** the Google provider needs credentials
  (`gcloud auth application-default login`, or `GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`)
  and the Kubernetes provider needs `KUBE_CONFIG_PATH=$HOME/.kube/config` so it can
  write the shares Secret into the cluster.

---

## Path A — scripted install

One command provisions the shares (Terraform) and installs the app (Helm):

```sh
./scripts/install-secretskydb.sh
```

With no variables it uses the gcloud project, its `default` VPC, and adds Private
Services Access (PSA) to that VPC when missing. To choose otherwise:

```sh
export PROJECT_ID=my-project
export NETWORK=projects/my-project/global/networks/my-vpc   # another VPC
export SHARE_REGIONS=europe-west1,europe-west4,europe-west9  # where the three shares live
export CACHE_STORAGECLASS=<your-encrypted-at-rest-class>     # else cluster default
export MANAGE_PSA=true                                       # force PSA creation (default: detected)
./scripts/install-secretskydb.sh
```

What it does: enables APIs → creates the namespace → `terraform apply` (3 AlloyDB
instances + the `secretskydb-alloydb-shares` Secret) → `helm install` (proxy + cache +
bootstrap Job) → waits for readiness → prints connection details.

> AlloyDB provisioning takes ~10–15 minutes. The clusters are billable.

### Connect your application
Point your app at the proxy Service as a normal PostgreSQL server:

- **Host:** `secretskydb.<namespace>.svc.cluster.local` (in-cluster)
- **Port:** `55432`
- **Database:** `ssdb`  **User:** `ssdb`
- **Password:** the `proxy` key of Secret `secretskydb-alloydb-shares`

```sh
kubectl -n secretskydb get secret secretskydb-alloydb-shares -o jsonpath='{.data.proxy}' | base64 -d
```

For access from outside the cluster, expose the Service via an internal LoadBalancer
or PSC — do **not** put the proxy on the public internet.

### Uninstall
```sh
./scripts/uninstall-secretskydb.sh      # same PROJECT_ID / NETWORK as the install, if you set them
```
⚠️ This runs `terraform destroy` — it deletes the AlloyDB shares and **all data**. Back up first.

The AlloyDB clusters are created with deletion protection, so a plain
`terraform destroy` removes the instances and then stops with *"cannot destroy
cluster without setting deletion_protection=false"*. To finish: delete the three
(now empty) clusters with `gcloud alloydb clusters delete <name> --region <region>
--force`, drop them from the Terraform state (`terraform state rm
'google_alloydb_cluster.share["<region>"]'`) and run `terraform destroy` again to
remove the Private Services Access peering and range.

---

## Path B — Marketplace 1-click (usage-metered)

1. In the GCP console → **Marketplace → SecretSkyDB → Configure**: pick the cluster and
   namespace. Leave **Create the three share stores inside this cluster** checked for the
   quick start, click **Deploy**, and the application is ready in a few minutes. The
   Marketplace deployer installs the app **and wires usage metering** (the `proxy_time`
   metric → your bill).
2. For AlloyDB shares instead: run `./scripts/prepare-shares.sh` first (it creates the three
   instances and the Secret `secretskydb-alloydb-shares` in the target namespace), then
   uncheck the box in the form and enter that Secret name.
3. The application page shows the connection string and a link to the password of user
   `ssdb` (the `proxy` key of the shares Secret). Connect your application as above.

---

## How it works (what got installed)

- **proxy** — the reassembly engine; serves the PG wire protocol on `55432`, splits
  writes into shares and reconstructs on read.
- **cache** — an in-pod Postgres (wal2json) on a **persistent** volume; the proxy acks a
  write once it commits to the cache, then fans out to the shares asynchronously, so the
  cache is the durability record for acked-but-unpropagated writes. Plaintext lives at
  rest here — use an encrypted-at-rest StorageClass.
- **bootstrap Job** — installs the pure-SQL `ssdb_ff_inner_product` UDF + RAG schema on
  each AlloyDB share (AlloyDB is managed Postgres, so no C extension).
- **3 AlloyDB shares** — one sub-threshold share per region; only shares ever leave the pod.

## Shared responsibility

SecretSkyDB's guarantees split cleanly between what mathematics enforces and what
operations must uphold:

- **Confidentiality is guaranteed by mathematics.** Every value is Shamir-split
  (k-of-n) across the shares; no share provider — nor any coalition below k —
  can read your data, regardless of anyone's operational discipline.
- **Share-store write-exclusivity is YOUR responsibility.** The pipeline assumes
  SSDB tables on the shares are modified **only** by the proxy via the replication
  stream (the one sanctioned exception is the bootstrap Job, which runs before
  streaming starts). Do not grant other principals write access to the share
  databases' SSDB tables; out-of-band writes there cause replication failures
  that surface as `[poll][dead-letter]` / `[poll][hold]` alerts — quarantined
  transactions are never applied silently.
- **Cache storage durability is a deployment property.** Writes are acknowledged
  at the in-pod cache and fan out asynchronously; until a write reaches the
  shares, the cache volume is its only copy. **RPO on cache-storage loss equals
  the fan-out lag**, which the proxy alerts on (`[poll][backlog]`, thresholds
  `SSDB_FANOUT_BACKLOG_ALERT_MB` / `SSDB_FANOUT_BACKLOG_CEILING_MB`). For
  production use an encrypted, durable (preferably regionally replicated)
  StorageClass for the cache PVC. A cache that comes back empty or rewound is
  detected at startup (`[poll][identity]`) and the proxy **refuses to stream**
  until an operator resolves it (`SSDB_FANOUT_IDENTITY_CHECK=0` overrides,
  accepting the gap).
- **Table identity is proxy-owned.** `"_id"` is a reserved UUID column the proxy
  manages; CREATE TABLE without it gets it added automatically, and a conflicting
  client declaration (e.g. `_id INT`) is rejected
  (`SSDB_CREATE_ID_POLICY=augment|reject|off`).

Fan-out containment knobs (defaults are safe; unknown errors always retry):
`SSDB_FANOUT_QUARANTINE` (kill-switch), `SSDB_FANOUT_QUARANTINE_N`/`_T`
(confirmation gate), `SSDB_FANOUT_DDL_BARRIER`, `SSDB_FANOUT_FRAME_CREATE`,
`SSDB_WAL_GET_BATCH_MAX`. Quarantined transactions are recorded in
`_ssdb.ssdb_dead_letter` on the cache for operator replay after the cause is
fixed.

## Licence

Use of the Software is governed by the SecretSkyDB End User License Agreement
(<https://www.secretskydb.com/eula>, copy in `docs/legal/EULA.md`). The third-party and
open-source components in the images, with their licences, are listed in
`docs/legal/THIRD_PARTY_NOTICES.md`.

**On Google Cloud Marketplace no licence token is needed (0.3).** Your Marketplace
subscription is the licence and usage is metered hourly; the deployer passes the entitlement
to the proxy, which reports `license.state: licensed` with reason *Google Cloud Marketplace
entitlement*. The **Licence key** field of the deploy form is optional and only for customers
who hold a SecretSkyDB token (its claims are then shown in `/statusz`).

**Outside the Marketplace** (public chart, on-prem) SecretSkyDB serves only with a licence
issued by SecretSkyDB Ltd. to the Google Cloud project it runs in. A licence is a short signed
token (`SSDB1.…`); it is bound to your project's **number** (not its ID) and carries an expiry
date.

- **Getting one:** request it at <https://secretskydb.com/license> (company, contact,
  project number, intended use); evaluations receive a time-limited token.
- **Installing it:** set `license.key` in the Helm values (`--set-file license.key=token.txt`).
  It is stored in the Secret `<release>-license` and read by the proxy as `SSDB_LICENSE`.
  Replacing the Secret and restarting the proxy pod applies a new token; the proxy also
  re-reads its licence every hour.
- **Without one:** the deployment runs a **14-day evaluation** from its first start (the
  clock is kept in the cache, so restarts do not reset it). After that, and after a
  licence's expiry plus **7 days of grace**, the proxy refuses every client connection
  with `SecretSkyDB is not licensed: …` and meters no usage; the cache and the shares are
  untouched and resume serving as soon as a valid token is installed.
- **Checking:** `/statusz` on the proxy's health port reports `license` (state, customer,
  expiry, days left); the proxy log carries `[license] …` lines at start and on every
  change of state.

## Transport security and authentication

- **TLS to the proxy** (`tls.enabled`, `tls.secretName`, `tls.require`): a
  `kubernetes.io/tls` Secret (cert-manager or `kubectl create secret tls`) is mounted into
  the proxy; with `tls.require: true` a client that does not negotiate TLS is refused before
  any password is exchanged. TLS 1.2 (AEAD suites only) and TLS 1.3. Clients connect with
  `sslmode=require` (or `verify-full` with a CA-signed certificate).
- **Authentication** (`proxy.authMethod`): SCRAM-SHA-256 by default; `md5` for drivers
  that cannot do SCRAM (plaintext-password users only). The deploy-form user (`proxyUser`,
  password in the shares Secret's `proxy` key) is an **admin**; add further users under
  `users.list` (0.3) — see *Users, roles and audit* below.
- **Share links** use TLS to AlloyDB (`sharesSslmode`). Key exchange is classical (X25519 /
  ECDHE) in 0.2 and 0.3.0; hybrid post-quantum key exchange (X25519 + ML-KEM, OpenSSL 3.5)
  follows in the next image.
- **Exposure** (`service.type`, `service.loadBalancerIP`, `service.loadBalancerSourceRanges`):
  the Service is ClusterIP by default. If you expose it with a LoadBalancer, always set
  `loadBalancerSourceRanges`; never publish the proxy to `0.0.0.0/0`.
- **Sizing knobs:** `proxy.servingProcesses` (serving processes behind one port),
  `proxy.mirrorWorkers` (parallel share writers), and `cache.tuning.*`
  (`shared_buffers`, `max_wal_size`, `checkpoint_timeout`, `wal_compression`) — the defaults
  suit the chart's default resource limits; raise them together with the limits.

## Users, roles and audit (0.3)

**Users.** Each proxy user is a record with a name, a role, an optional reconstruction policy
and a SCRAM-SHA-256 *verifier* (PostgreSQL's format) — the proxy never stores a password.
Make records with the tool from the SecretSkyDB repository and paste them into the chart:

```bash
python3 tools/ssdb_user.py add users.json app     --role writer
python3 tools/ssdb_user.py add users.json analyst --role reader --reconstruct aggregate
python3 tools/ssdb_user.py list users.json
```

```yaml
users:
  list:
    - { name: app,     role: writer, scram: "SCRAM-SHA-256$4096:…$…:…" }
    - { name: analyst, role: reader, reconstruct: aggregate, scram: "SCRAM-SHA-256$4096:…$…:…" }
```

The chart renders `users.list` into the Secret `<release>-users` (key `users.json`); or point
`users.existingSecret` at a Secret you manage. The deploy-form user stays an admin.

**Roles** (each includes the previous):

| Role | May run |
|---|---|
| `reader` | SELECT, SHOW, EXPLAIN, transaction control, session settings |
| `writer` | + INSERT, UPDATE, DELETE, MERGE, COPY, SELECT … FOR UPDATE |
| `admin` | + DDL, `COMMENT ON COLUMN` (policies), TRUNCATE, GRANT/REVOKE, VACUUM, CALL, DO |

A statement outside the role is refused with SQLSTATE `42501`; a multi-statement batch needs
the highest role of its statements.

**Reconstruction policy** (`reconstruct`, per user) — what the user may learn about *Secret*
columns:

| Value | Effect |
|---|---|
| `all` (default) | may read Secret values |
| `aggregate` | Secret columns only inside `SUM`, `COUNT`, `AVG` — computed on the shares, the aggregate reconstructed, never a row; `MIN/MAX`, vector search and Secret columns in `WHERE`/`ORDER BY` are refused |
| `none` | may not read Secret columns at all (open and cacheable columns, `COUNT(*)`, and writes are fine) |

This is enforced before any route is chosen, including the cache-first profile where the cache
holds plaintext.

**Audit** (`audit.mode`, `audit.sql`). One JSON line per statement on the proxy's stdout, which
Cloud Logging collects (`resource.type="k8s_container"`, container `proxy`, text starting with
`{"ts"`): `ts, user, role, client, db, kind, path, tables, secret` (Secret columns the statement
reconstructed), `rows, ms, ok, error, sql_sha256` and, with `audit.sql: text`, the statement.
`audit.mode: statements` (default) records every statement that reaches the proxy's handlers;
`full` additionally disables the compiled relay's shape forwarding for admin sessions so that no
statement can bypass the record (restricted roles are always fully recorded). `off` disables it.
Retention is the log bucket's (set it to the period your policy requires).

**No users at all.** The proxy refuses to start without a user table (the chart always has the
deploy-form user). `SSDB_ALLOW_NO_AUTH=1` serves unauthenticated — for test rigs only.

## Troubleshooting

- **`SecretSkyDB is not licensed`** on connect → see *Licence*: install or renew the token
  (`kubectl -n <ns> get secret <release>-license`), then restart the proxy pod or wait for the
  hourly re-check. `/statusz` shows why (expired, wrong project, evaluation ended).
- **`SSL connection is required`** → the client connected without TLS while `tls.require`
  is on: use `sslmode=require`.
- **`[poll][identity] … REFUSING to stream over an unexplained gap`** at start-up, writes
  succeed but reads from the shares come back empty → the shares remember a *different* cache
  (`_ssdb.ssdb_apply_state` on each share records the cache's system id and the last applied
  WAL position) and the proxy will not fan out over a gap it cannot explain: the cache volume
  was replaced or restored from an older backup, or — the common case — a **fresh deployment
  was pointed at shares that an earlier deployment already used**. Resolve it deliberately:
  - *The shares are stale and the new cache is the source of truth* (new deployment, test
    shares, migration): on **every** share run `DELETE FROM _ssdb.ssdb_apply_state;` and drop
    or truncate the tables that are to be re-mirrored, then restart the proxy pod
    (`kubectl -n <ns> rollout restart statefulset <release>`). The proxy starts a new slot
    and mirrors from there.
  - *The shares are the source of truth and the cache is empty* (cache disk lost): keep the
    shares, give the proxy an empty cache and let it rebuild from the shares on the next
    `CREATE TABLE … ` of each table (recovery backfill); then clear the apply state as above.
  - *You know the gap is harmless* (nothing was written in the window): set
    `SSDB_FANOUT_IDENTITY_CHECK=0` on the proxy (`proxy.env` in the values) for one start.
  A `ssdb-resync` tool that performs the first two cases ships in 0.3.1.

- **AlloyDB apply fails / hangs on peering** → the VPC lacks PSA. Re-run with `MANAGE_PSA=true`.
- **Secret not found after Terraform** → `kubectl` isn't pointed at the target cluster, or
  the namespace didn't exist (the script creates it before Terraform).
- **Proxy not Ready** → `kubectl -n <ns> logs secretskydb-0 -c proxy` — usually a share it
  can't reach (check AlloyDB private IP / firewall on the VPC).
