#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it deploys is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SecretSkyDB on YOUR OWN Kubernetes cluster (on-premises, another cloud, a laptop), billed
# through Google Cloud Marketplace — the "Deploy via command line" path of the product page.
#
#   1. On the product page, Configure → "Deploy via command line" → Download service account key.
#      You get service-account-key.yaml: a Kubernetes Secret with the usage-reporting key of your order.
#   2. KEY_FILE=~/Downloads/service-account-key.yaml ./scripts/install-onprem.sh
#
# What it does: creates the namespace → applies the reporting Secret → builds an image-pull Secret
# from the same key (the Marketplace registry serves images to authenticated Google identities) →
# helm install with chart/secretskydb/values-onprem.yaml (three share stores in this cluster, metering
# on, no GKE-only resources) → waits for the proxy → prints how to connect.
# Usage is reported hourly to Google and billed to the billing account of your order (a private offer
# applies as on GKE). The cluster needs outbound HTTPS to marketplace.gcr.io and *.googleapis.com.
#
# Without KEY_FILE the deployment runs the 14-day evaluation (no metering, nothing billed) and needs
# a pull Secret you create yourself (PULL_SECRET=name) or a licence token (LICENSE_KEY_FILE=...).
#
# Optional env (defaults shown):
#   NAMESPACE=secretskydb      Kubernetes namespace
#   RELEASE=secretskydb        Helm release name (also the proxy Service name)
#   TAG=0.4.0                  image tag (the version of your order)
#   PULL_SECRET=gcr-pull       name of the image-pull Secret (created from KEY_FILE unless it exists)
#   STORAGECLASS=              StorageClass for the cache and share volumes ("" = cluster default;
#                              prefer an encrypted-at-rest class)
#   PROFILE=share-read         proxy profile: share-read | cache-first
#   VALUES=                    extra values file merged last (your overrides)
#   LICENSE_KEY_FILE=          SecretSkyDB licence token for a deployment without KEY_FILE
#   AUTO_APPROVE=false         skip the confirmation prompt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/../chart/secretskydb"
KEY_FILE="${KEY_FILE:-}"
NAMESPACE="${NAMESPACE:-secretskydb}"
RELEASE="${RELEASE:-secretskydb}"
TAG="${TAG:-0.4.0}"
PULL_SECRET="${PULL_SECRET:-gcr-pull}"
STORAGECLASS="${STORAGECLASS:-}"
PROFILE="${PROFILE:-share-read}"
VALUES="${VALUES:-}"
LICENSE_KEY_FILE="${LICENSE_KEY_FILE:-}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
REGISTRY="marketplace.gcr.io/secretskydb-public/secretskydb"

B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
step(){ printf "%b\n" "${B}▸ $*${N}"; }
die(){ printf "%b\n" "${R}✗ $*${N}" >&2; exit 1; }

for t in kubectl helm; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
[ -d "$CHART/templates" ] || die "chart not found at $CHART (run from a checkout of this repository)"
CTX="$(kubectl config current-context 2>/dev/null || true)"; [ -n "$CTX" ] || die "kubectl has no current context"
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "cannot reach the cluster of context $CTX"
[ -z "$KEY_FILE" ] || [ -s "$KEY_FILE" ] || die "KEY_FILE not found: $KEY_FILE"
[ -z "$LICENSE_KEY_FILE" ] || [ -s "$LICENSE_KEY_FILE" ] || die "LICENSE_KEY_FILE not found: $LICENSE_KEY_FILE"
[ -z "$VALUES" ] || [ -s "$VALUES" ] || die "VALUES not found: $VALUES"

REPORTING_SECRET=""
if [ -n "$KEY_FILE" ]; then
  head -c1 "$KEY_FILE" | grep -q '{' && die "KEY_FILE is a raw JSON key. Download the Kubernetes Secret (service-account-key.yaml) from the product page's 'Deploy via command line' tab: it also carries the consumer id the metering needs."
  REPORTING_SECRET="$(kubectl create --dry-run=client -o jsonpath='{.metadata.name}' -f "$KEY_FILE" 2>/dev/null)" || die "KEY_FILE is not a Kubernetes Secret manifest"
  [ -n "$REPORTING_SECRET" ] || die "could not read the Secret name from $KEY_FILE"
fi

echo
echo "  cluster        $CTX"
echo "  namespace      $NAMESPACE      release $RELEASE      images $REGISTRY/*:$TAG"
echo "  share stores   three PostgreSQL StatefulSets in this cluster (values-onprem.yaml)"
if [ -n "$REPORTING_SECRET" ]; then echo "  billing        Google Cloud Marketplace, reporting Secret $REPORTING_SECRET (from $KEY_FILE)"
elif [ -n "$LICENSE_KEY_FILE" ]; then echo "  licence        token from $LICENSE_KEY_FILE (no metering)"
else echo "  licence        ${Y}14-day evaluation${N} (no KEY_FILE, no token)"; fi
echo "  image pull     Secret $PULL_SECRET$([ -n "$KEY_FILE" ] && echo ' (created from the reporting key)')"
echo
if [ "$AUTO_APPROVE" != "true" ]; then read -r -p "Proceed? [y/N] " a; [ "${a:-}" = y ] || [ "${a:-}" = Y ] || exit 1; fi

step "namespace $NAMESPACE"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE" >/dev/null

if [ -n "$REPORTING_SECRET" ]; then
  step "usage-reporting Secret $REPORTING_SECRET"
  kubectl -n "$NAMESPACE" apply -f "$KEY_FILE" >/dev/null
  KEY_B64="$(kubectl -n "$NAMESPACE" get secret "$REPORTING_SECRET" -o jsonpath='{.data.reporting-key}')"
  [ -n "$KEY_B64" ] || die "Secret $REPORTING_SECRET has no 'reporting-key' entry"
fi

if kubectl -n "$NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1; then
  step "image-pull Secret $PULL_SECRET already exists, keeping it"
elif [ -n "$REPORTING_SECRET" ]; then
  step "image-pull Secret $PULL_SECRET for $REGISTRY"
  kubectl -n "$NAMESPACE" create secret docker-registry "$PULL_SECRET" \
    --docker-server=marketplace.gcr.io --docker-username=_json_key \
    --docker-password="$(printf '%s' "$KEY_B64" | base64 -d)" --docker-email=unused@example.com >/dev/null
else
  die "no image-pull Secret '$PULL_SECRET' in $NAMESPACE and no KEY_FILE to create it from. Either pass KEY_FILE, or create it:
  kubectl -n $NAMESPACE create secret docker-registry $PULL_SECRET --docker-server=marketplace.gcr.io \\
    --docker-username=_json_key --docker-password=\"\$(cat key.json)\" --docker-email=unused@example.com"
fi

step "helm $( helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1 && echo upgrade || echo install ) $RELEASE"
ARGS=( upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$CHART/values-onprem.yaml"
  --set "imagePullSecrets={$PULL_SECRET}"
  --set "proxy.image.repo=$REGISTRY/proxy" --set "proxy.image.tag=$TAG"
  --set "cache.image=$REGISTRY/cache:$TAG" --set "bootstrap.image=$REGISTRY/cache:$TAG"
  --set "ubbagent.image=$REGISTRY/ubbagent:$TAG"
  --set "proxy.profile=$PROFILE"
  --set "cache.persistence.storageClass=$STORAGECLASS" --set "inclusterShares.persistence.storageClass=$STORAGECLASS" )
if [ -n "$REPORTING_SECRET" ]; then ARGS+=( --set "reportingSecret=$REPORTING_SECRET" --set ubbagent.enabled=true )
else ARGS+=( --set ubbagent.enabled=false ); fi
[ -z "$LICENSE_KEY_FILE" ] || ARGS+=( --set-file "license.key=$LICENSE_KEY_FILE" )
[ -z "$VALUES" ] || ARGS+=( -f "$VALUES" )
helm "${ARGS[@]}" --wait --timeout 15m >/dev/null

step "waiting for the proxy"
kubectl -n "$NAMESPACE" rollout status statefulset/"$RELEASE" --timeout=10m >/dev/null
PW="$(kubectl -n "$NAMESPACE" get secret "$RELEASE-shares" -o jsonpath='{.data.proxy}' 2>/dev/null | base64 -d || true)"

echo
printf "%b\n" "${G}${B}SecretSkyDB is running in $NAMESPACE.${N}"
echo "  in-cluster     host=$RELEASE.$NAMESPACE.svc port=55432 dbname=ssdb user=ssdb"
echo "  password       kubectl -n $NAMESPACE get secret $RELEASE-shares -o jsonpath='{.data.proxy}' | base64 -d"
echo "  from a laptop  kubectl -n $NAMESPACE port-forward svc/$RELEASE 55432:55432"
echo "                 PGPASSWORD='${PW:-<password>}' psql -h 127.0.0.1 -p 55432 -U ssdb -d ssdb"
echo "  licence/status kubectl -n $NAMESPACE port-forward pod/$RELEASE-0 55433:55433 &  curl -s http://127.0.0.1:55433/statusz"
if [ -n "$REPORTING_SECRET" ]; then echo "  billing        usage reports hourly to Google Cloud Marketplace; it appears on your GCP invoice within a day"; fi
echo "  remove         helm -n $NAMESPACE uninstall $RELEASE   (volumes are kept: kubectl -n $NAMESPACE delete pvc --all)"
