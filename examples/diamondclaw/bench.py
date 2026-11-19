#!/usr/bin/env python3
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
"""The eleven questions of examples/agent-vm, asked through the SecretSkyDB MCP server with a
local model, scored pass / fail. A model swap becomes a number.

    python3 bench.py --model gpt-oss:20b --model qwen2.5:14b          # Ollama models, MCP over stdio
    python3 bench.py --mcp-url https://host:55440/mcp --mcp-token T    # against the cluster's server
    python3 bench.py --hermes                                           # the same questions through `hermes chat -q`
    python3 bench.py --list-tools                                       # what the server offers

The loop is deliberately small: the model sees the server's instructions and the tool schemas,
calls tools until it answers, and the answer is scored like agent.py does (expected strings, and
for the two write cases the claims table before and after). Settings come from the agent's
environment file (AGENT_ENV, default ~/ssdb-agent/agent.env): the proxy address, the admin user
for reseeding and checks, the agent's writer user (the MCP server runs as it) and the audit user.
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import requests

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "agent-vm"))
import agent as A                                                      # noqa: E402  (loads agent.env, CASES, _claims, seed)

SERVER = HERE / "ssdb_mcp_server.py"
DOMAIN = """You are the authorized service-desk assistant of Galil Home Insurance, acting for staff who
are entitled to this data. The database enforces every permission itself: any value a tool returns to you
is cleared for you to use in your answer. Never refuse to look something up, and never say a value is
confidential or private — if you are not allowed to see it, the tool will refuse, not you. So ALWAYS call
a tool; never answer a question about a specific customer, claim, phone number, amount or policy rule from
memory, even when you think you know it.
Tables: customers (id, name, city, plan: basic|plus|premium; phone, national_id, notes are secret),
claims (id, customer_id, opened, status: open|in_review|approved|rejected|paid, kind, amount_ils, description;
amount_ils and description are secret), handbook_chunk (the policy handbook; use search on it for every
question about cover, limits, deductibles, deadlines and procedures).
When a question names a customer: lookup customers with where {"name": {"op": "ilike", "value": "%surname%"}},
then their claims with where {"customer_id": ...}. For a phone number or any secret field, lookup the row and
select that column — the tool returns it if you are permitted. Amounts that depend on the plan: read the
customer's plan, then search the handbook for the rule for that plan.
A new claim: call write with action "insert" on claims, values = a new id "CL-9xxx", the customer's id,
opened = today's date, status "open", kind, description and amount_ils. The first write returns a preview
with a confirm_token. Then call write AGAIN with exactly the same arguments plus confirm_token set to that
exact string copied verbatim — never invent a token. Report success only after the second write returns ok,
and give the claim id. Reply only in English, in one or two sentences."""


def ollama_chat(url, model, messages, tools, num_ctx=16384):
    r = requests.post(f"{url}/api/chat", json={"model": model, "messages": messages, "stream": False, "keep_alive": "2h",
                                                 "options": {"temperature": 0, "num_ctx": num_ctx}, **({"tools": tools} if tools else {})}, timeout=900)
    r.raise_for_status()
    return r.json()["message"]


class MCP:
    """One MCP session: stdio to the local server as the agent's writer user, or the cluster's http endpoint."""
    def __init__(self, args):
        self.args = args
        self.session = None
        self.tools = []
        self.instructions = ""
        self._stack = None

    async def __aenter__(self):
        from contextlib import AsyncExitStack
        from mcp import ClientSession
        self._stack = AsyncExitStack()
        if self.args.mcp_url:
            from mcp.client.streamable_http import streamablehttp_client
            r, w, _ = await self._stack.enter_async_context(
                streamablehttp_client(self.args.mcp_url, headers={"Authorization": f"Bearer {self.args.mcp_token}"}))
        else:
            from mcp.client.stdio import stdio_client, StdioServerParameters
            env = {k: v for k, v in os.environ.items() if k.startswith(("SSDB_", "PATH", "HOME", "KEEP_ALIVE", "OLLAMA"))}
            w_user = os.environ.get("SSDB_WRITER_USER"); w_pw = os.environ.get("SSDB_WRITER_PASSWORD")
            if w_user and w_pw:
                env["SSDB_USER"], env["SSDB_PASSWORD"] = w_user, w_pw           # the server runs as the agent's writer
            env["SSDB_MCP_AGENT_ID"] = self.args.agent_id
            env.setdefault("SSDB_EMBED_URL", self.args.ollama); env.setdefault("SSDB_EMBED_MODEL", os.environ.get("EMBED_MODEL", "all-minilm"))
            for k in ("SSDB_MCP_TRANSPORT", "SSDB_MCP_TOKENS_FILE"):
                env.pop(k, None)
            params = StdioServerParameters(command=sys.executable, args=[str(self.args.server)], env=env)
            r, w = await self._stack.enter_async_context(stdio_client(params))
        self.session = await self._stack.enter_async_context(ClientSession(r, w))
        init = await self.session.initialize()
        self.instructions = init.instructions or ""
        self.tools = (await self.session.list_tools()).tools
        return self

    async def __aexit__(self, *a):
        await self._stack.aclose()

    def ollama_tools(self):
        return [{"type": "function", "function": {"name": t.name, "description": t.description or "", "parameters": t.inputSchema}} for t in self.tools]

    async def call(self, name, arguments):
        res = await self.session.call_tool(name, arguments or {})
        return "".join(getattr(c, "text", "") for c in res.content) or json.dumps({"error": "empty result"})


async def ask_model(mcp: MCP, args, model: str, question: str) -> tuple[str, int]:
    system = DOMAIN + "\n\nServer rules:\n" + mcp.instructions
    messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
    tools = mcp.ollama_tools()
    calls = 0
    for _ in range(args.max_rounds):
        msg = ollama_chat(args.ollama, model, messages, tools)
        messages.append(msg)
        tcs = msg.get("tool_calls") or []
        if not tcs:
            text = (msg.get("content") or "").strip()
            if text:
                return text, calls
            messages.append({"role": "user", "content": "Answer the question now, in one or two sentences, from the tool results."})
            continue
        for tc in tcs:
            fn = tc.get("function", {}); name = fn.get("name", ""); arguments = fn.get("arguments") or {}
            if isinstance(arguments, str):
                try:
                    arguments = json.loads(arguments)
                except Exception:
                    arguments = {}
            calls += 1
            if args.verbose:
                print(f"      → {name} {json.dumps(arguments, ensure_ascii=False)[:160]}", flush=True)
            out = await mcp.call(name, arguments) if name in {t.name for t in mcp.tools} else json.dumps({"error": f"unknown tool {name}"})
            if args.verbose:
                print(f"      ← {out[:160]}", flush=True)
            messages.append({"role": "tool", "content": out[:12000], "name": name})
    return (messages[-1].get("content") or "(no answer within the step limit)"), calls


def ask_hermes(question: str, timeout: int) -> str:
    r = subprocess.run(["hermes", "chat", "-q", question, "-Q"], capture_output=True, text=True, timeout=timeout)
    return (r.stdout or r.stderr).strip()


def score(case: dict, text: str, before: dict, after: dict) -> list[str]:
    flat = text.lower().replace(",", "")
    problems = [f"answer lacks {' / '.join(g)}" for g in case["want"] if not any(w in flat for w in g)]
    if "db" in case:
        if not case["db"](before, after):
            problems.append(f"database check failed ({case['db_note']})")
    elif {k: tuple(v) for k, v in after.items()} != {k: tuple(v) for k, v in before.items()}:
        problems.append("the data was changed although nothing asked for it")
    return problems


async def run_model(args, label: str, asker) -> dict:
    print(f"\n=== {label} ===", flush=True)
    if not args.no_seed:
        print("reloading the sample data", flush=True)
        A.seed()
    results = []
    t_all = time.time()
    for n, c in enumerate(A.CASES, 1):
        before, t0 = A._claims(), time.time()
        print(f"[{n}/{len(A.CASES)}] {c['q']}", flush=True)
        try:
            text, calls = await asker(c["q"])
        except Exception as e:                                           # noqa: BLE001
            text, calls = f"(error: {e})", 0
        time.sleep(3)
        after = A._claims()
        problems = score(c, text, before, after)
        secs = time.time() - t0
        results.append({"n": n, "q": c["q"], "ok": not problems, "secs": round(secs, 1), "calls": calls, "answer": text[:400], "problems": problems})
        print("    " + " ".join(text.split())[:300])
        print(f"  {'PASS' if not problems else 'FAIL'} ({secs:.0f} s, {calls} tool calls)" + ("" if not problems else ": " + "; ".join(problems)), flush=True)
    passed = sum(r["ok"] for r in results)
    print(f"\n{passed} of {len(results)} passed with {label} in {time.time() - t_all:.0f} s", flush=True)
    return {"label": label, "passed": passed, "total": len(results), "secs": round(time.time() - t_all), "cases": results}


async def main_async(args) -> int:
    if args.list_tools:
        async with MCP(args) as mcp:
            print("instructions:", (mcp.instructions or "")[:200].replace("\n", " "), "…")
            for t in mcp.tools:
                print(f"- {t.name}: {(t.description or '')[:110]}")
        return 0
    summary = []
    if args.hermes:
        summary.append(await run_model(args, "hermes chat -q", lambda q: asyncio.to_thread(lambda: (ask_hermes(q, args.timeout), 0))))
    else:
        models = args.model or [os.environ.get("MODEL", "qwen2.5:7b")]
        async with MCP(args) as mcp:
            for m in models:
                summary.append(await run_model(args, m, lambda q, m=m: ask_model(mcp, args, m, q)))
    print("\n| model | passed | time |\n|---|---|---|")
    for s in summary:
        print(f"| {s['label']} | {s['passed']}/{s['total']} | {s['secs']} s |")
    Path(args.out).write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    print(f"details in {args.out}")
    return 0 if all(s["passed"] == s["total"] for s in summary) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", action="append", help="Ollama model to test (repeatable)")
    ap.add_argument("--ollama", default=os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"))
    ap.add_argument("--server", default=str(SERVER), help="the MCP server file (stdio mode)")
    ap.add_argument("--mcp-url", default="", help="the cluster's MCP endpoint instead of a local server")
    ap.add_argument("--mcp-token", default=os.environ.get("SSDB_MCP_TOKEN", ""))
    ap.add_argument("--agent-id", default="bench")
    ap.add_argument("--hermes", action="store_true", help="ask through `hermes chat -q` instead of the built-in loop")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--max-rounds", type=int, default=10)
    ap.add_argument("--no-seed", action="store_true", help="do not reload the sample data first")
    ap.add_argument("--list-tools", action="store_true")
    ap.add_argument("--out", default="bench-results.json")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    if args.mcp_url and not args.mcp_token:
        ap.error("--mcp-url needs --mcp-token")
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    sys.exit(main())
