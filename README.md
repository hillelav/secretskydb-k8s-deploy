# Deploying SecretSkyDB on GKE

SecretSkyDB is a wire-compatible PostgreSQL proxy that stores every protected value
as 2-of-3 secret shares across separate database instances, so no single server,
cloud or administrator ever holds recoverable data. This repository holds the
**deployment assets** for the SecretSkyDB Kubernetes application: the Helm chart,
the Terraform module that provisions the share stores, and a one-command install
script. The application images themselves are distributed through Google Cloud
Marketplace.

- Product page: Google Cloud Marketplace → *SecretSkyDB*
- Install guide: [docs/INSTALL.md](docs/INSTALL.md)
- Support: support@secretskydb.com
- Licence: use of the Software is governed by the [End User License Agreement](https://www.secretskydb.com/eula);
  the files in this repository are provided under the Apache License 2.0.

## Install from Cloud Shell, nothing to install locally

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/hillelav/secretskydb-k8s-deploy&cloudshell_tutorial=docs/cloudshell-tutorial.md&cloudshell_workspace=.)

The button opens Cloud Shell in your project with this repository checked out and a
step-by-step walkthrough beside the terminal: pick the project, connect the cluster,
prepare the shares, deploy, test. Cloud Shell already has gcloud, kubectl, terraform and
helm.

## Three ways to install

| Path | What you get | Billing |
|---|---|---|
| **Marketplace console** (Configure → Deploy) | the proxy in your cluster, metered usage; `scripts/prepare-shares.sh` creates the share stores first | your GCP invoice |
| **One command** (`scripts/install-secretskydb.sh`) | shares provisioned by Terraform **and** the proxy, in one run | metered if you pass the Marketplace reporting Secret, otherwise a licence token or a 14-day evaluation |
| **`mpdev install`** (command-line deployer) | the same deploy as the console, scripted | your GCP invoice |

## Prerequisites

- A GKE cluster (Standard or Autopilot), Kubernetes ≥ 1.27, with `kubectl`
  pointed at it:
  ```sh
  gcloud container clusters get-credentials CLUSTER --region REGION
  ```
- For AlloyDB shares: a VPC with Private Services Access (the script can create
  it with `MANAGE_PSA=true`), and `terraform` and `helm` on your PATH.
- For the Marketplace console and `mpdev` paths: service-account key creation
  allowed in the project (the deployer creates a key for usage reporting). If your
  organization blocks it, an Organization Policy Administrator can override
  `iam.disableServiceAccountKeyCreation` for the project; see docs/INSTALL.md.

## Prepare the shares, then deploy from the Marketplace

The Deploy button cannot create databases. This creates the three AlloyDB share
instances and the shares Secret, then tells you what to enter in the deploy form:

```sh
git clone https://github.com/hillelav/secretskydb-k8s-deploy.git && cd secretskydb-k8s-deploy
./scripts/prepare-shares.sh
```

Defaults: the gcloud project, its `default` VPC, and Private Services Access added to
that VPC if missing. Set `PROJECT_ID`, `NETWORK=projects/PROJECT/global/networks/NAME`
and `SHARE_REGIONS=region1,region2,region3` to choose otherwise.

## One-command install

Shares on AlloyDB, three regions, about 15 minutes:

```sh
git clone https://github.com/hillelav/secretskydb-k8s-deploy.git && cd secretskydb-k8s-deploy
./scripts/install-secretskydb.sh
```

(same defaults as `prepare-shares.sh`)

Evaluation with three stand-in PostgreSQL pods inside the cluster, no Terraform,
about 3 minutes (all shares in one trust domain, so not for production):

```sh
SHARES=test ./scripts/install-secretskydb.sh
```

Useful options (environment variables):

| Variable | Meaning |
|---|---|
| `REPORTING_SECRET` | name of the usage-reporting Secret from your Marketplace order; enables metering and licenses the deployment by that entitlement |
| `LICENSE_KEY_FILE` | a SecretSkyDB licence token for deployments outside the Marketplace (request at https://secretskydb.com/license) |
| `USERS_SECRET` | a Secret with `users.json` (users, roles, SCRAM verifiers); default is the single admin user `ssdb` |
| `TLS_SECRET` | a `kubernetes.io/tls` Secret; clients must then connect with TLS |
| `PROFILE` | `share-read` (default) or `cache-first`; see the install guide |
| `SHARE_REGIONS` | comma-separated AlloyDB regions for the three shares |
| `CACHE_STORAGECLASS` | encrypted-at-rest StorageClass for the proxy's cache volume |
| `PROJECT_ID`, `NETWORK` | default: the gcloud project and its `default` VPC |
| `MANAGE_PSA` | default: detected; `true` adds Private Services Access to the VPC |
| `NAMESPACE`, `RELEASE`, `TAG`, `AUTO_APPROVE` | as named |

The script prints the connection details when it finishes. To remove everything,
including the AlloyDB shares and their data, run `scripts/uninstall-secretskydb.sh`
with the same variables.

## Command-line deployer (`mpdev`)

The same deploy the Marketplace console performs, driven from a shell. The share
stores and their Secret must exist first (the Terraform in `terraform/` creates
them: three AlloyDB instances and the Secret `secretskydb-alloydb-shares` with the
keys `proxy`, `cache`, `share-a/b/c`, `share-a/b/c-host`, `share-a/b/c-user`).

```sh
BIN=/usr/local/bin/mpdev
docker run --rm --entrypoint=cat gcr.io/cloud-marketplace-tools/k8s/dev /scripts/dev > /tmp/mpdev \
  && chmod +x /tmp/mpdev && sudo mv /tmp/mpdev "$BIN"

kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"
NAMESPACE=secretskydb
kubectl create namespace "$NAMESPACE"

mpdev install \
  --deployer=us-docker.pkg.dev/secretskydb-public/secretskydb-private-legacy/deployer:0.3 \
  --parameters='{
    "name": "secretskydb",
    "namespace": "'$NAMESPACE'",
    "alloydbShareSecret": "secretskydb-alloydb-shares",
    "reportingSecret": "REPORTING_SECRET_NAME"
  }'
```

`reportingSecret` is the usage-reporting Secret that Google Cloud Marketplace
creates for your order (Marketplace → your order → credentials). With it, the
metering agent reports `proxy_time` usage for billing and the deployment is
licensed by the Marketplace entitlement; no licence key is needed. A `license.key`
parameter exists for deployments that hold a SecretSkyDB licence token instead.

## After the install

```sh
kubectl get application/secretskydb -n "$NAMESPACE"   # status: Healthy
kubectl get pods -n "$NAMESPACE"                       # proxy StatefulSet Ready
```

Connect exactly as to PostgreSQL, no driver changes:

```sh
kubectl port-forward -n "$NAMESPACE" svc/secretskydb 55432:55432 &
psql "host=127.0.0.1 port=55432 user=ssdb dbname=ssdb"
```

Licence state and share status:

```sh
kubectl port-forward -n "$NAMESPACE" pod/secretskydb-0 55433:55433 &
curl -s http://127.0.0.1:55433/statusz | python3 -m json.tool
```

Column protection tiers are declared in the table schema; see docs/INSTALL.md for
the `Secret` / `Cacheable` / `Open` column model, users and roles, TLS, and the
encrypted-at-rest StorageClass recommendation for the cache volume.

## Upgrade

Re-run the install script or `mpdev install` with the new tag, or use the
Marketplace console; releases are listed on the product page. The proxy's cache
volume and your shares are preserved across upgrades.

## Uninstall

```sh
kubectl delete application/secretskydb -n "$NAMESPACE"
```

This removes the application's resources (StatefulSet, Services, ConfigMaps,
Jobs). The share instances and their data, the durable secret-shared record, are
yours and are never touched by uninstall. `scripts/uninstall-secretskydb.sh`
additionally destroys the AlloyDB shares created by the Terraform module, after
an explicit confirmation.
