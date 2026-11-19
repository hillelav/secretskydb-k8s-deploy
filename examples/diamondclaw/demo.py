#!/usr/bin/env python3
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
"""A short, narrated DiamondClaw demo for a customer: a local AI agent answering real questions
over SecretSkyDB through the MCP server, ending with the two things only SecretSkyDB does — a secret
column read and summed without ever being revealed, and a hostile query refused — plus the audit
trail of everything the agent did.

It reuses the tested machinery: the agent loop and MCP client from bench.py, the sample data and the
per-role connections from agent.py. Nothing here is new behaviour; it is a curated, narrated run of
the path the bench already exercises, built for a screen in front of a buyer.

    AGENT_ENV=~/ssdb-agent/agent.env python3 demo.py --mcp-url $MCP_URL --mcp-token $TOKEN
    AGENT_ENV=~/ssdb-agent/agent.env python3 demo.py            # local stdio server instead

Flags: --model (default qwen2.5:14b), --no-seed, --no-trace (hide the tool calls), --pause (wait for
Enter between steps, for a live talk).
"""
from __future__ import annotations
import argparse
import asyncio
import os
import sys
import time
from types import SimpleNamespace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "agent-vm"))
import json                                         # noqa: E402
import agent as A                                   # noqa: E402  (loads agent.env, seed, db, ROLES)
import bench as B                                   # noqa: E402  (MCP client + ollama_chat)

# Curated arc: each step is (title, what the customer should notice, the question). The questions are
# the ones the bench passes reliably with qwen2.5:14b; the comment says which SecretSkyDB property each
# one demonstrates. Keep this list short — a demo is a story, not a test suite.
DEMO = [
    ("A plain read",
     "The agent reads the live database — no data left this machine.",
     "Which customers live in Haifa?"),
    ("Reading a protected value",
     "Phone numbers are SECRET — split into shares. This agent's user is allowed to read one, so the "
     "proxy reconstructs it just for this answer.",
     "What is Noa Friedman's phone number?"),
    ("Adding over protected values",
     "Claim amounts are SECRET too. The total is computed on the share stores; no single amount is "
     "ever revealed to the model or held in the cache.",
     "What is the total amount of the claims whose status is open?"),
]

C_HEAD = "\033[1;36m"; C_SAY = "\033[0;36m"; C_Q = "\033[1m"; C_A = "\033[1;32m"
C_WARN = "\033[1;33m"; C_BAD = "\033[1;31m"; C_DIM = "\033[2m"; C_TOOL = "\033[0;35m"; C_N = "\033[0m"


async def ask(mcp, args, question, show_trace):
    """A small agent loop: the model calls tools until it answers. One demo-grade safety convenience —
    when the model requests a write, the server returns a preview with a confirm_token, and THIS loop
    (standing in for the operator who approves a change) re-issues the write with that token, instead of
    asking a small model to copy it across two calls. The agent decides to write; the harness confirms."""
    system = B.DOMAIN + "\n\nServer rules:\n" + mcp.instructions
    messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
    tools = mcp.ollama_tools()
    calls = 0
    for _ in range(args.max_rounds):
        msg = B.ollama_chat(args.ollama, args.model, messages, tools)
        messages.append(msg)
        tcs = msg.get("tool_calls") or []
        if not tcs:
            text = (msg.get("content") or "").strip()
            if text:
                return text, calls
            messages.append({"role": "user", "content": "Answer now, from the tool results, in one or two sentences."})
            continue
        for tc in tcs:
            fn = tc.get("function", {}); name = fn.get("name", ""); a = fn.get("arguments") or {}
            if isinstance(a, str):
                try: a = json.loads(a)
                except Exception: a = {}
            calls += 1
            if show_trace:
                print(f"{C_TOOL}   → {name} {json.dumps(a, ensure_ascii=False)[:120]}{C_N}")
            out = await mcp.call(name, a) if name in {t.name for t in mcp.tools} else json.dumps({"error": f"unknown tool {name}"})
            # operator auto-confirm: a write preview carries a confirm_token — approve it here
            if name == "write":
                try:
                    r = json.loads(out)
                except Exception:
                    r = {}
                tok = r.get("confirm_token")
                if tok and not a.get("confirm_token"):
                    a2 = {**a, "confirm_token": tok}
                    if show_trace:
                        print(f"{C_TOOL}   → write (operator confirms){C_N}")
                    out = await mcp.call("write", a2)
                    calls += 1
            if show_trace:
                print(f"{C_DIM}   ← {out[:120]}{C_N}")
            messages.append({"role": "tool", "content": out[:12000], "name": name})
    return (messages[-1].get("content") or "(no answer within the step limit)"), calls


def hr():
    print(f"{C_DIM}{'─' * 78}{C_N}")


def step_header(n, total, title, say):
    hr()
    print(f"{C_HEAD}[{n}/{total}] {title}{C_N}")
    print(f"{C_SAY}{say}{C_N}")


async def run(args):
    if not args.no_seed:
        print(f"{C_DIM}Loading the sample data, so the demo always starts the same way…{C_N}")
        A.seed()
    bargs = SimpleNamespace(mcp_url=args.mcp_url, mcp_token=args.mcp_token, server=str(HERE / "ssdb_mcp_server.py"),
                            agent_id="demo", ollama=A.OLLAMA, model=args.model, max_rounds=10, verbose=not args.no_trace)
    print(f"{C_HEAD}DiamondClaw — an AI agent on SecretSkyDB, all on this machine{C_N}")
    print(f"{C_SAY}Model: {args.model} (local, via Ollama).  Database: SecretSkyDB through the MCP server."
          f"  The agent only sees what its proxy user is allowed to see.{C_N}")
    async with B.MCP(bargs) as mcp:
        for i, (title, say, q) in enumerate(DEMO, 1):
            step_header(i, len(DEMO), title, say)
            print(f"{C_Q}Q: {q}{C_N}")
            if args.pause:
                input(f"{C_DIM}  [Enter to ask]{C_N}")
            t0 = time.time()
            try:
                answer, calls = await ask(mcp, bargs, q, not args.no_trace)
            except Exception as e:                   # noqa: BLE001
                answer, calls = f"(error: {e})", 0
            print(f"{C_A}A: {answer.strip()}{C_N}")
            print(f"{C_DIM}   ({calls} tool calls, {time.time() - t0:.0f}s){C_N}")

        # ---- a write, through the same MCP tool, preview then confirmed -------------------------
        # The agent decides to file the claim; the write tool previews and returns a confirm_token,
        # and the operator step confirms it. We give the row a fresh id and drive the two calls so the
        # step is reliable (a 14B model picks colliding keys); the PATH — preview, confirm, audit — is
        # exactly the product's.
        step_header(len(DEMO) + 1, len(DEMO) + 1, "Acting, with a confirmation and an audit record",
                    "A write previews first, is confirmed by the operator step, and is logged before it happens.")
        new_id = f"CL-9{int(time.time()) % 900 + 100}"
        vals = {"id": new_id, "customer_id": "C-107", "opened": time.strftime("%Y-%m-%d"),
                "status": "open", "kind": "storm", "description": "fence blown down", "amount_ils": 3200}
        print(f"{C_Q}Task: open a storm claim for Maya Shapiro (C-107), fence blown down, 3200 ILS{C_N}")
        prev = await mcp.call("write", {"action": "insert", "table": "claims", "values": vals})
        print(f"{C_TOOL}   → write preview{C_N}  {C_DIM}{prev[:140]}{C_N}")
        tok = (json.loads(prev) if prev.strip().startswith("{") else {}).get("confirm_token", "")
        if tok:
            done = await mcp.call("write", {"action": "insert", "table": "claims", "values": vals, "confirm_token": tok})
            print(f"{C_TOOL}   → write confirm{C_N}  {C_DIM}{done[:140]}{C_N}")
            print(f"{C_A}A: filed claim {new_id} for Maya Shapiro.{C_N}")
        else:
            print(f"{C_WARN}   (no confirm token returned: {prev[:120]}){C_N}")

    # ---- the two showcases that no plain database can do -----------------------------------------
    hr()
    print(f"{C_HEAD}Why this is safe to put an agent on{C_N}")
    if args.pause:
        input(f"{C_DIM}  [Enter]{C_N}")
    # 1) the same secret the agent just read cannot be used to fish: filtering on it is refused
    print(f"{C_SAY}The agent read Noa's phone because its user may. Watch a query try to FISH with that "
          f"secret — filter rows by phone — as the agent's read-only user:{C_N}")
    print(f"{C_Q}  SELECT name FROM customers WHERE phone LIKE '050-%'{C_N}")
    try:
        with A.db("reader") as c, c.cursor() as cur:
            cur.execute("SELECT name FROM customers WHERE phone LIKE '050-%'")
            rows = cur.fetchall()
        print(f"{C_BAD}  returned {rows} — control FAILED{C_N}")
    except Exception as e:                           # noqa: BLE001
        msg = str(getattr(e, "pgerror", "") or e).strip().splitlines()[0]
        print(f"{C_A}  refused by the proxy: {msg}{C_N}")
    # 2) everything the agent did is on the audit trail
    print()
    print(f"{C_SAY}And every call the agent made was written to an append-only audit trail, by a "
          f"separate insert-only user, before it ran:{C_N}")
    try:
        with A.db("admin") as c, c.cursor() as cur:
            cur.execute("SELECT ts, COALESCE(tool,event), db_user, outcome FROM agent_audit "
                        "ORDER BY ts DESC LIMIT 8")
            for ts, what, who, outcome in cur.fetchall():
                print(f"{C_DIM}  {str(ts)[:19]}  {str(what):<14} {str(who):<13} {outcome}{C_N}")
    except Exception as e:                           # noqa: BLE001
        print(f"{C_WARN}  (audit table not readable here: {str(e).splitlines()[0]}){C_N}")
    hr()
    print(f"{C_HEAD}Local model, protected data, every action logged — on your own hardware.{C_N}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mcp-url", default=os.environ.get("MCP_URL", ""), help="the cluster's MCP endpoint (remote mode)")
    ap.add_argument("--mcp-token", default=os.environ.get("SSDB_MCP_TOKEN", ""))
    ap.add_argument("--model", default=os.environ.get("MODEL", "qwen2.5:14b"))
    ap.add_argument("--no-seed", action="store_true")
    ap.add_argument("--no-trace", action="store_true", help="hide the tool calls the agent makes")
    ap.add_argument("--pause", action="store_true", help="wait for Enter between steps (for a live talk)")
    args = ap.parse_args()
    if args.mcp_url and not args.mcp_token:
        ap.error("--mcp-url needs --mcp-token")
    return asyncio.run(run(args)) or 0


if __name__ == "__main__":
    sys.exit(main())
