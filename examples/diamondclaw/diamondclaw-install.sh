#!/usr/bin/env bash
# diamondclaw-install.sh
# Unattended installer for ONE complete combination:
#
#   agent    Hermes Agent (Nous Research, MIT)
#   model    gpt-oss-20b or gpt-oss-120b (OpenAI, Apache 2.0), served by Ollama on this machine
#   link     the SecretSkyDB MCP server (typed tools: describe, lookup, aggregate, search, write,
#            unit_of_work) run locally over stdio against the proxy, OR a remote endpoint when the
#            cluster runs the server (--mcp-url https://host:55440/mcp --mcp-token …, chart mcp.enabled)
#
# It accepts the flags the DiamondClaw Installer Selector prints, and stops with a clear
# message for any choice that is not implemented yet.
#
#   SSDB_PASSWORD=... ./diamondclaw-install.sh \
#       --customer us-gov --agent hermes --model gpt-oss-20b \
#       --serving ollama --connect mcp --ssdb 127.0.0.1:55432 \
#       --db postgres --user postgres --yes
#
#   --mcp-url URL --mcp-token TOKEN   use the cluster's MCP server instead of a local one
#   --agent-id NAME     how the audit trail names this agent (default: the login user)
#   --audit-user U --audit-password P   the insert-only proxy user that writes agent_audit (optional)
#   --embed-model NAME  the Ollama embedding model `search` uses (default all-minilm)
#   --dry-run   print every step, change nothing
#   --yes       do not ask before running the Ollama and Hermes installers
#
# It does NOT install SecretSkyDB. The proxy must already be listening.
# Linux, macOS, or Windows WSL2. Needs curl and Python 3.10+ with the venv module.

set -uo pipefail

CUSTOMER="us-gov"; AGENT="hermes"; MODEL_ID="gpt-oss-20b"; SERVING="ollama"; CONNECT="mcp"
SSDB_ADDR="127.0.0.1:55432"; SSDB_DB="postgres"; SSDB_USER="postgres"
GUARDRAILS=""; AIRGAP=0; DRY=0; YES=0
MCP_URL=""; MCP_TOKEN="${SSDB_MCP_TOKEN:-}"; AGENT_ID="${AGENT_ID:-$(id -un 2>/dev/null || echo agent)}"
AUDIT_USER=""; AUDIT_PASSWORD="${SSDB_AUDIT_PASSWORD:-}"; EMBED_MODEL="all-minilm"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_URL="https://raw.githubusercontent.com/hillelav/secretskydb-k8s-deploy/main/examples/diamondclaw/ssdb_mcp_server.py"
OLLAMA_URL="http://127.0.0.1:11434"
HOME_DIR="${DIAMONDCLAW_HOME:-$HOME/.diamondclaw}"
HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
CTX=64000                      # Hermes Agent needs a model served with at least 64,000 tokens of context

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
say(){ printf '%s\n' "$*"; }
step(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
ok(){ printf '%s[ok]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!]%s  %s\n' "$Y" "$N" "$*"; }
die(){ printf '%s[x]%s  %s\n' "$R" "$N" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
run(){ say "  \$ $*"; [ "$DRY" -eq 1 ] && return 0; "$@"; }

# ---------------- flags ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --customer) CUSTOMER="${2:-}"; shift 2 ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
    --model) MODEL_ID="${2:-}"; shift 2 ;;
    --serving) SERVING="${2:-}"; shift 2 ;;
    --connect) CONNECT="${2:-}"; shift 2 ;;
    --ssdb) SSDB_ADDR="${2:-}"; shift 2 ;;
    --db) SSDB_DB="${2:-}"; shift 2 ;;
    --user) SSDB_USER="${2:-}"; shift 2 ;;
    --guardrails) GUARDRAILS="${2:-}"; shift 2 ;;
    --air-gapped) AIRGAP=1; shift ;;
    --bundle) shift 2 ;;
    --mcp-url) MCP_URL="${2:-}"; shift 2 ;;
    --mcp-token) MCP_TOKEN="${2:-}"; shift 2 ;;
    --agent-id) AGENT_ID="${2:-}"; shift 2 ;;
    --audit-user) AUDIT_USER="${2:-}"; shift 2 ;;
    --audit-password) AUDIT_PASSWORD="${2:-}"; shift 2 ;;
    --embed-model) EMBED_MODEL="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

not_yet(){ die "$1 is not implemented in this installer yet. Implemented today: --agent hermes --serving ollama --connect mcp --model gpt-oss-20b | gpt-oss-120b | qwen2.5-14b."; }
[ "$AGENT" = "hermes" ]   || not_yet "Agent '$AGENT'"
[ "$SERVING" = "ollama" ] || not_yet "Serving with '$SERVING'"
[ "$CONNECT" = "mcp" ]    || not_yet "Connection '$CONNECT'"
[ -z "$GUARDRAILS" ]      || not_yet "Guardrails"
[ "$AIRGAP" -eq 0 ]       || not_yet "Air-gapped installation (it needs an offline bundle)"
case "$MODEL_ID" in
  gpt-oss-20b)  OLLAMA_TAG="gpt-oss:20b";  NEED_GB=24 ;;
  gpt-oss-120b) OLLAMA_TAG="gpt-oss:120b"; NEED_GB=80 ;;
  qwen2.5-14b)  OLLAMA_TAG="qwen2.5:14b";  NEED_GB=16
                [ "$CUSTOMER" = "us-gov" ] && die "qwen2.5-14b is a Chinese-origin model and is not offered with --customer us-gov." ;;
  *) not_yet "Model '$MODEL_ID'" ;;
esac
case "$CUSTOMER" in us-gov|eu|other) ;; *) die "--customer must be us-gov, eu or other." ;; esac
case "$SSDB_ADDR" in *:*) SSDB_HOST="${SSDB_ADDR%:*}"; SSDB_PORT="${SSDB_ADDR##*:}" ;; *) die "--ssdb must be host:port" ;; esac
case "$SSDB_PORT" in ''|*[!0-9]*) die "--ssdb port must be a number" ;; esac
REMOTE_MCP=0
if [ -n "$MCP_URL" ]; then
  case "$MCP_URL" in https://*|http://127.0.0.1*|http://localhost*) ;; *) die "--mcp-url must be https:// (or a loopback http:// address)" ;; esac
  [ -n "$MCP_TOKEN" ] || die "--mcp-url needs --mcp-token (or SSDB_MCP_TOKEN in the environment)"
  REMOTE_MCP=1
fi
LOCAL_MODEL="diamondclaw-${MODEL_ID}"

confirm_installer(){   # confirm_installer "Name" "command shown"
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || die "$1 is not installed. Re-run with --yes to allow its official installer to run."
  printf 'Run the official %s installer now?\n  %s\n[y/N]: ' "$1" "$2"
  local a; IFS= read -r a || a=""
  case "$a" in y|Y|yes) return 0 ;; *) die "Stopped: $1 is required." ;; esac
}
fetch_and_run(){       # fetch_and_run URL interpreter [args...]
  local url="$1" interp="$2"; shift 2
  say "  \$ curl -fsSL $url | $interp $*"
  [ "$DRY" -eq 1 ] && return 0
  local tmp; tmp="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp" || { rm -f "$tmp"; die "Download failed: $url"; }
  "$interp" "$tmp" "$@"; local rc=$?; rm -f "$tmp"; return $rc
}

# ---------------- 1. this machine ----------------
step "1 of 6  This machine"
OS="$(uname -s)"
case "$OS" in
  Linux)  RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0) ;;
  Darwin) RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) ;;
  *) die "Unsupported system: $OS. Use Linux, macOS or WSL2." ;;
esac
VRAM_GB=0
if have nvidia-smi; then
  V=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')
  case "${V:-}" in ''|*[!0-9]*) ;; *) VRAM_GB=$V ;; esac
fi
say "System $OS, memory ${RAM_GB} GB, NVIDIA GPU memory ${VRAM_GB} GB"
have curl || die "curl is required."
PY=""
for c in python3.13 python3.12 python3.11 python3.10 python3; do
  if have "$c" && "$c" -c 'import sys,venv; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || die "Python 3.10+ with the venv module is required (Debian/Ubuntu: sudo apt install python3-venv)."
ok "Using $($PY --version 2>&1)"
AVAIL=$RAM_GB; [ "$VRAM_GB" -gt "$AVAIL" ] && AVAIL=$VRAM_GB
[ "$AVAIL" -lt "$NEED_GB" ] && warn "$MODEL_ID with a 64K context wants about ${NEED_GB} GB; this machine shows ${AVAIL} GB. It may be slow or fail to load."
[ "$DRY" -eq 1 ] && warn "Dry run: nothing is installed or changed."

# ---------------- 2. SecretSkyDB proxy ----------------
if [ "$REMOTE_MCP" -eq 1 ]; then
  step "2 of 6  SecretSkyDB MCP endpoint $MCP_URL"
  ok "The cluster runs the MCP server; this machine only needs the agent and the model."
else
step "2 of 6  SecretSkyDB proxy at $SSDB_ADDR"
if ( exec 3<>"/dev/tcp/$SSDB_HOST/$SSDB_PORT" ) >/dev/null 2>&1; then ok "Port is open."
elif [ "$DRY" -eq 1 ]; then warn "Nothing is listening on $SSDB_ADDR (ignored in a dry run)."
else die "Nothing is listening on $SSDB_ADDR. Start the SecretSkyDB proxy (or its port-forward) and run again."; fi
if [ -z "${SSDB_PASSWORD:-}" ] && [ "$DRY" -eq 0 ]; then
  [ -t 0 ] || die "Set SSDB_PASSWORD in the environment for an unattended run."
  printf 'Password for database user %s: ' "$SSDB_USER"
  stty -echo 2>/dev/null; IFS= read -r SSDB_PASSWORD || SSDB_PASSWORD=""; stty echo 2>/dev/null; say ""
fi
fi

# ---------------- 3. SecretSkyDB MCP server ----------------
VENV="$HOME_DIR/venv"; SERVER="$HOME_DIR/ssdb_mcp_server.py"; ENVFILE="$HOME_DIR/ssdb.env"
if [ "$REMOTE_MCP" -eq 1 ]; then
  step "3 of 6  SecretSkyDB MCP server: remote ($MCP_URL)"
  [ "$DRY" -eq 1 ] || { mkdir -p "$HOME_DIR" && chmod 700 "$HOME_DIR"; }
  ok "Nothing to install here; the token is registered with the agent in step 5."
else
step "3 of 6  SecretSkyDB MCP server (local, stdio)"
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$HOME_DIR" && chmod 700 "$HOME_DIR" || die "Cannot create $HOME_DIR"
  [ -x "$VENV/bin/python" ] || "$PY" -m venv "$VENV" || die "Could not create the Python environment."
  "$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1
  "$VENV/bin/python" -m pip install --quiet "mcp>=1.2,<2" "psycopg[binary]>=3.1" "requests>=2.31" "pyyaml>=6" || die "Could not install the MCP server's Python packages."
  umask 077
  {
    printf 'SSDB_HOST=%s\nSSDB_PORT=%s\nSSDB_DB=%s\nSSDB_USER=%s\n' "$SSDB_HOST" "$SSDB_PORT" "$SSDB_DB" "$SSDB_USER"
    printf 'SSDB_PASSWORD=%s\n' "$SSDB_PASSWORD"
    printf 'SSDB_MCP_AGENT_ID=%s\nSSDB_EMBED_URL=%s\nSSDB_EMBED_MODEL=%s\n' "$AGENT_ID" "$OLLAMA_URL" "$EMBED_MODEL"
    [ -z "$AUDIT_USER" ] || printf 'SSDB_AUDIT_USER=%s\nSSDB_AUDIT_PASSWORD=%s\n' "$AUDIT_USER" "$AUDIT_PASSWORD"
  } > "$ENVFILE"
  chmod 600 "$ENVFILE"
  # The server: the copy next to this script, or the published copy (same file as sql/mcp in the proxy image).
  if [ -s "$HERE/ssdb_mcp_server.py" ]; then cp "$HERE/ssdb_mcp_server.py" "$SERVER"
  else
    say "  \$ curl -fsSL $SERVER_URL"
    curl -fsSL --proto '=https' --tlsv1.2 "$SERVER_URL" -o "$SERVER" || die "Could not download the MCP server."
  fi
  grep -q "SecretSkyDB MCP server" "$SERVER" || die "$SERVER is not the SecretSkyDB MCP server (download damaged?)"
  chmod 600 "$SERVER"
  ok "Server at $SERVER"
  say "Testing the connection through the proxy:"
  SSDB_ENV_FILE="$ENVFILE" "$VENV/bin/python" "$SERVER" --selftest || die "The MCP server could not query the proxy. Check the address, database, user and password."
else
  say "  (dry run) would create $VENV, install mcp + psycopg, copy the server to $SERVER, write $ENVFILE and test SELECT 1"
fi
fi

# ---------------- 4. Ollama and the model ----------------
step "4 of 6  Model $MODEL_ID on Ollama"
if have ollama; then ok "Ollama is installed."
else
  if [ "$OS" = "Linux" ]; then
    confirm_installer "Ollama" "curl -fsSL https://ollama.com/install.sh | sh"
    fetch_and_run "https://ollama.com/install.sh" sh || die "Ollama installation failed."
  elif have brew; then run brew install ollama || die "Ollama installation failed."
  else die "Install Ollama from https://ollama.com/download and run again."; fi
fi
if [ "$DRY" -eq 0 ] && ! curl -fsS "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  say "Starting the Ollama service..."
  ( OLLAMA_CONTEXT_LENGTH=$CTX nohup ollama serve >"${TMPDIR:-/tmp}/ollama-serve.log" 2>&1 & )
  i=0; while [ $i -lt 30 ] && ! curl -fsS "$OLLAMA_URL/api/tags" >/dev/null 2>&1; do sleep 1; i=$((i+1)); done
  curl -fsS "$OLLAMA_URL/api/tags" >/dev/null 2>&1 || die "Ollama did not start on $OLLAMA_URL."
fi
run ollama pull "$OLLAMA_TAG" || die "Could not download $OLLAMA_TAG."
[ "$REMOTE_MCP" -eq 1 ] || run ollama pull "$EMBED_MODEL" || die "Could not download the embedding model $EMBED_MODEL."
# A copy of the model with a 64K context window, which Hermes Agent requires.
if [ "$DRY" -eq 0 ]; then
  MF="$HOME_DIR/Modelfile"
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$OLLAMA_TAG" "$CTX" > "$MF"
fi
run ollama create "$LOCAL_MODEL" -f "$HOME_DIR/Modelfile" || die "Could not create the 64K-context model."
ok "Model ready as $LOCAL_MODEL"

# ---------------- 5. Hermes Agent ----------------
step "5 of 6  Hermes Agent"
export PATH="$HOME/.local/bin:$PATH"
if have hermes; then ok "Hermes Agent is installed."
else
  confirm_installer "Hermes Agent" "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use"
  fetch_and_run "https://hermes-agent.nousresearch.com/install.sh" bash --non-interactive --skip-browser --skip-computer-use || die "Hermes Agent installation failed."
  hash -r
  { have hermes || [ "$DRY" -eq 1 ]; } || die "Hermes installed but 'hermes' is not on PATH. Open a new terminal and run this script again."
fi
run hermes config set model.provider custom
run hermes config set model.base_url "$OLLAMA_URL/v1"
run hermes config set model.default "$LOCAL_MODEL"
run hermes config set model.context_length "$CTX" || warn "Could not set the context length in Hermes; it will auto-detect."

# Register the MCP server in Hermes's config.yaml (a backup is kept beside it).
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$HERMES_DIR"
  CFG="$HERMES_DIR/config.yaml"
  [ -f "$CFG" ] && cp "$CFG" "$CFG.before-diamondclaw"
  PYCFG="$PY"; [ -x "$VENV/bin/python" ] && PYCFG="$VENV/bin/python"
  "$PYCFG" -c "import yaml" 2>/dev/null || "$PYCFG" -m pip install --quiet --user "pyyaml>=6" >/dev/null 2>&1 || true
  "$PYCFG" - "$CFG" "$VENV/bin/python" "$SERVER" "$ENVFILE" "$REMOTE_MCP" "$MCP_URL" "$MCP_TOKEN" <<'PYEOF' || die "Could not update Hermes's config.yaml."
import sys, yaml, pathlib
cfg_path, py, server, envfile, remote, url, token = sys.argv[1:8]
p = pathlib.Path(cfg_path)
cfg = (yaml.safe_load(p.read_text()) if p.exists() else None) or {}
if not isinstance(cfg, dict):
    raise SystemExit("config.yaml is not a mapping")
servers = cfg.get("mcp_servers") or {}
if remote == "1":
    servers["secretskydb"] = {"url": url, "headers": {"Authorization": "Bearer " + token}}
else:
    servers["secretskydb"] = {"command": py, "args": [server], "env": {"SSDB_ENV_FILE": envfile}}
cfg["mcp_servers"] = servers
p.write_text(yaml.safe_dump(cfg, sort_keys=False, default_flow_style=False))
print("  mcp_servers.secretskydb written to", p, "(remote endpoint)" if remote == "1" else "(local stdio server)")
PYEOF
  ok "SecretSkyDB registered with Hermes."
else
  say "  (dry run) would add mcp_servers.secretskydb to $HERMES_DIR/config.yaml"
fi

# ---------------- 6. checks ----------------
step "6 of 6  Checks"
FAIL=0
if [ "$DRY" -eq 0 ]; then
  if [ "$REMOTE_MCP" -eq 1 ]; then ok "Remote MCP endpoint registered: $MCP_URL"
  elif SSDB_ENV_FILE="$ENVFILE" "$VENV/bin/python" "$SERVER" --selftest >/dev/null 2>&1; then ok "MCP server reaches SecretSkyDB."; else warn "MCP server self-test failed."; FAIL=1; fi
  say "Asking the model for a first reply (loading can take a few minutes)..."
  REPLY=$(curl -fsS --max-time 600 "$OLLAMA_URL/api/generate" -H 'Content-Type: application/json' \
          -d "{\"model\":\"$LOCAL_MODEL\",\"prompt\":\"Reply with the single word READY.\",\"stream\":false}" 2>/dev/null)
  if [ -n "$REPLY" ]; then ok "The model answers."; else warn "The model did not answer within ten minutes."; FAIL=1; fi
  if hermes mcp test secretskydb >/dev/null 2>&1; then ok "Hermes sees the SecretSkyDB tools."
  else warn "'hermes mcp test secretskydb' did not pass. Start hermes and run /reload-mcp, then check again."; fi
  {
    echo "# written by diamondclaw-install.sh on $(date '+%Y-%m-%d %H:%M')"
    echo "CUSTOMER=$CUSTOMER"; echo "AGENT=$AGENT"; echo "MODEL=$LOCAL_MODEL"; echo "OLLAMA_URL=$OLLAMA_URL"
    if [ "$REMOTE_MCP" -eq 1 ]; then echo "MCP_URL=$MCP_URL"; else echo "SSDB=$SSDB_USER@$SSDB_HOST:$SSDB_PORT/$SSDB_DB"; echo "MCP_SERVER=$SERVER"; fi
    echo "AGENT_ID=$AGENT_ID"
  } > "$HOME_DIR/install.env"
fi

say ""
if [ "$REMOTE_MCP" -eq 1 ]; then
  say "${B}Installed${N}: Hermes Agent + $MODEL_ID on Ollama, connected to the SecretSkyDB MCP server at $MCP_URL."
else
  say "${B}Installed${N}: Hermes Agent + $MODEL_ID on Ollama + the SecretSkyDB MCP server (describe, lookup, aggregate, search, write, unit_of_work)."
  say "Database credentials are stored in $ENVFILE (readable only by you)."
  say "The proxy user's role and table grants decide what the agent may read or change; writes are previewed and confirmed, and recorded first."
fi
say "Start the agent:   ${B}hermes${N}"
say "Then ask, for example:  ${B}Which tables can you see in SecretSkyDB, and what is in the handbook about burst pipes?${N}"
exit $FAIL
