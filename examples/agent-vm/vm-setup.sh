#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
#
# Runs ON the VM (run.sh copies it there and starts it). Safe to run again: every step checks
# what is already in place.
#
#   1. single-node Kubernetes (k3s) and Helm
#   2. SecretSkyDB from the chart, with the reporting key of the Marketplace order
#   3. Ollama with the chat model and the embedding model
#   4. the agent's Python environment and its connection settings
#   5. sample data loaded through SecretSkyDB, then an end-to-end check
set -euo pipefail

ROOT="$HOME/ssdb-agent"
HERE="$ROOT/examples/agent-vm"
MODEL="${MODEL:-qwen2.5:7b}"
EMBED_MODEL="${EMBED_MODEL:-all-minilm}"
NAMESPACE="${NAMESPACE:-secretskydb}"
RELEASE="${RELEASE:-secretskydb}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export DEBIAN_FRONTEND=noninteractive

GPU="${GPU:-0}"

step(){ printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die(){ printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# `vm-setup.sh licence`: one line with the licence state of the running proxy, then leave
licence(){
  local ip; ip="$(kubectl -n "$NAMESPACE" get pod "$RELEASE-0" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  [ -n "$ip" ] || { echo "  FAIL  SecretSkyDB: the proxy pod is not running"; return 1; }
  curl -fsS --max-time 10 "http://$ip:55433/statusz" | python3 -c '
import json, sys
d = json.load(sys.stdin); lic = d.get("license") or {}
print("  ok    SecretSkyDB:", d.get("status"), "| licence:", lic.get("state", "?"), "-", lic.get("reason") or lic.get("source") or "")'
}
if [ "${1:-}" = "licence" ]; then licence; exit $?; fi

step "1/5 Kubernetes (k3s) and Helm"
if ! command -v k3s >/dev/null; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh - >/dev/null
fi
for _ in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break; sleep 3; done
kubectl get nodes | grep -q ' Ready ' || die "the Kubernetes node did not become Ready"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
fi

step "2/5 SecretSkyDB"
KEY="$ROOT/service-account-key.yaml"
if kubectl -n "$NAMESPACE" get statefulset "$RELEASE" >/dev/null 2>&1 && [ ! -s "$KEY" ]; then
  echo "already installed"
else
  [ -s "$KEY" ] || die "reporting key missing at $KEY"
  KEY_FILE="$KEY" AUTO_APPROVE=true NAMESPACE="$NAMESPACE" RELEASE="$RELEASE" bash "$ROOT/scripts/install-onprem.sh"
  # the key now lives in the cluster as a Secret; do not keep a second copy in the home directory
  shred -u "$KEY" 2>/dev/null || rm -f "$KEY"
fi

step "3/5 model server (Ollama): $MODEL and $EMBED_MODEL"
if ! command -v ollama >/dev/null; then
  # on a VM with an NVIDIA GPU the Ollama installer also installs the driver
  curl -fsSL https://ollama.com/install.sh | sh >"$ROOT/ollama-install.log" 2>&1 || die "Ollama install failed, see $ROOT/ollama-install.log"
fi
if [ "$GPU" = "1" ]; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null \
    || die "GPU=1 but the NVIDIA driver is not working (nvidia-smi failed). See $ROOT/ollama-install.log"
fi
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:11434/api/version >/dev/null || die "Ollama did not start"
ollama pull "$MODEL" >/dev/null 2>&1 || die "could not pull model $MODEL"
ollama pull "$EMBED_MODEL" >/dev/null 2>&1 || die "could not pull model $EMBED_MODEL"

step "4/5 agent environment"
if [ ! -x "$ROOT/venv/bin/python" ]; then
  sudo apt-get update -qq >/dev/null
  sudo apt-get install -y -qq python3-venv >/dev/null
  python3 -m venv "$ROOT/venv"
  "$ROOT/venv/bin/pip" install -q psycopg2-binary requests
fi
# The agent runs on the node itself, so it reaches the proxy on the Service's cluster address.
SSDB_HOST="$(kubectl -n "$NAMESPACE" get svc "$RELEASE" -o jsonpath='{.spec.clusterIP}')"
SSDB_PASSWORD="$(kubectl -n "$NAMESPACE" get secret "$RELEASE-shares" -o jsonpath='{.data.proxy}' | base64 -d)"
[ -n "$SSDB_HOST" ] && [ -n "$SSDB_PASSWORD" ] || die "could not read the proxy address or password from the cluster"
umask 077
cat > "$ROOT/agent.env" <<EOF
SSDB_HOST=$SSDB_HOST
SSDB_PORT=55432
SSDB_DB=ssdb
SSDB_USER=ssdb
SSDB_PASSWORD=$SSDB_PASSWORD
OLLAMA_URL=http://127.0.0.1:11434
MODEL=$MODEL
EMBED_MODEL=$EMBED_MODEL
EOF

step "5/5 sample data and end-to-end check"
"$ROOT/venv/bin/python" "$HERE/agent.py" seed
licence
"$ROOT/venv/bin/python" "$HERE/agent.py" check
