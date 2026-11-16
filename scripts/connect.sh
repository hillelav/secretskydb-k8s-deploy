#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# This script is licensed under the Apache License, Version 2.0. The SecretSkyDB
# Software it connects to is proprietary and governed by the SecretSkyDB End User License
# Agreement (https://www.secretskydb.com/eula). Contact: support@secretskydb.com
#
# SecretSkyDB — connect from your own machine to an install on GKE.
#
# 1. Checks the tools this machine needs (gcloud, the GKE auth plugin, kubectl, psql) and
#    stops with the exact fix when one is missing. It installs nothing and changes nothing
#    on this machine except the kubectl context that `gcloud ... get-credentials` writes.
# 2. Fetches the cluster credentials, shows the pods, prints the proxy password and opens a
#    port-forward to the proxy on 127.0.0.1:55432 (Ctrl-C closes it).
#
# Usage:
#   ./scripts/connect.sh CLUSTER LOCATION          # LOCATION = region or zone of the cluster
#   curl -fsSL https://storage.googleapis.com/secretskydb-downloads/connect.sh | bash -s -- CLUSTER LOCATION
#   ./scripts/connect.sh --check                   # only check the tools
#
# Optional environment:
#   PROJECT_ID   project of the cluster            (default: the gcloud project)
#   NAMESPACE    namespace of the install          (default: secretskydb)
#   APP          application / release name        (default: secretskydb)
#   LOCAL_PORT   local port for the proxy          (default: 55432)
set -euo pipefail

NAMESPACE="${NAMESPACE:-secretskydb}"
APP="${APP:-secretskydb}"
LOCAL_PORT="${LOCAL_PORT:-55432}"
PROXY_PORT=55432

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok       %s\n' "$*"; }
miss() { printf '  MISSING  %s\n' "$*"; }
die()  { printf '\n%s\n' "$*" >&2; exit 1; }

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '8,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
  exit 0
fi
CLUSTER="${1:-}"
LOCATION="${2:-}"
if [ "$CHECK_ONLY" = 0 ] && { [ -z "$CLUSTER" ] || [ -z "$LOCATION" ]; }; then
  die "Usage: connect.sh CLUSTER LOCATION   (LOCATION = the cluster's region or zone, e.g. us-central1)
       connect.sh --check             (only check the tools on this machine)"
fi

# ---------------------------------------------------------------- 1. tools
say "Checking the tools on this machine"
problems=0
is_linux=0; [ "$(uname -s)" = "Linux" ] && is_linux=1

gcloud_path="$(command -v gcloud || true)"
gcloud_real=""
gcloud_snap=0
if [ -n "$gcloud_path" ]; then
  gcloud_real="$(readlink -f "$gcloud_path" 2>/dev/null || echo "$gcloud_path")"
  case "$gcloud_path $gcloud_real" in *"/snap/"*) gcloud_snap=1 ;; esac
fi
gcloud_apt=0
if [ "$is_linux" = 1 ] && command -v dpkg >/dev/null 2>&1 && dpkg -s google-cloud-cli >/dev/null 2>&1; then
  gcloud_apt=1
fi

apt_fix() {
  cat <<'EOF'

    sudo snap remove google-cloud-cli
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    sudo apt-get update && sudo apt-get install -y google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin kubectl

  Then open a NEW terminal (the old one still looks for /snap/bin/gcloud), run
  `gcloud auth login`, and run this script again.
EOF
}

if [ -z "$gcloud_path" ]; then
  miss "gcloud — install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install"
  problems=$((problems + 1))
elif [ "$gcloud_snap" = 1 ]; then
  miss "gcloud is the snap package ($gcloud_path). It has no GKE auth plugin and cannot add one,"
  say  "           so kubectl cannot sign in to the cluster. Replace it with Google's apt packages:"
  apt_fix
  problems=$((problems + 1))
else
  ok "gcloud ($gcloud_path)"
fi

if [ "$gcloud_snap" = 0 ] && [ -n "$gcloud_path" ]; then
  # The plugin is either on PATH (apt package) or in the SDK's own bin directory (gcloud
  # component), which need not be on PATH: get-credentials writes its full path for kubectl.
  sdk_root="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || true)"
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1 \
     || [ -x "$(dirname "$gcloud_real")/gke-gcloud-auth-plugin" ] \
     || { [ -n "$sdk_root" ] && [ -x "$sdk_root/bin/gke-gcloud-auth-plugin" ]; }; then
    ok "gke-gcloud-auth-plugin"
  else
    if [ "$gcloud_apt" = 1 ]; then
      miss "gke-gcloud-auth-plugin — sudo apt-get install -y google-cloud-cli-gke-gcloud-auth-plugin"
    else
      miss "gke-gcloud-auth-plugin — gcloud components install gke-gcloud-auth-plugin"
    fi
    problems=$((problems + 1))
  fi
fi

if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl"
else
  if [ "$gcloud_apt" = 1 ]; then
    miss "kubectl — sudo apt-get install -y kubectl"
  else
    miss "kubectl — gcloud components install kubectl"
  fi
  problems=$((problems + 1))
fi

if command -v psql >/dev/null 2>&1; then
  ok "psql"
else
  say "  note     psql not found — any PostgreSQL client works; the connection details are printed below"
fi

if [ "$problems" -gt 0 ]; then
  die "Fix the item(s) marked MISSING and run this script again.
No local tools at all? Cloud Shell has everything preinstalled: https://shell.cloud.google.com"
fi

account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
if [ -z "$account" ]; then
  die "gcloud is not signed in. Run:  gcloud auth login   and then this script again."
fi
ok "signed in as $account"

if [ "$CHECK_ONLY" = 1 ]; then
  say ""
  say "All tools are in place."
  exit 0
fi

# ---------------------------------------------------------------- 2. connect
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "(unset)" ] \
  || die "No project. Run:  gcloud config set project YOUR_PROJECT   or set PROJECT_ID=..."

say ""
say "Fetching credentials for cluster $CLUSTER ($LOCATION, project $PROJECT_ID)"
gcloud container clusters get-credentials "$CLUSTER" --location "$LOCATION" --project "$PROJECT_ID" \
  || die "Could not get the cluster credentials. Check the cluster name and its region or zone:
  gcloud container clusters list --project $PROJECT_ID"

say ""
say "Pods in namespace $NAMESPACE"
kubectl -n "$NAMESPACE" get pods \
  || die "kubectl could not reach the cluster. If the message above mentions gke-gcloud-auth-plugin,
run:  $0 --check"

password=""
for secret in "$APP-shares" "secretskydb-alloydb-shares"; do
  b64="$(kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath='{.data.proxy}' 2>/dev/null || true)"
  if [ -n "$b64" ]; then
    password="$(printf '%s' "$b64" | base64 --decode)"
    break
  fi
done
[ -n "$password" ] \
  || die "No proxy password found: neither Secret $APP-shares nor secretskydb-alloydb-shares has a 'proxy' key
in namespace $NAMESPACE. Is the application deployed there, and are NAMESPACE / APP right?"

say ""
say "SecretSkyDB is a PostgreSQL server. While this window stays open, connect with:"
say ""
say "  host 127.0.0.1   port $LOCAL_PORT   database ssdb   user ssdb"
say "  password: $password"
say ""
say "  psql \"host=127.0.0.1 port=$LOCAL_PORT user=ssdb dbname=ssdb\""
say ""
say "Opening the port-forward (Ctrl-C to close)"
exec kubectl -n "$NAMESPACE" port-forward "svc/$APP" "$LOCAL_PORT:$PROXY_PORT"
