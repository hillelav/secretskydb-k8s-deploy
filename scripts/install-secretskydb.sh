#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it deploys is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SecretSkyDB — one-command install on GKE (release 0.3).
#
#   SHARES=alloydb (default)  Terraform provisions three AlloyDB instances (one region each)
#                             and the Kubernetes Secret the proxy reads; Helm then installs
#                             the proxy, its cache and the bootstrap Job.  ~15 minutes.
#   SHARES=test               No Terraform: three small PostgreSQL pods inside the cluster stand
#                             in for the custodians.  Evaluation only — all shares then live in
#                             one trust domain.  ~3 minutes.
#
# Usage:
#   PROJECT_ID=my-proj NETWORK=projects/my-proj/global/networks/my-vpc ./scripts/install-secretskydb.sh
#   PROJECT_ID=my-proj SHARES=test ./scripts/install-secretskydb.sh
#
# Required env:
#   PROJECT_ID          GCP project id (the cluster's project)
#   NETWORK             VPC self-link with Private Services Access, SHARES=alloydb only
# Optional env (defaults shown):
#   SHARES=alloydb            alloydb | test
#   NAMESPACE=secretskydb     Kubernetes namespace
#   RELEASE=secretskydb       Helm release name (also the proxy Service name)
#   TAG=0.3.0                 image tag; REGISTRY defaults to the Marketplace registry
#   PROFILE=                  proxy profile: share-read (default) | cache-first
#   CACHE_STORAGECLASS=       encrypted-at-rest StorageClass for the cache volume ("" = cluster default)
#   REPORTING_SECRET=         name of the Marketplace usage-reporting Secret (from your Marketplace
#                             order). When set, the metering agent runs and usage is billed through
#                             Google Cloud Marketplace; the deployment is licensed by that entitlement.
#   LICENSE_KEY_FILE=         file holding a SecretSkyDB licence token (outside the Marketplace).
#                             Without REPORTING_SECRET or a token, 0.3 runs a 14-day evaluation.
#   USERS_SECRET=             existing Secret with users.json (users, roles, SCRAM verifiers);
#                             default: the single admin user "ssdb" (password in the shares Secret)
#   TLS_SECRET=               kubernetes.io/tls Secret for inbound TLS on the proxy (clients must use TLS)
#   SHARE_REGIONS=            comma-separated AlloyDB regions, e.g. europe-west1,australia-southeast1,asia-southeast1
#   MANAGE_PSA=false          true to create Private Services Access on a fresh VPC (alloydb only)
#   AUTO_APPROVE=false        skip the confirmation prompt (automation)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_ID="${PROJECT_ID:?set PROJECT_ID to your GCP project id}"
SHARES="${SHARES:-alloydb}"
NAMESPACE="${NAMESPACE:-secretskydb}"
RELEASE="${RELEASE:-secretskydb}"
REGISTRY="${REGISTRY:-us-docker.pkg.dev/secretskydb-public/secretskydb-private-legacy}"
TAG="${TAG:-0.3.0}"
PROFILE="${PROFILE:-}"
CACHE_STORAGECLASS="${CACHE_STORAGECLASS:-}"
REPORTING_SECRET="${REPORTING_SECRET:-}"
LICENSE_KEY_FILE="${LICENSE_KEY_FILE:-}"
USERS_SECRET="${USERS_SECRET:-}"
TLS_SECRET="${TLS_SECRET:-}"
SHARE_REGIONS="${SHARE_REGIONS:-}"
MANAGE_PSA="${MANAGE_PSA:-false}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
SHARE_SECRET="secretskydb-alloydb-shares"
APP_CRD_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

case "$SHARES" in
  alloydb) NETWORK="${NETWORK:?set NETWORK to a VPC self-link with Private Services Access (or use SHARES=test)}" ;;
  test)    NETWORK="" ;;
  *)       die "SHARES must be 'alloydb' or 'test' (got '$SHARES')" ;;
esac

# ---- preflight ---------------------------------------------------------------
say "Preflight checks"
TOOLS="gcloud kubectl helm"; [ "$SHARES" = "alloydb" ] && TOOLS="$TOOLS terraform"
for bin in $TOOLS; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH. Install it and retry."
done
kubectl cluster-info >/dev/null 2>&1 || die "kubectl can't reach a cluster. Run: gcloud container clusters get-credentials <cluster> --region <region>"
[ -z "$LICENSE_KEY_FILE" ] || [ -r "$LICENSE_KEY_FILE" ] || die "LICENSE_KEY_FILE '$LICENSE_KEY_FILE' is not readable"
CTX="$(kubectl config current-context)"
echo "  project:    $PROJECT_ID"
echo "  cluster:    $CTX"
echo "  namespace:  $NAMESPACE   release: $RELEASE"
echo "  shares:     $SHARES${SHARE_REGIONS:+ ($SHARE_REGIONS)}"
echo "  images:     $REGISTRY/{proxy,cache,ubbagent}:$TAG"
if [ -n "$REPORTING_SECRET" ]; then echo "  licence:    Google Cloud Marketplace entitlement (metered via Secret '$REPORTING_SECRET')"
elif [ -n "$LICENSE_KEY_FILE" ]; then echo "  licence:    token from $LICENSE_KEY_FILE"
else echo "  licence:    none — 14-day evaluation"; fi

if [ "$AUTO_APPROVE" != "true" ]; then
  if [ "$SHARES" = "alloydb" ]; then
    printf '\nThis creates 3 AlloyDB instances (billable, ~10-15 min) and installs SecretSkyDB into the cluster above.\nProceed? [y/N] '
  else
    printf '\nThis installs SecretSkyDB with three in-cluster stand-in shares (evaluation) into the cluster above.\nProceed? [y/N] '
  fi
  read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "Aborted."
fi

gcloud config set project "$PROJECT_ID" >/dev/null

# ---- APIs, CRD, namespace ----------------------------------------------------
if [ "$SHARES" = "alloydb" ]; then
  say "Enabling required APIs (alloydb, servicenetworking, compute, container)"
  gcloud services enable alloydb.googleapis.com servicenetworking.googleapis.com \
    compute.googleapis.com container.googleapis.com --project="$PROJECT_ID"
fi

if ! kubectl get crd applications.app.k8s.io >/dev/null 2>&1; then
  say "Installing the Kubernetes Application CRD (one-time per cluster)"
  kubectl apply -f "$APP_CRD_URL"
fi
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# ---- shares ------------------------------------------------------------------
if [ "$SHARES" = "alloydb" ]; then
  say "Provisioning AlloyDB shares + '$SHARE_SECRET' Secret (Terraform)"
  TF_ARGS=( -input=false -auto-approve
    -var "project_id=$PROJECT_ID" -var "network=$NETWORK"
    -var "k8s_namespace=$NAMESPACE" -var "manage_psa=$MANAGE_PSA" )
  if [ -n "$SHARE_REGIONS" ]; then
    REGION_LIST="$(printf '%s' "$SHARE_REGIONS" | sed 's/[[:space:]]//g; s/,/","/g')"
    TF_ARGS+=( -var "regions=[\"$REGION_LIST\"]" )
  fi
  ( cd "$REPO_DIR/terraform" && terraform init -input=false && terraform apply "${TF_ARGS[@]}" )
  say "Verifying the shares Secret exists in namespace '$NAMESPACE'"
  kubectl -n "$NAMESPACE" get secret "$SHARE_SECRET" >/dev/null 2>&1 \
    || die "Secret '$SHARE_SECRET' not found in '$NAMESPACE' — Terraform did not write it (check the kube context / create_k8s_secret)."
fi

# ---- app ---------------------------------------------------------------------
say "Installing SecretSkyDB $TAG (Helm release '$RELEASE')"
HELM_ARGS=(
  upgrade --install "$RELEASE" "$REPO_DIR/chart/secretskydb"
  --namespace "$NAMESPACE" --create-namespace
  --set "proxy.image.repo=$REGISTRY/proxy"
  --set "proxy.image.tag=$TAG"
  --set "cache.image=$REGISTRY/cache:$TAG"
  --set "ubbagent.image=$REGISTRY/ubbagent:$TAG"
  --wait --timeout 10m
)
if [ -n "$REPORTING_SECRET" ]; then
  HELM_ARGS+=( --set "ubbagent.enabled=true" --set "reportingSecret=$REPORTING_SECRET" )
else
  HELM_ARGS+=( --set "ubbagent.enabled=false" )
fi
[ "$SHARES" = "test" ]        && HELM_ARGS+=( --set "testShares.enabled=true" --set "sharesSslmode=disable" )   # stand-in shares are plain Postgres, no TLS
[ -n "$PROFILE" ]             && HELM_ARGS+=( --set "proxy.profile=$PROFILE" )
[ -n "$CACHE_STORAGECLASS" ]  && HELM_ARGS+=( --set "cache.persistence.storageClass=$CACHE_STORAGECLASS" )
[ -n "$LICENSE_KEY_FILE" ]    && HELM_ARGS+=( --set-file "license.key=$LICENSE_KEY_FILE" )
[ -n "$USERS_SECRET" ]        && HELM_ARGS+=( --set "users.existingSecret=$USERS_SECRET" )
[ -n "$TLS_SECRET" ]          && HELM_ARGS+=( --set "tls.enabled=true" --set "tls.secretName=$TLS_SECRET" )
# A Job's template is immutable: on re-runs (upgrades) recreate the idempotent bootstrap Job.
kubectl -n "$NAMESPACE" delete job "$RELEASE-bootstrap" --ignore-not-found >/dev/null 2>&1 || true
EXISTED=false; helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1 && EXISTED=true
helm "${HELM_ARGS[@]}"
if [ "$EXISTED" = "true" ]; then
  # the proxy reads its share configuration at start: pick up changed values on an upgrade
  kubectl -n "$NAMESPACE" rollout restart "statefulset/$RELEASE" >/dev/null
  kubectl -n "$NAMESPACE" rollout status "statefulset/$RELEASE" --timeout=5m >/dev/null || true
fi

say "Waiting for the bootstrap Job (prepares the SQL functions on each share)"
kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$RELEASE-bootstrap" --timeout=5m \
  || echo "  (bootstrap Job still running; the proxy retries it — check: kubectl -n $NAMESPACE logs job/$RELEASE-bootstrap)"

# ---- summary -----------------------------------------------------------------
say "SecretSkyDB is installed"
PORT="$(kubectl -n "$NAMESPACE" get svc "$RELEASE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo 55432)"
cat <<EOF

  Connect your application to the proxy as a normal PostgreSQL server:
    Host:      $RELEASE.$NAMESPACE.svc.cluster.local   (in-cluster)
    Port:      $PORT
    Database:  ssdb
    User:      ssdb$( [ -n "$USERS_SECRET" ] && printf ', plus the users in Secret %s' "$USERS_SECRET" )
    Password:  kubectl -n $NAMESPACE get secret $SHARE_SECRET -o jsonpath='{.data.proxy}' | base64 -d
$( [ -n "$TLS_SECRET" ] && printf '    TLS:       required (sslmode=require)\n' )
  From your laptop:
    kubectl -n $NAMESPACE port-forward svc/$RELEASE $PORT:$PORT &
    psql "host=127.0.0.1 port=$PORT user=ssdb dbname=ssdb"

  Licence and share status:
    kubectl -n $NAMESPACE port-forward pod/$RELEASE-0 55433:55433 &
    curl -s http://127.0.0.1:55433/statusz | python3 -m json.tool

$( if [ "$SHARES" = "test" ]; then
     printf '  Shares: three stand-in PostgreSQL pods in this cluster (evaluation). For production,\n  point the Secret %s at custodians in separate trust domains (SHARES=alloydb, or your own).\n' "$SHARE_SECRET"
   else
     printf '  Shares: three AlloyDB instances, one per region. Each holds sub-threshold shares only;\n  plaintext exists only inside the proxy pod.\n'
   fi )
EOF
