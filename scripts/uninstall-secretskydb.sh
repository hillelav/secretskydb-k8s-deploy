#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it removes is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SHARES=incluster (an install whose share stores run in the cluster) needs no NETWORK and
# runs no Terraform: the share pods go away with the Helm release (their PVCs are kept).
#
# SecretSkyDB — customer uninstall. Removes the app (Helm) and then the share data
# plane (Terraform: the 3 AlloyDB instances + the shares Secret).
#
# ⚠️  DESTRUCTIVE: `terraform destroy` deletes the AlloyDB shares and ALL DATA on them.
#     Back up first if you need to keep anything.
#
# Usage:
#   ./scripts/uninstall-secretskydb.sh            # same PROJECT_ID / NETWORK as the install
#
# Env mirrors install-secretskydb.sh: PROJECT_ID, NETWORK (defaults: gcloud project, its default VPC),
#   NAMESPACE=secretskydb, MANAGE_PSA=false, AUTO_APPROVE=false, KEEP_NAMESPACE=false

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[ -n "$PROJECT_ID" ] || { echo "ERROR: set PROJECT_ID (or 'gcloud config set project …')" >&2; exit 1; }
SHARES="${SHARES:-alloydb}"
[ "$SHARES" = "test" ] && SHARES=incluster
if [ "$SHARES" = "alloydb" ]; then
  NETWORK="${NETWORK:-projects/$PROJECT_ID/global/networks/default}"   # same VPC as the install
else
  NETWORK=""
fi
NAMESPACE="${NAMESPACE:-secretskydb}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
KEEP_NAMESPACE="${KEEP_NAMESPACE:-false}"
RELEASE="${RELEASE:-secretskydb}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

TOOLS="gcloud kubectl helm"; [ "$SHARES" = "alloydb" ] && TOOLS="$TOOLS terraform"
for bin in $TOOLS; do command -v "$bin" >/dev/null || die "'$bin' not found"; done
gcloud config set project "$PROJECT_ID" >/dev/null

if [ "$SHARES" = "alloydb" ]; then
  say "This will DELETE the SecretSkyDB app and the 3 AlloyDB shares (ALL DATA) in project $PROJECT_ID."
else
  say "This will DELETE the SecretSkyDB app and its in-cluster share stores (ALL DATA) in project $PROJECT_ID."
fi
if [ "$AUTO_APPROVE" != "true" ]; then
  printf 'Type the project id to confirm: '; read -r c; [ "$c" = "$PROJECT_ID" ] || die "Aborted."
fi

# 1) app first (so nothing is still writing to the shares)
say "Uninstalling the Helm release '$RELEASE'"
helm -n "$NAMESPACE" uninstall "$RELEASE" --wait --timeout 5m || true

# 2) share data plane + Secret
if [ "$SHARES" = "alloydb" ]; then
  say "Destroying AlloyDB shares + shares Secret (Terraform)"
  ( cd "$REPO_DIR/terraform"
    terraform destroy -input=false -auto-approve \
      -var "project_id=$PROJECT_ID" \
      -var "network=$NETWORK" \
      -var "k8s_namespace=$NAMESPACE" \
      -var "manage_psa=${MANAGE_PSA:-$(terraform state list 2>/dev/null | grep -q service_networking_connection && echo true || echo false)}"
  )
fi

# 3) namespace (optional)
if [ "$KEEP_NAMESPACE" != "true" ]; then
  say "Deleting namespace '$NAMESPACE'"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
fi

say "SecretSkyDB uninstalled."
