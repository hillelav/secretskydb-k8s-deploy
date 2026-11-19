#!/bin/bash
# Start (or restart) the DiamondClaw web demo on the agent VM.
# It listens on 127.0.0.1:8077; reach it through an SSH tunnel:
#   gcloud compute ssh ssdb-agent --zone <zone> -- -N -L 8077:localhost:8077
set -e
cd ~/ssdb-agent
[ -f dc-only.tgz ] && tar -xzf dc-only.tgz -C examples && rm dc-only.tgz
pkill -f webdemo.py 2>/dev/null || true
pkill -f "dashtool/dashboard.py" 2>/dev/null || true
sleep 1
. ./mcp-token.env
AGENT_ENV=$HOME/ssdb-agent/agent.env nohup venv/bin/python examples/diamondclaw/webdemo.py \
  --mcp-url "$MCP_URL" --mcp-token "$SSDB_MCP_TOKEN" --port 8077 --no-seed > webdemo.log 2>&1 &
sleep 12
tail -2 webdemo.log
