# Deploying SecretSkyDB from the command line

SecretSkyDB is a wire-compatible PostgreSQL proxy that stores every sensitive
value as 2-of-3 secret shares across separate AlloyDB instances — no single
server ever holds recoverable data. This repository contains the **command-line
deployment instructions** for the SecretSkyDB Kubernetes application on
Google Cloud Marketplace. (The application images are distributed through
Google Cloud Marketplace; this repo carries deployment assets only.)

- Product page: Google Cloud Marketplace → *SecretSkyDB*
- Support: support@secretskydb.com · Docs: see the product's Documentation tab

## Prerequisites

- A GKE cluster (Standard or Autopilot), Kubernetes ≥ 1.27, and `kubectl`
  pointed at it:
  ```sh
  gcloud container clusters get-credentials CLUSTER --region REGION
  ```
- The Kubernetes **Application** resource definition (one-time per cluster):
  ```sh
  kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"
  ```
- Three AlloyDB (or PostgreSQL) share instances reachable from the cluster,
  and a Kubernetes Secret holding their hosts and credentials (keys:
  `proxy`, `cache`, `share-a`, `share-b`, `share-c`, `share-a-host`,
  `share-b-host`, `share-c-host`). The product documentation includes a
  Terraform module that provisions AlloyDB across three regions and writes
  this Secret for you.
- `mpdev`, Google's Marketplace dev tool:
  ```sh
  BIN=/usr/local/bin/mpdev
  docker run --rm --entrypoint=cat gcr.io/cloud-marketplace-tools/k8s/dev /scripts/dev > /tmp/mpdev \
    && chmod +x /tmp/mpdev && sudo mv /tmp/mpdev "$BIN"
  ```

## Install

```sh
NAMESPACE=secretskydb
kubectl create namespace "$NAMESPACE"

mpdev install \
  --deployer=us-docker.pkg.dev/secretskydb-public/secretskydb-private-legacy/deployer:0.2 \
  --parameters='{
    "name": "secretskydb",
    "namespace": "'$NAMESPACE'",
    "alloydbShareSecret": "secretskydb-alloydb-shares",
    "reportingSecret": "REPORTING_SECRET_NAME",
    "license.key": "SSDB1...."
  }'
```

`reportingSecret` is the usage-reporting Secret that Google Cloud Marketplace
creates for your deployment (Marketplace → your order → credentials); it lets
the bundled metering agent report `proxy_time` usage for billing.

`license.key` is your SecretSkyDB licence token (release 0.2 and later). It is
bound to your Google Cloud project *number* and carries an expiry; request one
at <https://secretskydb.com/license>. The field may be left out: the deployment
then runs a **14-day evaluation** from its first start, after which the proxy
refuses client connections until a licence is installed (the cache and the
shares are untouched). To install or renew a licence on a running deployment,
replace the Secret `secretskydb-license` (key `token`) and restart the proxy
pod; the proxy also re-reads its licence every hour. `/statusz` on the proxy's
health port (55433) reports the licence state.

## Verify

```sh
kubectl get application/secretskydb -n "$NAMESPACE"   # status: Healthy
kubectl get pods -n "$NAMESPACE"                       # proxy StatefulSet Ready
```

Connect exactly as to PostgreSQL (no driver changes):

```sh
kubectl port-forward -n "$NAMESPACE" svc/secretskydb 55432:55432 &
psql "host=127.0.0.1 port=55432 user=YOUR_USER dbname=ssdb"
```

Column protection tiers are declared in the table schema; see the product
documentation for the `Secret` / `Cacheable` / `Open` column model, sizing
presets, and the encrypted-at-rest StorageClass recommendation for the cache
volume.

### Transport security (release 0.2 and later)

The proxy serves plaintext PostgreSQL inside the cluster by default. To expose
it beyond the cluster, give it a TLS certificate and require it: create a TLS
Secret (`kubectl create secret tls secretskydb-proxy-tls --cert=… --key=…`) and
set the Helm values `tls.enabled=true`, `tls.secretName=secretskydb-proxy-tls`,
`tls.require=true`; clients then connect with `sslmode=require` (or
`verify-full` with a CA-signed certificate). Client authentication is
SCRAM-SHA-256 (`proxy.authMethod`). A `LoadBalancer` Service takes a source
allow-list (`service.loadBalancerSourceRanges`) and a reserved address
(`service.loadBalancerIP`). These are Helm values of the chart the deployer
installs; the product documentation describes them in full.

## Upgrade

Re-run `mpdev install` (or use the Marketplace UI) with the new deployer tag;
releases are listed on the product page. The proxy's cache volume and your
AlloyDB shares are preserved across upgrades. Deployments upgraded from 0.1 to
0.2 keep working without a licence for 14 days from the first start on 0.2;
install the licence within that window.

## Uninstall

```sh
kubectl delete application/secretskydb -n "$NAMESPACE"
```

This garbage-collects the application's resources (StatefulSet, Services,
ConfigMaps, Jobs). The AlloyDB share instances and their data — the durable,
secret-shared record — are yours and are never touched by uninstall. Delete
the namespace and the PVC too if you do not intend to reinstall:

```sh
kubectl delete namespace "$NAMESPACE"
```

## License

Use of SecretSkyDB is governed by the End User License Agreement presented on
the Google Cloud Marketplace product page. The deployment instructions in
this repository are provided under the Apache License 2.0.
