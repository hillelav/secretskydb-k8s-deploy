# Installing SecretSkyDB on your own Kubernetes cluster

SecretSkyDB does not have to run on GKE. The same Helm chart installs on any Kubernetes
cluster, on-premises or in another cloud, and the deployment is still bought, metered and
billed through Google Cloud Marketplace: this is the **"Deploy via command line"** path of the
product page. A private offer you accepted applies to it exactly as it does on GKE.

```
your cluster (anywhere)                                     Google Cloud
┌─────────────────────────────────────────────┐             ┌──────────────────────────────┐
│ proxy pod ── cache ── share-a share-b share-c│  HTTPS out  │ marketplace.gcr.io  (images)  │
│   └ metering agent ─────────────────────────┼────────────▶│ Service Control     (usage)   │
└─────────────────────────────────────────────┘             │ → your GCP invoice / offer    │
         ▲ PostgreSQL wire protocol :55432                   └──────────────────────────────┘
      your applications
```

What stays in Google Cloud: the images you pull and one usage number per hour. Your data,
the shares and the proxy never leave your cluster.

## Prerequisites

- A Kubernetes cluster, version 1.27 or later, with `kubectl` pointed at it and `helm` 3 on
  your PATH. Three nodes let the three share stores land on different nodes (preferred, not
  required). A default or named StorageClass; prefer one that encrypts at rest.
- Outbound HTTPS from the nodes to `marketplace.gcr.io` and `*.googleapis.com`.
- A Google Cloud project linked to the billing account that holds your Marketplace order (or
  that accepted your private offer). Nothing runs in it; it only issues the reporting key.
  Service-account key creation must be allowed in that project (see
  [INSTALL.md](INSTALL.md), prerequisites, for the organisation policy override).
- A fully disconnected site cannot report usage. Use the licence-token path instead
  ([INSTALL.md](INSTALL.md), "Licence"), with images mirrored into your own registry.

## Install

1. **Download the reporting key.** Open the product page, click **Configure**, then the
   **Deploy via command line** tab. Under *Reporting service account* keep *Create new
   service account* and click **Download service account key**. Save the file; it is a
   Kubernetes Secret manifest (`service-account-key.yaml`) holding the key that identifies
   your order when usage is reported.

2. **Clone this repository** on a machine with `kubectl` access to your cluster:
   ```sh
   git clone https://github.com/hillelav/secretskydb-k8s-deploy.git && cd secretskydb-k8s-deploy
   ```

3. **Install:**
   ```sh
   KEY_FILE=~/Downloads/service-account-key.yaml ./scripts/install-onprem.sh
   ```
   The script creates the namespace, applies the reporting Secret, builds an image-pull Secret
   from the same key, and runs `helm install` with
   [`chart/secretskydb/values-onprem.yaml`](../chart/secretskydb/values-onprem.yaml): the
   three share stores as PostgreSQL StatefulSets in your cluster, metering on, and no
   GKE-only resources. Options such as `NAMESPACE`, `STORAGECLASS` or `PROFILE=cache-first`
   are listed at the top of the script. About three minutes.

4. **Connect.** The proxy is a ClusterIP Service on port 55432:
   ```sh
   kubectl -n secretskydb port-forward svc/secretskydb 55432:55432
   PGPASSWORD="$(kubectl -n secretskydb get secret secretskydb-shares -o jsonpath='{.data.proxy}' | base64 -d)" \
     psql -h 127.0.0.1 -p 55432 -U ssdb -d ssdb
   ```
   Your applications connect the same way as to any PostgreSQL server. To reach the proxy
   from outside the cluster set `service.type: LoadBalancer` with `tls.enabled: true` and a
   source allow-list, as described in [INSTALL.md](INSTALL.md).

5. **Verify the licence and metering.**
   ```sh
   kubectl -n secretskydb port-forward pod/secretskydb-0 55433:55433 &
   curl -s http://127.0.0.1:55433/statusz
   ```
   `license.state` reads `licensed` with the reason *Google Cloud Marketplace entitlement*.
   Usage appears on the Google Cloud invoice of the billing account within a day, at the rate
   of your order or private offer. Google bills nothing for the cluster itself: it is yours.

## Without a Marketplace order

Run the script without `KEY_FILE`. You then need an image-pull Secret (ask
support@secretskydb.com for a pull credential, or mirror the images into your own registry
and point `values-onprem.yaml` at it) and either a licence token (`LICENSE_KEY_FILE=`) or the
built-in 14-day evaluation, after which the proxy stops accepting connections.

## Separated custodians

`values-onprem.yaml` keeps the three shares in the cluster, which protects against a lost
node or disk but not against the cluster administrator. For separation, run the three share
stores as PostgreSQL servers in three places you control (two sites and a cloud, for example),
put their addresses and credentials in the Secret described under "Share stores" in
[INSTALL.md](INSTALL.md), and install with `inclusterShares.enabled=false`.

## Upgrade and removal

Re-run the install command with a new `TAG`; the release is upgraded in place and the data is
kept. To remove: `helm -n secretskydb uninstall secretskydb`, then delete the volumes if you
want the data gone: `kubectl -n secretskydb delete pvc --all`.
