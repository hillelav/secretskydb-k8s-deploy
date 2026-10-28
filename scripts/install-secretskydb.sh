#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it deploys is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SecretSkyDB — one-command install on GKE (release 0.4).
#
#   SHARES=alloydb (default)  Terraform provisions three AlloyDB instances (one region each)
#                             and the Kubernetes Secret the proxy reads; Helm then installs
#                             the proxy, its cache and the bootstrap Job.  ~15 minutes.
#   SHARES=incluster          No Terraform: the chart runs the three share stores inside the
#                             cluster (quick start, ~3 minutes). All custodians then share one
#                             cluster and one administrator; move to AlloyDB for separation.
#
# Usage:
#   ./scripts/install-secretskydb.sh              # gcloud project, its default VPC, AlloyDB shares
#   SHARES=incluster ./scripts/install-secretskydb.sh  # quick start, share stores in the cluster
#   PROJECT_ID=my-proj NETWORK=projects/my-proj/global/networks/my-vpc ./scripts/install-secretskydb.sh
#
# Required env:
#   PROJECT_ID          GCP project id (the cluster's project)
#   NETWORK             VPC self-link, SHARES=alloydb only; default the project's 'default' VPC
# Optional env (defaults shown):
#   SHARES=alloydb            alloydb | incluster
#   NAMESPACE=secretskydb     Kubernetes namespace
#   RELEASE=secretskydb       Helm release name (also the proxy Service name)
#   RESTART=false             true to roll the proxy after an upgrade that re-pinned the same image tag
#   TAG=0.4.0                 image tag; REGISTRY defaults to the Marketplace registry
#   PROFILE=                  proxy profile: share-read (default) | cache-first
#   CACHE_STORAGECLASS=       encrypted-at-rest StorageClass for the cache volume ("" = cluster default)
#   REPORTING_SECRET=         name of the Marketplace usage-reporting Secret (from your Marketplace
#                             order). When set, the metering agent runs and usage is billed through
#                             Google Cloud Marketplace; the deployment is licensed by that entitlement.
#   LICENSE_KEY_FILE=         file holding a SecretSkyDB licence token (outside the Marketplace).
#                             Without REPORTING_SECRET or a token, 0.4 runs a 14-day evaluation.
#   USERS_SECRET=             existing Secret with users.json (users, roles, SCRAM verifiers);
#                             default: the single admin user "ssdb" (password in the shares Secret)
#   TLS_SECRET=               kubernetes.io/tls Secret for inbound TLS on the proxy (clients must use TLS)
#   SHARE_REGIONS=            comma-separated AlloyDB regions, e.g. europe-west1,australia-southeast1,asia-southeast1
#   MANAGE_PSA                true/false; default: detected (true when the VPC has no PSA peering yet)
#   AUTO_APPROVE=false        skip the confirmation prompt (automation)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- defaults a Cloud Shell user need not type -----------------------------------
# PROJECT_ID falls back to the gcloud default; NETWORK to the project's "default" VPC;
# MANAGE_PSA is detected: true when that VPC has no Private Services Access peering yet.
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[ -n "$PROJECT_ID" ] || { echo "ERROR: set PROJECT_ID (or 'gcloud config set project …')" >&2; exit 1; }
_default_network() { printf 'projects/%s/global/networks/default' "$PROJECT_ID"; }
_detect_psa() {   # prints true when the network has no servicenetworking peering
  local net="${1##*/}" peer
  peer="$(gcloud services vpc-peerings list --network="$net" --project="$PROJECT_ID" \
            --format='value(peering)' 2>/dev/null | grep -c servicenetworking || true)"
  [ "$peer" = "0" ] && echo true || echo false
}
SHARES_GIVEN="${SHARES+x}"
SHARES="${SHARES:-alloydb}"
[ "$SHARES" = "test" ] && SHARES=incluster   # old name
NAMESPACE="${NAMESPACE:-secretskydb}"
RELEASE="${RELEASE:-secretskydb}"
REGISTRY="${REGISTRY:-us-docker.pkg.dev/secretskydb-public/secretskydb-private-legacy}"
TAG="${TAG:-0.4.0}"
PROFILE="${PROFILE:-}"
CACHE_STORAGECLASS="${CACHE_STORAGECLASS:-}"
REPORTING_SECRET="${REPORTING_SECRET:-}"
LICENSE_KEY_FILE="${LICENSE_KEY_FILE:-}"
USERS_SECRET="${USERS_SECRET:-}"
TLS_SECRET="${TLS_SECRET:-}"
SHARE_REGIONS="${SHARE_REGIONS:-}"
MANAGE_PSA="${MANAGE_PSA:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
APP_CRD_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- existing release: upgrade in place -------------------------------------
# An upgrade keeps every value of the installed release (--reuse-values); only what is set
# explicitly below changes. The share layout follows the release unless SHARES is given:
# upgrading an AlloyDB install must not create in-cluster shares, and vice versa. Detected
# FIRST: everything below (the VPC lookup, the tool list, the prompt, the APIs, the Secret
# name) depends on the share layout, and a quick-start upgrade without SHARES= used to run
# the AlloyDB preflight and die on a project without a 'default' VPC or terraform.
EXISTING=""
DETECTED=""
if command -v helm >/dev/null 2>&1 && helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1; then
  EXISTING="yes"
  if helm get values "$RELEASE" --namespace "$NAMESPACE" -o yaml 2>/dev/null | grep -A1 '^inclusterShares:' | grep -q 'enabled: true'; then
    DETECTED=incluster
  else
    DETECTED=alloydb
  fi
  if [ -z "$SHARES_GIVEN" ]; then
    SHARES="$DETECTED"
    say "Release '$RELEASE' exists: upgrading in place (shares: $SHARES, from the release)"
  elif [ "$SHARES" != "$DETECTED" ] && [ "${FORCE_SHARES_CHANGE:-false}" != "true" ]; then
    # Changing the layout in place is not an upgrade: incluster -> alloydb deletes the three share
    # StatefulSets and the Secret that holds their passwords; alloydb -> incluster points the
    # proxy at empty shares and the identity check refuses to stream.
    die "release '$RELEASE' uses $DETECTED shares; SHARES=$SHARES would change the share layout in place. Install a new release and copy the data (or set FORCE_SHARES_CHANGE=true if that is really what you want)."
  else
    say "Release '$RELEASE' exists: upgrading in place"
  fi
fi
SHARE_SECRET="secretskydb-alloydb-shares"           # AlloyDB: written by Terraform; incluster: <release>-shares
[ "$SHARES" = "incluster" ] && SHARE_SECRET="$RELEASE-shares"   # generated by the chart

case "$SHARES" in
  alloydb) NETWORK="${NETWORK:-$(_default_network)}"
           [ -z "$NETWORK" ] || gcloud compute networks describe "${NETWORK##*/}" --project="$PROJECT_ID" >/dev/null 2>&1 \
             || { echo "ERROR: VPC '$NETWORK' not found in $PROJECT_ID; set NETWORK=projects/$PROJECT_ID/global/networks/<name>" >&2; exit 1; }
           MANAGE_PSA="${MANAGE_PSA:-$(_detect_psa "$NETWORK")}" ;;
  incluster) NETWORK="" ;;
  *)       die "SHARES must be 'alloydb' or 'incluster' (got '$SHARES')" ;;
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
  [ -t 0 ] || die "stdin is not a terminal: set AUTO_APPROVE=true for a non-interactive run"
  if [ -n "$EXISTING" ]; then
    printf '\nThis upgrades release %s in place to %s (shares: %s, kept as they are).\nProceed? [y/N] ' "$RELEASE" "$TAG" "$SHARES"
  elif [ "$SHARES" = "alloydb" ]; then
    printf '\nThis creates 3 AlloyDB instances (billable, ~10-15 min) and installs SecretSkyDB into the cluster above.\nProceed? [y/N] '
  else
    printf '\nThis installs SecretSkyDB with its three share stores inside the cluster above (quick start).\nProceed? [y/N] '
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
  if [ -z "$EXISTING" ] || [ "${REAPPLY_SHARES:-false}" = "true" ]; then
    say "Provisioning AlloyDB shares + '$SHARE_SECRET' Secret (Terraform)"
    TF_ARGS=( -input=false -auto-approve
      -var "project_id=$PROJECT_ID" -var "network=$NETWORK"
      -var "k8s_namespace=$NAMESPACE" -var "manage_psa=$MANAGE_PSA" )
    if [ -n "$SHARE_REGIONS" ]; then
      REGION_LIST="$(printf '%s' "$SHARE_REGIONS" | sed 's/[[:space:]]//g; s/,/","/g')"
      TF_ARGS+=( -var "regions=[\"$REGION_LIST\"]" )
    fi
    # 0.3 renamed the Secret resource (kubernetes_secret -> _v1); move it in an older state instead of recreating it
    ( cd "$REPO_DIR/terraform" && terraform init -input=false \
      && { terraform state list 2>/dev/null | grep -q '^kubernetes_secret\.shares' \
           && terraform state mv 'kubernetes_secret.shares[0]' 'kubernetes_secret_v1.shares[0]' || true; } \
      && terraform apply "${TF_ARGS[@]}" )
  else
    # The Terraform state lives in the checkout that created the shares (terraform/terraform.tfstate,
    # not committed); from any other checkout an apply would try to create the clusters again.
    say "Existing release: AlloyDB shares and Secret '$SHARE_SECRET' kept as they are (REAPPLY_SHARES=true re-runs Terraform from this checkout's state)"
  fi
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
  --set "bootstrap.image=$REGISTRY/cache:$TAG"
  --wait --timeout 10m
)
[ -n "$EXISTING" ] && HELM_ARGS+=( --reuse-values )
if [ -n "$REPORTING_SECRET" ]; then
  HELM_ARGS+=( --set "ubbagent.enabled=true" --set "reportingSecret=$REPORTING_SECRET" )
elif [ -z "$EXISTING" ]; then
  HELM_ARGS+=( --set "ubbagent.enabled=false" )
fi   # an upgrade without REPORTING_SECRET keeps the release's metering as installed (--reuse-values)
if [ "$SHARES" = "incluster" ]; then HELM_ARGS+=( --set "inclusterShares.enabled=true" )    # the chart runs the three share stores in the cluster
else                              HELM_ARGS+=( --set "inclusterShares.enabled=false" ); fi
[ -n "$PROFILE" ]             && HELM_ARGS+=( --set "proxy.profile=$PROFILE" )
[ -n "$CACHE_STORAGECLASS" ]  && HELM_ARGS+=( --set "cache.persistence.storageClass=$CACHE_STORAGECLASS" )
[ -n "$LICENSE_KEY_FILE" ]    && HELM_ARGS+=( --set-file "license.key=$LICENSE_KEY_FILE" )
[ -n "$USERS_SECRET" ]        && HELM_ARGS+=( --set "users.existingSecret=$USERS_SECRET" )
[ -n "$TLS_SECRET" ]          && HELM_ARGS+=( --set "tls.enabled=true" --set "tls.secretName=$TLS_SECRET" )
# A Job's template is immutable: on re-runs (upgrades) recreate the idempotent bootstrap Job.
kubectl -n "$NAMESPACE" delete job "$RELEASE-bootstrap" --ignore-not-found >/dev/null 2>&1 || true
helm "${HELM_ARGS[@]}"
if [ "${RESTART:-false}" = "true" ]; then
  # a CVE rebuild re-pins the image under the same tag (imagePullPolicy Always): roll the proxy by hand
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

$( if [ "$SHARES" = "incluster" ]; then
     printf '  Shares: three PostgreSQL stores in this cluster, one administrator. For separated custodians\n  move to AlloyDB (SHARES=alloydb) or your own servers; the Secret is then %s.\n' "$SHARE_SECRET"
   else
     printf '  Shares: three AlloyDB instances, one per region. Each holds sub-threshold shares only;\n  plaintext exists only inside the proxy pod.\n'
   fi )
EOF
