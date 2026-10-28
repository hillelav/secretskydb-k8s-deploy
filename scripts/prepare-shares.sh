#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software is proprietary and governed by the SecretSkyDB End User License Agreement
# (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SecretSkyDB — prepare the share stores for a Google Cloud Marketplace deploy.
#
# Creates everything the Marketplace "Deploy" button cannot create itself: three AlloyDB
# instances (one per region, each holding sub-threshold shares only), Private Services
# Access if asked, and the Kubernetes Secret the proxy reads. Then click Deploy on the
# Marketplace listing; usage is metered to your Google Cloud invoice.  ~10-15 minutes.
#
# Usage:
#   ./scripts/prepare-shares.sh                   # gcloud project, its default VPC
#   PROJECT_ID=my-proj NETWORK=projects/my-proj/global/networks/my-vpc ./scripts/prepare-shares.sh
#
# Required env:
#   PROJECT_ID        GCP project id (the cluster's project)
#   NETWORK           VPC self-link; default projects/$PROJECT_ID/global/networks/default
# Optional env (defaults shown):
#   NAMESPACE=secretskydb     namespace you will deploy into (the Secret is written there)
#   SHARE_REGIONS=            comma-separated AlloyDB regions for the three shares
#   MANAGE_PSA                true/false; default: detected (true when the VPC has no PSA peering yet)
#   AUTO_APPROVE=false        skip the confirmation prompt
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
NETWORK="${NETWORK:-$(_default_network)}"
[ -z "$NETWORK" ] || gcloud compute networks describe "${NETWORK##*/}" --project="$PROJECT_ID" >/dev/null 2>&1 \
  || { echo "ERROR: VPC '$NETWORK' not found in $PROJECT_ID; set NETWORK=projects/$PROJECT_ID/global/networks/<name>" >&2; exit 1; }
NAMESPACE="${NAMESPACE:-secretskydb}"
SHARE_REGIONS="${SHARE_REGIONS:-}"
MANAGE_PSA="${MANAGE_PSA:-$(_detect_psa "$NETWORK")}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
SHARE_SECRET="secretskydb-alloydb-shares"
APP_CRD_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

say "Preflight checks"
for bin in gcloud kubectl terraform; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found on PATH. Install it and retry."
done
kubectl cluster-info >/dev/null 2>&1 || die "kubectl can't reach a cluster. Run: gcloud container clusters get-credentials <cluster> --region <region>"
echo "  project:    $PROJECT_ID"
echo "  cluster:    $(kubectl config current-context)"
echo "  namespace:  $NAMESPACE"
echo "  regions:    ${SHARE_REGIONS:-module defaults}"

if [ "$AUTO_APPROVE" != "true" ]; then
  printf '\nThis creates 3 AlloyDB instances (billable, ~10-15 min) and the shares Secret in the cluster above.\nProceed? [y/N] '
  read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ] || die "Aborted."
fi

gcloud config set project "$PROJECT_ID" >/dev/null
say "Enabling required APIs (alloydb, servicenetworking, compute, container)"
gcloud services enable alloydb.googleapis.com servicenetworking.googleapis.com \
  compute.googleapis.com container.googleapis.com --project="$PROJECT_ID"

if ! kubectl get crd applications.app.k8s.io >/dev/null 2>&1; then
  say "Installing the Kubernetes Application CRD (one-time per cluster)"
  kubectl apply -f "$APP_CRD_URL"
fi
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

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

kubectl -n "$NAMESPACE" get secret "$SHARE_SECRET" >/dev/null 2>&1 \
  || die "Secret '$SHARE_SECRET' not found in '$NAMESPACE' — Terraform did not write it (check the kube context)."

say "Shares are ready"
cat <<EOF

  Now deploy from Google Cloud Marketplace: open the SecretSkyDB listing → Configure, and enter
    Cluster:                     $(kubectl config current-context)
    Namespace:                   $NAMESPACE
    Create the three share stores inside this cluster:  UNCHECK (the shares are the AlloyDB instances)
    AlloyDB shares secret (name): $SHARE_SECRET
    Licence key:                 leave empty (the Marketplace entitlement is the licence)
  then click Deploy. The proxy comes up in a few minutes; usage is metered to your invoice.

  Prefer the command line? The same deploy, scripted (needs Google's mpdev tool and the
  reporting Secret from your Marketplace order):
    mpdev install --deployer=us-docker.pkg.dev/secretskydb-public/secretskydb-private-legacy/deployer:0.4 \\
      --parameters='{"name":"secretskydb","namespace":"$NAMESPACE","inclusterShares.enabled":false,"alloydbShareSecret":"$SHARE_SECRET","reportingSecret":"<your reporting secret>"}'

  To remove the shares later (ALL DATA on them): scripts/uninstall-secretskydb.sh with the same variables,
  after deleting the application.
EOF
