#!/bin/bash
# Start (or restart) the DiamondClaw web demo on the agent VM, with the
# dashboard's direct store connections gathered from the cluster.
set -e
cd ~/ssdb-agent
[ -f dc-only.tgz ] && tar -xzf dc-only.tgz -C examples && rm dc-only.tgz
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS=secretskydb
POD_IP=$(kubectl -n $NS get pod secretskydb-0 -o jsonpath='{.status.podIP}')
sec(){ kubectl -n $NS get secret secretskydb-shares -o jsonpath="{.data.$1}" | base64 -d; }
svc(){ kubectl -n $NS get svc secretskydb-$1 -o jsonpath='{.spec.clusterIP}'; }
python3 - "$POD_IP" "$(sec cache)" "$(svc share-a)" "$(sec share-a)" "$(svc share-b)" "$(sec share-b)" "$(svc share-c)" "$(sec share-c)" <<'PY' > dash.json
import json, sys
pod, cpw, ah, apw, bh, bpw, ch, cpw3 = sys.argv[1:9]
json.dump([
  {"name": "Cache",   "host": pod, "port": 5432, "db": "ssdb", "user": "ssdb_cache", "pw": cpw},
  {"name": "Share A", "host": ah,  "port": 5432, "db": "ssdb", "user": "postgres",   "pw": apw},
  {"name": "Share B", "host": bh,  "port": 5432, "db": "ssdb", "user": "postgres",   "pw": bpw},
  {"name": "Share C", "host": ch,  "port": 5432, "db": "ssdb", "user": "postgres",   "pw": cpw3},
], sys.stdout)
PY
chmod 600 dash.json
pkill -f webdemo.py 2>/dev/null || true
sleep 1
. ./mcp-token.env
SSDB_DASH_FILE=$HOME/ssdb-agent/dash.json AGENT_ENV=$HOME/ssdb-agent/agent.env \
  nohup venv/bin/python examples/diamondclaw/webdemo.py \
  --mcp-url "$MCP_URL" --mcp-token "$SSDB_MCP_TOKEN" --port 8077 --no-seed > webdemo.log 2>&1 &
sleep 12
tail -3 webdemo.log
