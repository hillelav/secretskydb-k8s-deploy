# DiamondClaw: an agent, a local model and the SecretSkyDB MCP server, in one command

`selector.html` is a page that turns six choices (customer, agent, hardware, model, connection,
site options) into one command. `diamondclaw-install.sh` runs that command on the target machine:
it installs the agent runtime, a model served locally by Ollama, and the connection to SecretSkyDB
through the Model Context Protocol. Nothing in the data path leaves the machine except the calls
to the SecretSkyDB proxy.

```
SSDB_PASSWORD=… ./diamondclaw-install.sh --customer eu --agent hermes --model mistral-small-4 \
    --serving ollama --connect mcp --ssdb 127.0.0.1:55432 --db ssdb --user agent_reader --agent-id desk-1 --yes
```

Add `--dry-run` to see every step without changing anything. Open `selector.html` in a browser
to build the command with the right model for the customer and the hardware.

## What is installed today

| Part | Choice implemented | Others |
|---|---|---|
| Agent | **Hermes Agent** (Nous Research, MIT): channels, sessions, memory, cron, MCP client; installs without Docker | OpenClaw / NeMoClaw, Agent SDK app, Dify, n8n: the script stops with a message |
| Model | gpt-oss-20b, gpt-oss-120b (OpenAI, Apache 2.0); qwen2.5-14b for non-US customers | the selector lists the menu; untested ones carry a tag |
| Serving | Ollama, with a 64K-context copy of the model (Hermes refuses smaller windows) | vLLM for a fleet: not yet |
| Connection | the **SecretSkyDB MCP server**, local over stdio, or the endpoint the cluster runs (`--mcp-url`, chart `mcp.enabled`, release 0.5) | OpenClaw skill, REST: not built |

## The MCP server

`ssdb_mcp_server.py` is the same file that ships in the SecretSkyDB proxy image (`sql/mcp`). It
speaks MCP to the agent and PostgreSQL to the proxy, as the proxy user you name, so the proxy's
roles, table grants and reconstruction policy decide what the agent may see or change:

| Tool | What it does | Rules it enforces |
|---|---|---|
| `describe` | tables; or one table's columns with tier (open, cacheable, secret) and key | |
| `lookup` | rows by filters, selected columns | filters and sort on open/cacheable columns only; secret columns may be selected |
| `aggregate` | SUM, COUNT, AVG, MIN, MAX, grouped | secret columns inside SUM/COUNT/AVG, computed on the share stores |
| `search` | similarity over a secret vector column | embeds the text here, scores on the shares, fetches the best rows by key |
| `write` | insert or update, two steps | preview + confirm token; update names the primary key; `expect` values checked; audit record before the change |
| `unit_of_work` | several writes in one transaction | same confirmation; all or nothing |

Every call is logged as a JSON line; with `--audit-user` it is also a row in the table
`agent_audit`, written by an insert-only user before the change is made. Results are screened for
instruction-like text. Per-agent limits: calls per minute, rows that carried a reconstructed value.

Give the agent a least-privilege proxy user (release 0.4.1), for example:

```json
{"name": "agent_reader", "role": "reader", "catalog": true,
 "tables": {"customers": "read", "claims": "read", "handbook_chunk": "read"}}
```

## Connecting other clients

Claude Code:
```
claude mcp add secretskydb -e SSDB_ENV_FILE=$HOME/.diamondclaw/ssdb.env -- $HOME/.diamondclaw/venv/bin/python $HOME/.diamondclaw/ssdb_mcp_server.py
```

Claude Desktop (`claude_desktop_config.json`):
```json
{"mcpServers": {"secretskydb": {"command": "/Users/me/.diamondclaw/venv/bin/python",
  "args": ["/Users/me/.diamondclaw/ssdb_mcp_server.py"], "env": {"SSDB_ENV_FILE": "/Users/me/.diamondclaw/ssdb.env"}}}}
```

Any client, against the cluster's endpoint: URL `https://<host>:55440/mcp`, header
`Authorization: Bearer <token>`; the token is made by the operator and names the proxy user
(see `docs/INSTALL.md`, "MCP server for agents").

## Testing a model against the tools

`bench.py` runs the eleven questions of `examples/agent-vm` through a small agent loop that uses
the MCP server's tools with a model served by Ollama, and reports pass/fail per question. It is how
a model swap becomes a number: `python3 bench.py --model gpt-oss:20b --model qwen2.5:14b`.

## A customer demo

`demo.py` is a short, narrated run for a screen in front of a buyer: a local model answering real
questions over SecretSkyDB through the MCP server, then the two things only SecretSkyDB does — a
secret column read and summed without any single value being revealed, and a hostile query refused —
with the audit trail of everything the agent did.

```
AGENT_ENV=~/ssdb-agent/agent.env python3 demo.py --mcp-url $MCP_URL --mcp-token $TOKEN
```

It uses `qwen2.5:14b` (the tested model) for three reliable reads — a plain lookup, a reconstructed
secret phone number, and a SUM over a secret amount computed on the shares — then files a claim
through the write tool (preview, then an operator-confirmed commit) and prints the refusal and the
audit trail. Add `--pause` to step through it in a live talk, `--no-trace` to hide the tool calls.

Note on scope: the model drives the reads; the single write is driven deterministically because a
14B model does not reliably pick a free primary key or carry a confirm token across two calls. The
path it exercises — preview, confirm, audit — is exactly the product's. A larger model, or a write
tool that generates the id, closes that gap (`bench.py` measures it: this model passes the reads and
the aggregate, not the model-driven writes or the handbook-grounded questions).

## The demo in a browser

`webdemo.py` serves the same demo as a web page: a chat with the agent, the live
tool-call trace, the audit trail, a one-click "try to fish with the secret"
refusal, and a scripted claim-filing button (write preview → operator confirm).
It binds 127.0.0.1 only; reach a VM through an SSH tunnel:

```
# on the VM
. ~/ssdb-agent/mcp-token.env
AGENT_ENV=~/ssdb-agent/agent.env python3 webdemo.py --mcp-url "$MCP_URL" --mcp-token "$SSDB_MCP_TOKEN"
# on the laptop
gcloud compute ssh ssdb-agent --zone <zone> -- -N -L 8077:localhost:8077
open http://localhost:8077
```
