#!/usr/bin/env python3
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
"""A one-file web GUI for the DiamondClaw customer demo: a local model
answering questions over SecretSkyDB through the MCP server, with the tool
calls, the audit trail and the proxy's refusals on screen.

It reuses the exact machinery the terminal demo proved (bench.py's MCP client
and agent loop, agent.py's per-role connections); this file only adds a small
stdlib HTTP server and a page. Nothing is exposed to the internet: it binds
127.0.0.1 — on a VM, reach it through an SSH tunnel:

    # on the VM
    . ~/ssdb-agent/mcp-token.env
    AGENT_ENV=~/ssdb-agent/agent.env python3 webdemo.py \
        --mcp-url "$MCP_URL" --mcp-token "$SSDB_MCP_TOKEN" --port 8077
    # on the laptop
    gcloud compute ssh ssdb-agent --zone <zone> -- -N -L 8077:localhost:8077
    open http://localhost:8077

Endpoints: GET / (the page), POST /ask {"q": ...}, GET /audit,
POST /fish (the forbidden filter, as the read-only user), POST /seed.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "agent-vm"))
import agent as A                                   # noqa: E402  (agent.env, db, seed)
import bench as B                                   # noqa: E402  (MCP client, ollama_chat, DOMAIN)

STATE = SimpleNamespace(mcp=None, loop=None, bargs=None, model="", lock=threading.Lock())


# ---------------------------------------------------------------- agent loop
async def ask(question: str) -> dict:
    """The demo agent loop: the model calls tools until it answers; a write
    preview's confirm_token is approved by the harness (the operator step),
    like demo.py. Returns the answer plus a structured trace for the page."""
    mcp, bargs = STATE.mcp, STATE.bargs
    system = B.DOMAIN + "\n\nServer rules:\n" + mcp.instructions
    messages = [{"role": "system", "content": system},
                {"role": "user", "content": question}]
    tools = mcp.ollama_tools()
    trace, calls, t0 = [], 0, time.time()
    for _ in range(bargs.max_rounds):
        msg = await asyncio.to_thread(B.ollama_chat, bargs.ollama, STATE.model, messages, tools)
        messages.append(msg)
        tcs = msg.get("tool_calls") or []
        if not tcs:
            text = (msg.get("content") or "").strip()
            if text:
                return {"answer": text, "trace": trace, "calls": calls,
                        "secs": round(time.time() - t0, 1)}
            messages.append({"role": "user", "content":
                             "Answer now, from the tool results, in one or two sentences."})
            continue
        for tc in tcs:
            fn = tc.get("function", {})
            name = fn.get("name", "")
            a = fn.get("arguments") or {}
            if isinstance(a, str):
                try:
                    a = json.loads(a)
                except Exception:
                    a = {}
            calls += 1
            out = (await mcp.call(name, a) if name in {t.name for t in mcp.tools}
                   else json.dumps({"error": f"unknown tool {name}"}))
            step = {"tool": name, "args": json.dumps(a, ensure_ascii=False)[:160],
                    "result": out[:200]}
            if name == "write":
                try:
                    r = json.loads(out)
                except Exception:
                    r = {}
                tok = r.get("confirm_token")
                if tok and not a.get("confirm_token"):
                    out = await mcp.call("write", {**a, "confirm_token": tok})
                    calls += 1
                    step["confirmed"] = out[:160]
            trace.append(step)
            messages.append({"role": "tool", "content": out[:12000], "name": name})
    return {"answer": "(no answer within the step limit)", "trace": trace,
            "calls": calls, "secs": round(time.time() - t0, 1)}


async def write_claim() -> dict:
    """The write showcase, driven deterministically through the SAME MCP write
    tool (preview -> operator confirm), like demo.py: a 14B model does not
    reliably pick a free primary key or carry a confirm token, so the agent
    decides WHAT to do in chat while the harness drives the two-step write."""
    mcp = STATE.mcp
    t0 = time.time()
    new_id = f"CL-9{int(time.time()) % 900 + 100}"
    vals = {"id": new_id, "customer_id": "C-107", "opened": time.strftime("%Y-%m-%d"),
            "status": "open", "kind": "storm", "description": "fence blown down",
            "amount_ils": 3200}
    trace = []
    prev = await mcp.call("write", {"action": "insert", "table": "claims", "values": vals})
    trace.append({"tool": "write (preview)", "args": json.dumps(vals)[:160],
                  "result": prev[:200]})
    try:
        tok = json.loads(prev).get("confirm_token", "")
    except Exception:
        tok = ""
    if not tok:
        return {"answer": f"no confirm token returned: {prev[:120]}", "trace": trace,
                "calls": 1, "secs": round(time.time() - t0, 1)}
    done = await mcp.call("write", {"action": "insert", "table": "claims",
                                    "values": vals, "confirm_token": tok})
    trace.append({"tool": "write (operator confirms)", "args": f"confirm_token={tok[:24]}…",
                  "result": done[:200]})
    return {"answer": f"Filed claim {new_id} for Maya Shapiro: storm, fence blown down, "
                      f"3,200 ILS — previewed, confirmed, audited.",
            "trace": trace, "calls": 2, "secs": round(time.time() - t0, 1)}


def _stores():
    f = os.environ.get("SSDB_DASH_FILE", "")
    if f and Path(f).exists():
        return json.loads(Path(f).read_text())
    return json.loads(os.environ.get("SSDB_DASH_STORES", "[]"))


def _cell(v):
    if v is None:
        return "—"
    if isinstance(v, (bytes, bytearray, memoryview)):
        b = bytes(v)
        return "0x" + b[:8].hex() + ("…" if len(b) > 8 else "")
    if isinstance(v, list):
        head = ",".join(str(x) for x in v[:2])
        return f"[{len(v)} ints] {head}…" if len(v) > 2 else str(v)
    t = str(v)
    return t if len(t) <= 30 else t[:27] + "…"


def dashboard():
    """The faces-demo view: one card per store (up + row counts), and the
    same customer row read through the proxy and raw from every store —
    plaintext via the proxy, shares elsewhere."""
    import psycopg2
    out = {"stores": [], "split": {"cols": [], "stores": []}}
    tables = ("customers", "claims", "handbook_chunk")
    # the reference row, through the proxy (reconstructed where authorized)
    try:
        with A.db("admin") as c, c.cursor() as cur:
            cur.execute("SELECT id, name, city, plan, phone FROM customers "
                        "WHERE name = 'Noa Friedman'")
            r = cur.fetchone()
        proxy_row = dict(zip(("id", "name", "city", "plan", "phone"), r)) if r else {}
    except Exception as e:                           # noqa: BLE001
        proxy_row = {"error": str(e)[:80]}
    key = proxy_row.get("id")
    out["split"]["stores"].append(
        {"name": "Through the proxy", "row": {k: _cell(v) for k, v in proxy_row.items()}})
    for st in _stores():
        card = {"name": st["name"], "up": False, "counts": {}, "error": ""}
        row = {}
        try:
            cn = psycopg2.connect(host=st["host"], port=st.get("port", 5432),
                                  dbname=st.get("db", "ssdb"), user=st.get("user", "postgres"),
                                  password=st.get("pw", ""), sslmode="prefer",
                                  connect_timeout=4)
            cn.autocommit = True
            card["up"] = True
            with cn.cursor() as cur:
                for t in tables:
                    try:
                        cur.execute(f'SELECT count(*) FROM "{t}"')
                        card["counts"][t] = cur.fetchone()[0]
                    except Exception:
                        cn.rollback()
                        card["counts"][t] = "—"
                if key is not None:
                    try:
                        cur.execute('SELECT * FROM "customers" WHERE id = %s LIMIT 1', (key,))
                        r = cur.fetchone()
                        if r is not None:
                            cols = [d.name for d in cur.description]
                            row = {k: _cell(v) for k, v in zip(cols, r)}
                    except Exception as e:           # noqa: BLE001
                        row = {"error": str(e)[:60]}
            cn.close()
        except Exception as e:                       # noqa: BLE001
            card["error"] = str(e).strip().splitlines()[0][:90]
        out["stores"].append(card)
        out["split"]["stores"].append({"name": st["name"] + " (raw)", "row": row})
    seen = []
    for stt in out["split"]["stores"]:
        for k in stt["row"]:
            if k not in seen and k != "error":
                seen.append(k)
    out["split"]["cols"] = seen
    return out


def audit_rows(limit=12):
    with A.db("admin") as c, c.cursor() as cur:
        cur.execute("SELECT ts, COALESCE(tool, event), db_user, outcome FROM agent_audit "
                    "ORDER BY ts DESC LIMIT %s", (limit,))
        return [{"ts": str(r[0])[:19], "what": str(r[1]), "who": str(r[2]),
                 "outcome": str(r[3])} for r in cur.fetchall()]


def fish():
    """The forbidden query — filter rows BY the secret — as the agent's
    read-only user. The proxy must refuse it."""
    sql = "SELECT name FROM customers WHERE phone LIKE '050-%'"
    try:
        with A.db("reader") as c, c.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()
        return {"sql": sql, "refused": False, "rows": str(rows)[:200]}
    except Exception as e:                           # noqa: BLE001
        msg = str(getattr(e, "pgerror", "") or e).strip().splitlines()[0]
        return {"sql": sql, "refused": True, "error": msg[:200]}


# ---------------------------------------------------------------- the page
PAGE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DiamondClaw live demo</title>
<style>
:root{--bg:#0f181f;--panel:#17232c;--ink:#e7eef2;--mut:#9db0bd;--line:#2c3c48;
--acc:#4fc1c0;--good:#6fd08c;--bad:#ff8a80;--mono:Menlo,Consolas,monospace}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.45 "Segoe UI",Helvetica,Arial,sans-serif}
.wrap{max-width:1200px;margin:0 auto;padding:16px;display:flex;flex-direction:column;gap:12px;height:100vh}
header{display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:6px}
h1{font-size:21px;margin:0}h1 b{color:var(--acc)}
.sub{color:var(--mut);font-size:13px}
.grid{display:grid;grid-template-columns:minmax(0,1.25fr) minmax(0,1fr);gap:12px;flex:1;min-height:0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
display:flex;flex-direction:column;min-height:0}
.card h2{font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--mut);
margin:0;padding:10px 12px;border-bottom:1px solid var(--line)}
#chat{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:10px}
.msg{max-width:88%;padding:8px 12px;border-radius:12px;white-space:pre-wrap}
.me{align-self:flex-end;background:#1d3a4a}.ai{align-self:flex-start;background:#122b2b;border:1px solid #1d4a48}
.meta{color:var(--mut);font-size:11.5px;margin-top:4px}
.chips{display:flex;flex-wrap:wrap;gap:6px;padding:0 12px 8px}
.chip{border:1px solid var(--line);background:none;color:var(--mut);border-radius:999px;
padding:4px 10px;font-size:12.5px;cursor:pointer}.chip:hover{border-color:var(--acc);color:var(--ink)}
.inrow{display:flex;gap:8px;padding:10px 12px;border-top:1px solid var(--line)}
input{flex:1;background:#0c141a;border:1px solid var(--line);border-radius:8px;
color:var(--ink);padding:9px 11px;font:inherit}
button.send{background:var(--acc);color:#06201f;border:0;border-radius:8px;padding:9px 16px;
font-weight:600;cursor:pointer}button.send:disabled{opacity:.5}
.right{display:flex;flex-direction:column;gap:12px;min-height:0}
#trace{flex:1.2;overflow-y:auto;padding:10px 12px;font-family:var(--mono);font-size:12px}
.tl{margin-bottom:8px;border-left:3px solid var(--acc);padding-left:8px}
.tl .t{color:var(--acc);font-weight:700}.tl .r{color:var(--mut);word-break:break-all}
.tl .c{color:var(--good)}
#auditbox{flex:1;overflow-y:auto}
table{width:100%;border-collapse:collapse;font-size:12px;font-family:var(--mono)}
td,th{padding:4px 10px;border-bottom:1px solid var(--line);text-align:left;color:var(--mut)}
td.ok{color:var(--good)}td.refused,td.failed{color:var(--bad)}
.fishrow{padding:10px 12px;border-top:1px solid var(--line)}
button.fish{background:none;border:1px solid var(--bad);color:var(--bad);border-radius:8px;
padding:8px 12px;cursor:pointer;font:inherit}
#fishout{font-family:var(--mono);font-size:12px;margin-top:8px;white-space:pre-wrap;word-break:break-all}
#fishout .no{color:var(--bad)}
footer{color:var(--mut);font-size:12.5px;text-align:center;padding-bottom:4px}
.spin{color:var(--mut);font-style:italic}
</style></head><body><div class="wrap">
<header><h1><b>DiamondClaw</b> — an AI agent on SecretSkyDB</h1>
<span class="sub" id="status">model: … · all on this machine · nothing leaves it</span>
<button class="chip" id="dashbtn" style="border-color:var(--acc);color:var(--acc)">📊 Dashboard</button></header>
<div id="dash" style="display:none;position:fixed;inset:0;background:rgba(5,10,14,.92);z-index:9;overflow:auto">
 <div style="max-width:1150px;margin:24px auto;padding:0 16px">
  <div style="display:flex;justify-content:space-between;align-items:center">
   <h1 style="font-size:19px">📊 The cluster, store by store</h1>
   <button class="chip" id="dashclose">✕ close</button></div>
  <div id="cards" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin:10px 0"></div>
  <div class="card" style="margin-top:12px"><h2>One row, everywhere — Noa Friedman</h2>
   <div style="overflow-x:auto"><table id="splitt"></table></div>
   <div class="sub" style="padding:8px 12px">Through the proxy the phone is served only to an
   authorized user. The cache is the protected store inside the pod (with scrub-after-flush it holds
   no secret plaintext at all); each share store holds a meaningless fragment — any two of the three
   reconstruct the value, one alone reveals nothing.</div>
  </div>
 </div>
</div>
<div class="grid">
  <div class="card"><h2>Ask the agent</h2>
    <div id="chat"></div>
    <div class="chips">
      <button class="chip">Which customers live in Haifa?</button>
      <button class="chip">What is Noa Friedman's phone number?</button>
      <button class="chip">What is the total amount of the claims whose status is open?</button>
      <button class="chip">How many claims have the status paid?</button>
      <button class="chip" id="writebtn">📝 File a claim for Maya Shapiro (preview → confirm → audit)</button>
    </div>
    <div class="inrow"><input id="q" placeholder="Ask about customers, claims or the policy handbook…">
    <button class="send" id="send">Send</button></div>
  </div>
  <div class="right">
    <div class="card" style="flex:1.2"><h2>Tool calls — what the agent did</h2><div id="trace"></div></div>
    <div class="card" style="flex:1"><h2>Audit trail — written before every action</h2>
      <div id="auditbox"><table id="audit"></table></div>
      <div class="fishrow"><button class="fish" id="fish">🎣 Try to fish with the secret (filter by phone)</button>
      <div id="fishout"></div></div>
    </div>
  </div>
</div>
<footer>Local model · protected data split into shares · every action permission-checked and logged</footer>
</div>
<script>
const $=id=>document.getElementById(id);
const esc=s=>String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function add(cls,text,meta){const d=document.createElement('div');d.className='msg '+cls;
d.textContent=text;if(meta){const m=document.createElement('div');m.className='meta';
m.textContent=meta;d.appendChild(m);}$('chat').appendChild(d);$('chat').scrollTop=1e9;return d;}
function showTrace(tr){$('trace').innerHTML=tr.map(s=>'<div class="tl"><span class="t">→ '
+esc(s.tool)+'</span> '+esc(s.args)+(s.confirmed?'<br><span class="c">→ write (operator confirms) '
+esc(s.confirmed)+'</span>':'')+'<br><span class="r">← '+esc(s.result)+'</span></div>').join('');}
async function refreshAudit(){try{const r=await(await fetch('/audit')).json();
$('audit').innerHTML='<tr><th>time</th><th>call</th><th>as user</th><th>outcome</th></tr>'+
r.map(a=>'<tr><td>'+esc(a.ts.slice(11))+'</td><td>'+esc(a.what)+'</td><td>'+esc(a.who)+
'</td><td class="'+esc(a.outcome)+'">'+esc(a.outcome)+'</td></tr>').join('');}catch(e){}}
async function askQ(q){if(!q)return;$('q').value='';$('send').disabled=true;
add('me',q);const w=add('ai','');w.classList.add('spin');w.textContent='thinking + calling tools…';
try{const r=await fetch('/ask',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({q})});const d=await r.json();w.classList.remove('spin');
w.textContent=d.answer;const m=document.createElement('div');m.className='meta';
m.textContent=d.calls+' tool calls · '+d.secs+'s';w.appendChild(m);showTrace(d.trace);}
catch(e){w.textContent='error: '+e;}
$('send').disabled=false;refreshAudit();}
$('send').onclick=()=>askQ($('q').value.trim());
$('q').addEventListener('keydown',e=>{if(e.key==='Enter')askQ($('q').value.trim());});
document.querySelectorAll('.chip:not(#writebtn)').forEach(c=>c.onclick=()=>askQ(c.textContent));
$('writebtn').onclick=async()=>{$('send').disabled=true;
add('me','Open a storm claim for Maya Shapiro: fence blown down, 3200 shekels.');
const w=add('ai','');w.classList.add('spin');w.textContent='write preview → operator confirm…';
try{const d=await(await fetch('/write',{method:'POST'})).json();w.classList.remove('spin');
w.textContent=d.answer;showTrace(d.trace);}catch(e){w.textContent='error: '+e;}
$('send').disabled=false;refreshAudit();};
$('fish').onclick=async()=>{const d=await(await fetch('/fish',{method:'POST'})).json();
$('fishout').innerHTML='$ '+esc(d.sql)+'\\n'+(d.refused?'<span class="no">'+esc(d.error)
+'</span>\\nThe agent could READ that phone when authorized — but nobody can FILTER by it.'
:'<span class="no">NOT refused: '+esc(d.rows)+'</span>');};
$('dashbtn').onclick=async()=>{$('dash').style.display='block';
$('cards').innerHTML='<span class="sub">reading every store…</span>';
try{const d=await(await fetch('/dashboard')).json();
$('cards').innerHTML=d.stores.map(s=>'<div class="card" style="padding:10px 12px">'
+'<div><span style="color:'+(s.up?'var(--good)':'var(--bad)')+'">●</span> <b>'+esc(s.name)+'</b></div>'
+(s.up?Object.entries(s.counts).map(([t,n])=>'<div class="sub">'+esc(t)+': '+esc(n)+' rows</div>').join('')
:'<div class="sub">'+esc(s.error)+'</div>')+'</div>').join('');
const cols=d.split.cols, sts=d.split.stores;
$('splitt').innerHTML='<tr><th>column</th>'+sts.map(s=>'<th>'+esc(s.name)+'</th>').join('')+'</tr>'
+cols.map(c=>'<tr><td>'+esc(c)+'</td>'+sts.map(s=>{const v=s.row[c]??'—';
const hot=(c==='phone');const good=hot&&String(v).startsWith('05');
return '<td class="'+(hot?(good?'ok':'refused'):'')+'">'+esc(v)+'</td>';}).join('')+'</tr>').join('');
}catch(e){$('cards').innerHTML='<span class="sub">dashboard error: '+esc(e)+'</span>';}};
$('dashclose').onclick=()=>{$('dash').style.display='none';};
fetch('/info').then(r=>r.json()).then(d=>{$('status').textContent=
'model: '+d.model+' (local) · MCP: '+d.mcp+' · all on this machine';});
refreshAudit();
</script></body></html>"""


# ---------------------------------------------------------------- server
class Handler(BaseHTTPRequestHandler):
    def _send(self, body, ctype="application/json", code=200):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):                 # quieter console
        if "/ask" in (args[0] if args else ""):
            print(f"[webdemo] {args[0]}", flush=True)

    def do_GET(self):
        if self.path == "/":
            self._send(PAGE.encode(), "text/html; charset=utf-8")
        elif self.path == "/audit":
            try:
                self._send(audit_rows())
            except Exception as e:                     # noqa: BLE001
                self._send([{"ts": "", "what": "audit unreadable", "who": "",
                             "outcome": str(e)[:80]}])
        elif self.path == "/dashboard":
            try:
                self._send(dashboard())
            except Exception as e:                   # noqa: BLE001
                self._send({"error": str(e)[:200]}, code=500)
        elif self.path == "/info":
            self._send({"model": STATE.model,
                        "mcp": STATE.bargs.mcp_url or "local stdio"})
        else:
            self._send({"error": "not found"}, code=404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        if self.path == "/ask":
            q = (body.get("q") or "").strip()[:500]
            if not q:
                return self._send({"error": "empty question"}, code=400)
            with STATE.lock:                           # one question at a time
                fut = asyncio.run_coroutine_threadsafe(ask(q), STATE.loop)
                try:
                    return self._send(fut.result(timeout=180))
                except Exception as e:                 # noqa: BLE001
                    return self._send({"answer": f"error: {e}", "trace": [],
                                       "calls": 0, "secs": 0})
        if self.path == "/write":
            with STATE.lock:
                fut = asyncio.run_coroutine_threadsafe(write_claim(), STATE.loop)
                try:
                    return self._send(fut.result(timeout=60))
                except Exception as e:                 # noqa: BLE001
                    return self._send({"answer": f"error: {e}", "trace": [],
                                       "calls": 0, "secs": 0})
        if self.path == "/fish":
            return self._send(fish())
        if self.path == "/seed":
            A.seed()
            return self._send({"ok": True})
        self._send({"error": "not found"}, code=404)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mcp-url", default=os.environ.get("MCP_URL", ""))
    ap.add_argument("--mcp-token", default=os.environ.get("SSDB_MCP_TOKEN", ""))
    ap.add_argument("--model", default=os.environ.get("MODEL", "qwen2.5:14b"))
    ap.add_argument("--port", type=int, default=8077)
    ap.add_argument("--no-seed", action="store_true")
    args = ap.parse_args()

    STATE.model = args.model
    STATE.bargs = SimpleNamespace(mcp_url=args.mcp_url, mcp_token=args.mcp_token,
                                  server=str(HERE / "ssdb_mcp_server.py"),
                                  agent_id="webdemo", ollama=A.OLLAMA,
                                  model=args.model, max_rounds=10, verbose=False)
    if not args.no_seed:
        print("[webdemo] loading the sample data…", flush=True)
        A.seed()

    STATE.loop = asyncio.new_event_loop()
    threading.Thread(target=STATE.loop.run_forever, daemon=True).start()

    async def connect():
        STATE.mcp = await B.MCP(STATE.bargs).__aenter__()
        return len(STATE.mcp.tools)

    ntools = asyncio.run_coroutine_threadsafe(connect(), STATE.loop).result(timeout=60)
    print(f"[webdemo] MCP connected ({ntools} tools); model {args.model}", flush=True)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[webdemo] ready on http://127.0.0.1:{args.port}  "
          f"(tunnel: ssh -N -L {args.port}:localhost:{args.port} <vm>)", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
