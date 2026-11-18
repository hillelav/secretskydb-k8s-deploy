#!/usr/bin/env bash
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
#
# The first real end-to-end run of DiamondClaw on the examples/agent-vm GPU VM. Run from a laptop
# after `GPU=1 ./examples/agent-vm/run.sh up` has finished (SecretSkyDB, Ollama and the demo data
# are on the VM). Stages, each resumable:
#
#   proxy     build the proxy image of the given marketplace checkout ON the VM (0.4.1 + MCP server;
#             the Marketplace mirror serves only published versions) and switch the release to it,
#             with mcp.enabled: a tokens Secret and the audit Secret from the agent's users
#   install   run diamondclaw-install.sh on the VM: Hermes Agent + gpt-oss-20b on Ollama, against
#             the cluster's MCP endpoint (remote mode) — the agent's writer user is the token's user
#   bench     the eleven questions through the MCP server with the built-in loop, for each model
#   hermes    the eleven questions through `hermes chat -q`
#   all       proxy install bench hermes
#
#   MARKETPLACE=../secretskydb-gcp-marketplace   checkout with proxy/ (branch mcp-0.5)
#   MODELS="gpt-oss:20b qwen2.5:14b"             bench models (pulled on the VM if missing)
#   INSTALL_MODEL=gpt-oss-20b                    the installer's --model
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTVM="$HERE/../agent-vm"
MARKETPLACE="${MARKETPLACE:-$HERE/../../../secretskydb-gcp-marketplace}"
MODELS="${MODELS:-gpt-oss:20b qwen2.5:14b}"
INSTALL_MODEL="${INSTALL_MODEL:-gpt-oss-20b}"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
ZONE="${ZONE:-$(cat "$AGENTVM/.zone" 2>/dev/null || echo us-central1-a)}"
VM="${VM:-ssdb-agent}"
SSH_FLAGS="${SSH_FLAGS:-}"
R=ssdb-agent                      # remote dir of run.sh

B=$'\e[1m'; G=$'\e[32m'; N=$'\e[0m'
step(){ printf "%b\n" "${B}▸ $*${N}"; }
die(){ printf "%b\n" "\e[31m✗ $*${N}" >&2; exit 1; }
# shellcheck disable=SC2086
vssh(){ gcloud compute --project "$PROJECT" ssh "$VM" --zone "$ZONE" $SSH_FLAGS --command "$*"; }
# shellcheck disable=SC2086
vscp(){ gcloud compute --project "$PROJECT" scp --zone "$ZONE" $SSH_FLAGS "$@"; }

gcloud auth print-access-token >/dev/null 2>&1 || die "gcloud is not logged in: gcloud auth login"
[ "$(gcloud compute --project "$PROJECT" instances describe "$VM" --zone "$ZONE" --format='value(status)' 2>/dev/null)" = RUNNING ] \
  || die "VM $VM is not running in $PROJECT/$ZONE: GPU=1 $AGENTVM/run.sh up"

stage_proxy(){
  [ -d "$MARKETPLACE/proxy/ssdb/sql/mcp" ] || die "no MCP server in $MARKETPLACE/proxy/ssdb (checkout branch mcp-0.5 and run scripts/sync-from-ssdb.sh)"
  step "proxy: shipping the build context"
  local tmp; tmp="$(mktemp -d)"
  COPYFILE_DISABLE=1 tar -C "$MARKETPLACE" --exclude '._*' --exclude '__pycache__' -czf "$tmp/proxyctx.tgz" proxy
  COPYFILE_DISABLE=1 tar -C "$MARKETPLACE" --exclude '._*' -czf "$tmp/chart.tgz" chart
  vssh "mkdir -p $R/proxybuild"
  vscp "$tmp/proxyctx.tgz" "$tmp/chart.tgz" "$VM:$R/proxybuild/" >/dev/null
  rm -rf "$tmp"
  step "proxy: building on the VM (podman), loading into k3s, switching the release with mcp.enabled (10-15 min)"
  vssh "bash -s" <<'REMOTE'
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml DEBIAN_FRONTEND=noninteractive
R=$HOME/ssdb-agent; cd $R/proxybuild
command -v podman >/dev/null || { sudo apt-get update -qq >/dev/null; sudo apt-get install -y -qq podman >/dev/null 2>&1; }
tar -xzf proxyctx.tgz; rm -rf chart; tar -xzf chart.tgz
IMG=localhost/ssdb-proxy:0.5-dev
sudo podman build --network host -t "$IMG" proxy/ > build.log 2>&1 || { tail -40 build.log; exit 1; }
grep -E "fast_gf ok|relay_fast ok|compiled upsert ok|mcp server ok" build.log
sudo podman save "$IMG" -o proxy.tar && sudo k3s ctr images import proxy.tar | tail -1
# tokens: one per agent, bound to the agent's writer user; audit: the insert-only user
. $R/agent-users.env
TOK=$(openssl rand -hex 32); echo "SSDB_MCP_TOKEN=$TOK" > $R/mcp-token.env; chmod 600 $R/mcp-token.env
kubectl -n secretskydb create secret generic ssdb-mcp-tokens --from-literal=tokens.json="{\"tokens\":[{\"id\":\"hermes-1\",\"token\":\"$TOK\",\"user\":\"$SSDB_WRITER_USER\",\"password\":\"$SSDB_WRITER_PASSWORD\"}]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n secretskydb create secret generic ssdb-mcp-audit --from-literal=user="$SSDB_AUDIT_USER" --from-literal=password="$SSDB_AUDIT_PASSWORD" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm -n secretskydb upgrade secretskydb ./chart/secretskydb --reuse-values \
  --set proxy.image.repo=localhost/ssdb-proxy --set proxy.image.tag=0.5-dev --set imagePullPolicy=IfNotPresent \
  --set mcp.enabled=true --set mcp.tokensSecret=ssdb-mcp-tokens --set mcp.auditSecret=ssdb-mcp-audit \
  --set mcp.embed.url=http://$(hostname -I | awk '{print $1}'):11434 --set mcp.embed.model=all-minilm \
  --wait --timeout 15m >/dev/null
kubectl -n secretskydb rollout status statefulset secretskydb --timeout=10m
kubectl -n secretskydb get pod secretskydb-0 -o jsonpath='{range .spec.containers[*]}{.name}{" "}{.image}{"\n"}{end}'
IP=$(kubectl -n secretskydb get svc secretskydb -o jsonpath='{.spec.clusterIP}')
echo "MCP_URL=http://$IP:55440/mcp" >> $R/mcp-token.env
curl -s -o /dev/null -w "mcp endpoint answers HTTP %{http_code} without a token (401 expected)\n" "http://$IP:55440/mcp"
rm -rf proxy proxy.tar proxyctx.tgz
echo PROXY_DONE
REMOTE
}

stage_install(){
  step "install: copying the DiamondClaw example and running the installer on the VM (remote MCP mode)"
  local tmp; tmp="$(mktemp -d)"
  COPYFILE_DISABLE=1 tar -C "$HERE/.." --exclude '._*' --exclude '__pycache__' -czf "$tmp/dc.tgz" diamondclaw agent-vm
  vscp "$tmp/dc.tgz" "$VM:$R/dc.tgz" >/dev/null; rm -rf "$tmp"
  vssh "cd $R && tar -xzf dc.tgz -C examples --strip-components=0 && rm dc.tgz && . $R/mcp-token.env && \
    SSDB_MCP_TOKEN=\$SSDB_MCP_TOKEN bash examples/diamondclaw/diamondclaw-install.sh --customer us-gov --agent hermes \
    --model $INSTALL_MODEL --serving ollama --connect mcp --mcp-url \$MCP_URL --agent-id hermes-1 --yes"
}

stage_bench(){
  step "bench: the eleven questions through the MCP server, models: $MODELS"
  vssh "cd $R && for m in $MODELS; do ollama pull \$m >/dev/null 2>&1 || true; done; \
    [ -x venv/bin/python ] || python3 -m venv venv; venv/bin/pip install -q 'mcp>=1.2,<2' 'psycopg[binary]' psycopg2-binary requests pyyaml; \
    . $R/mcp-token.env && AGENT_ENV=$R/agent.env venv/bin/python examples/diamondclaw/bench.py --mcp-url \$MCP_URL --mcp-token \$SSDB_MCP_TOKEN \
    $(for m in $MODELS; do printf -- '--model %s ' "$m"; done) --out $R/bench-mcp.json"
}

stage_hermes(){
  step "hermes: the eleven questions through hermes chat -q"
  vssh "cd $R && export PATH=\$HOME/.local/bin:\$PATH && AGENT_ENV=$R/agent.env venv/bin/python examples/diamondclaw/bench.py --hermes --out $R/bench-hermes.json"
}

case "${1:-all}" in
  proxy) stage_proxy ;;
  install) stage_install ;;
  bench) stage_bench ;;
  hermes) stage_hermes ;;
  all) stage_proxy; stage_install; stage_bench; stage_hermes ;;
  *) sed -n '8,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
printf "%b\n" "${G}done: ${1:-all}${N}"
