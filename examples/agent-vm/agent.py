#!/usr/bin/env python3
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
"""A small agent whose database and document search are both SecretSkyDB, with a local model.

    agent.py seed        create the tables and load the sample data
    agent.py check       connectivity and an end-to-end search, no model reasoning
    agent.py ask "..."   one question; read-only unless you add --write
    agent.py chat        interactive; asks before every change to the data
    agent.py test        the question set in CASES, with pass / fail per question

The model (served by Ollama on this machine) decides which tool to call:

    search_handbook   document search (RAG). The question is embedded locally; SecretSkyDB scores
                      it against the stored vectors on the share stores, and only the best
                      passages are reassembled.
    query_database    one read-only SELECT on the customers and claims tables.
    open_claim        INSERT a claim.
    set_claim_status  UPDATE a claim.

Two safeguards that do not depend on the model behaving:
  * the read tools connect as a proxy user with the role "reader", the write tools as one with the
    role "writer"; the admin user is used only to load the sample data;
  * an amount in an answer must be found in what the tools returned (see "figure check").

The agent speaks the PostgreSQL protocol to the SecretSkyDB proxy; there is no other database.
Columns marked Secret below are stored only as shares on the three share stores.

Sample data is fictional.
"""
from __future__ import annotations

import base64
import json
import math
import os
import re
import sys
import time
import uuid
from datetime import date
from pathlib import Path

import psycopg2
import requests

HERE = Path(__file__).resolve().parent
ENV_FILE = Path(os.environ.get("AGENT_ENV", Path.home() / "ssdb-agent" / "agent.env"))


def _load_env() -> None:
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


_load_env()
SSDB = dict(
    host=os.environ.get("SSDB_HOST", "127.0.0.1"),
    port=int(os.environ.get("SSDB_PORT", "55432")),
    dbname=os.environ.get("SSDB_DB", "ssdb"),
    user=os.environ.get("SSDB_USER", "ssdb"),
    password=os.environ.get("SSDB_PASSWORD", ""),
)
# The agent's tools do not use the admin user. Reads go through a proxy user with the role
# "reader" (SELECT only), the two write tools through one with the role "writer" (no DDL); the
# proxy enforces the role, whatever SQL the model writes. vm-setup.sh creates both. Without
# them (an older setup) everything falls back to the admin user and `check` says so.
def _role_user(prefix: str) -> dict:
    u, pw = os.environ.get(f"SSDB_{prefix}_USER"), os.environ.get(f"SSDB_{prefix}_PASSWORD")
    return dict(SSDB, user=u, password=pw) if u and pw else SSDB


ROLES = {"admin": SSDB, "reader": _role_user("READER"), "writer": _role_user("WRITER")}

OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("MODEL", "qwen2.5:7b")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "all-minilm")
SCALE = 1_000_000          # unit vectors are stored as integers; score / SCALE^2 = cosine similarity
MAX_ROWS = 50
MAX_TOOL_ROUNDS = 8
KEEP_ALIVE = os.environ.get("KEEP_ALIVE", "2h")   # keep the models in memory between questions
WRITE_TOOLS = {"open_claim", "set_claim_status"}

DIM = "\033[2m" if sys.stdout.isatty() else ""
OFF = "\033[0m" if sys.stdout.isatty() else ""


# ───────────────────────────── SecretSkyDB ─────────────────────────────
def db(role: str = "admin"):
    conn = psycopg2.connect(connect_timeout=10, **ROLES[role])
    conn.autocommit = True
    return conn


def run(sql: str, args: tuple = (), fetch: bool = True, role: str = "admin"):
    """role: admin (sample data, checks), reader (everything the model reads), writer (the write tools)."""
    conn = db(role)
    try:
        with conn.cursor() as cur:
            cur.execute(sql, args or None)   # None: a literal % in the model's SQL is not a placeholder
            if fetch and cur.description:
                return [d[0] for d in cur.description], cur.fetchall()
            return [], []
    finally:
        conn.close()


def clean(v):
    """Secret text can arrive as bytes; dates and decimals are not JSON."""
    if isinstance(v, memoryview):
        v = v.tobytes()
    if isinstance(v, (bytes, bytearray)):
        return v.decode("utf-8", "replace").rstrip("\x00")
    if v is None or isinstance(v, (int, float, str, bool)):
        return v
    return str(v)


# ───────────────────────────── local model ─────────────────────────────
def embed(texts: list[str]) -> list[list[int]]:
    r = requests.post(f"{OLLAMA}/api/embed", json={"model": EMBED_MODEL, "input": texts, "keep_alive": KEEP_ALIVE}, timeout=300)
    r.raise_for_status()
    out = []
    for v in r.json()["embeddings"]:
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        out.append([int(round(x / n * SCALE)) for x in v])
    return out


def vec(v: list[int]) -> str:
    return "[" + ",".join(str(x) for x in v) + "]"


def chat(messages: list[dict], tools: list[dict]) -> dict:
    r = requests.post(
        f"{OLLAMA}/api/chat",
        json={"model": MODEL, "messages": [{k: v for k, v in m.items() if k != "_check"} for m in messages], "stream": False, "keep_alive": KEEP_ALIVE,
              "options": {"temperature": 0, "num_ctx": 8192}, **({"tools": tools} if tools else {})},
        timeout=900,
    )
    r.raise_for_status()
    return r.json()["message"]


# ───────────────────────────── tools ─────────────────────────────
def search_handbook(query: str, k: int = 4) -> dict:
    """Two steps, as the proxy's vector queries require: score every passage on the shares
    (only the id next to the score, no ORDER BY), sort here, then fetch the best passages by id."""
    q = embed([query])[0]
    _, rows = run(f'SELECT "_id"::text, intvec_ff_inner_product("emb", \'{vec(q)}\'::intvector) AS score '
                  f'FROM "handbook_chunk";', role="reader")
    top = sorted((r for r in rows if r[1] is not None), key=lambda r: r[1], reverse=True)[:k]
    passages = []
    for cid, score in top:
        _, got = run('SELECT "title","chunk" FROM "handbook_chunk" WHERE "_id"::text = %s;', (cid,), role="reader")
        if got:
            passages.append({"title": clean(got[0][0]), "text": clean(got[0][1]),
                             "similarity": round(float(score) / (SCALE * SCALE), 3)})
    return {"passages_scanned": len(rows), "passages": passages}


_FORBIDDEN = re.compile(r"\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|copy|comment|call|do|set)\b", re.I)


def query_database(sql: str) -> dict:
    s = sql.strip().rstrip(";").strip()
    if not re.match(r"(?is)^select\b", s) or ";" in s or _FORBIDDEN.search(s):
        return {"error": "only a single SELECT statement is allowed"}
    if not re.search(r"(?i)\b(customers|claims)\b", s) or re.search(r"(?i)\b(pg_|information_schema|handbook_chunk)", s):
        return {"error": "query the customers and claims tables only"}
    try:
        try:
            cols, rows = run(s + ";", role="reader")
        except psycopg2.Error as e:
            # Proxy fault in 0.4.0 (fixed in 0.4.1): a literal % (a LIKE pattern) in a single-table
            # SELECT that reads a Secret column is taken for a parameter placeholder. Doubling it
            # gets through.
            if "allowed as placeholders" not in str(e) or "%" not in s:
                raise
            cols, rows = run(s.replace("%", "%%") + ";", role="reader")
    except Exception as e:  # the model reads the error and can correct its query
        err = str(e).strip().splitlines()[0][:300]
        m = re.search(r'Secret column "?(\w+)"? cannot be used in a filter or join', err)
        if m:
            # 0.4.0 words this as "reconstruction failed (cluster degraded)", which makes a model
            # give up (0.4.1 reports the refusal itself); say what to do
            err = (f"Query not run. The column {m.group(1)} is Secret: it can be SELECTed, but it may not appear in "
                   f"WHERE, JOIN, GROUP BY or ORDER BY (not even 'IS NOT NULL'). The data is available: "
                   f"run the same query again without the condition on {m.group(1)}.")
        return {"error": err}
    return {"columns": cols, "rows": [[clean(v) for v in r] for r in rows[:MAX_ROWS]],
            "row_count": len(rows), "truncated": len(rows) > MAX_ROWS}


def open_claim(customer_id: str, customer_name: str, kind: str, description: str, amount_ils: int) -> dict:
    _, rows = run("SELECT name FROM customers WHERE id = %s;", (customer_id,), role="reader")
    if not rows:
        return {"error": f"no customer with id {customer_id}"}
    # a write needs the id and the name to agree, so a guessed id cannot open a claim for the wrong person
    if clean(rows[0][0]).strip().lower() != str(customer_name).strip().lower():
        return {"error": f"id {customer_id} belongs to {clean(rows[0][0])}, not to {customer_name}. "
                         "Look the customer up with query_database and use the id it returns."}
    cid = "CL-" + uuid.uuid4().hex[:6].upper()
    run("INSERT INTO claims (id, customer_id, opened, status, kind, amount_ils, description) "
        "VALUES (%s,%s,%s,'open',%s,%s,%s);",
        (cid, customer_id, date.today().isoformat(), kind, int(amount_ils), description), fetch=False, role="writer")
    return {"claim_id": cid, "customer": clean(rows[0][0]), "status": "open"}


def set_claim_status(claim_id: str, status: str) -> dict:
    if status not in ("open", "in_review", "approved", "rejected", "paid"):
        return {"error": "status must be one of open, in_review, approved, rejected, paid"}
    _, rows = run("SELECT id FROM claims WHERE id = %s;", (claim_id,), role="reader")
    if not rows:
        return {"error": f"no claim with id {claim_id}"}
    run("UPDATE claims SET status = %s WHERE id = %s;", (status, claim_id), fetch=False, role="writer")
    return {"claim_id": claim_id, "status": status}


TOOL_IMPL = {"search_handbook": search_handbook, "query_database": query_database,
             "open_claim": open_claim, "set_claim_status": set_claim_status}


def _fn(name, desc, props, required):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": required}}}


TOOLS = [
    _fn("search_handbook", "Search the insurance handbook for what the policy covers, limits, deductibles, "
        "deadlines and procedures. Use it for any question about rules or coverage.",
        {"query": {"type": "string", "description": "what to look for, in plain words"}}, ["query"]),
    _fn("query_database", "Run ONE read-only SQL SELECT on the tables customers and claims.",
        {"sql": {"type": "string", "description": "a single PostgreSQL SELECT statement"}}, ["sql"]),
    _fn("open_claim", "Open a new claim for a customer.",
        {"customer_id": {"type": "string", "description": "the id returned by query_database for this customer"},
         "customer_name": {"type": "string", "description": "the customer's full name, as stored"}, "kind": {"type": "string", "description": "water, theft, fire, storm or other"},
         "description": {"type": "string"}, "amount_ils": {"type": "integer", "description": "claimed amount in shekels"}},
        ["customer_id", "customer_name", "kind", "description", "amount_ils"]),
    _fn("set_claim_status", "Change the status of a claim.",
        {"claim_id": {"type": "string"},
         "status": {"type": "string", "description": "open, in_review, approved, rejected or paid"}},
        ["claim_id", "status"]),
]

SYSTEM = """You are the service-desk assistant of Galil Home Insurance. Answer from the tools only; never guess.

There are exactly two tables (PostgreSQL). There is no other table.
  customers(id, name, city, plan, phone, national_id, notes)
      plan is a column of customers: basic, plus or premium. phone, national_id and notes are Secret.
  claims(id, customer_id, opened, status, kind, amount_ils, description)
      status is one of open, in_review, approved, rejected, paid. kind is water, theft, fire, storm or other.
      amount_ils and description are Secret.

Write simple queries. Examples:
  SELECT id, name, plan FROM customers WHERE name ILIKE '%levi%'
  SELECT id, opened, status, kind, amount_ils, description FROM claims WHERE customer_id = 'C-101'
Secret columns can be selected and summed (SELECT sum(amount_ils) FROM claims WHERE status = 'open'), but
never put a Secret column in WHERE, JOIN, GROUP BY or ORDER BY, not even as "IS NOT NULL".
When a question names a customer, first read that customer's row (id, plan, notes), and when it is about
damage, a claim or cover, also read that customer's claims.
When someone asks about a customer's "open" or "current" claims, list every claim that is not paid or
rejected (open, in_review, approved) and state the status of each.

Coverage rules, limits, deductibles and deadlines are in the handbook. Call search_handbook once per topic
(for example once for "water damage" and once for "deductible"), and name the section each fact comes from.
Amounts that depend on the plan: look up the customer's plan first, then give the figure for that plan
exactly as the handbook states it. A special case (such as a doubled deductible) is a condition to mention,
not the figure to give.

Change data (open_claim, set_claim_status) ONLY when the user explicitly asks you to open a claim or to
change a status. A question such as "is it covered?" or "how much?" is never a request to open a claim:
answer it and change nothing. Before open_claim, look the customer up to get the id.
Keep answers short and concrete."""


def _write_allowed(name: str, args: dict, writes: str) -> str:
    """'' = go ahead; otherwise the reason handed back to the model."""
    if writes == "allow":
        return ""
    if writes == "confirm":
        try:
            a = input(f"  The agent wants to change data: {name} {json.dumps(args, ensure_ascii=False)}\n  Allow? [y/N] ")
        except (EOFError, KeyboardInterrupt):
            a = ""
        return "" if a.strip().lower() in ("y", "yes") else "the user declined this change; do not retry it"
    return ("this run is read-only: no data may be changed. Answer the question from what you can read "
            "and say that nothing was changed.")


# ───────────────────────────── figure check ─────────────────────────────
# A model that skips a search still writes a confident number (it gave 800 for a deductible the
# handbook puts at 400). So before an answer goes out, every amount in it must be found in what
# the tools returned in this conversation or in the user's own words, or follow from two such
# numbers as their sum, or be the double of one (the handbook doubles a deductible). If one is not, the model is told which,
# and to look it up; after FIGURE_RETRIES such rounds the answer goes out with the figure named
# as unconfirmed. Identifiers, dates and phone numbers (digits joined by "-") and numbers below
# FIGURE_MIN (counts, days) are not checked.
FIGURE_MIN = 100
FIGURE_RETRIES = 2
_ANSWER_FIGURE = re.compile(r"(?<![\w.-])\d[\d,]*(?:\.\d+)?(?![\w-]|\.\d)")
_ANY_NUMBER = re.compile(r"\d[\d,]*(?:\.\d+)?")


def _num(tok: str):
    try:
        return float(tok.replace(",", "").rstrip("."))
    except ValueError:
        return None


def _evidence_numbers(messages: list[dict]) -> set:
    """Every number the tools returned or the user wrote (not the system text, not the model's own turns)."""
    out = set()
    for m in messages:
        if m.get("role") in ("tool", "user"):
            out.update(v for v in (_num(t) for t in _ANY_NUMBER.findall(str(m.get("content") or ""))) if v is not None)
    return out


def unsupported_figures(text: str, evidence: set) -> list[str]:
    """The amounts in ``text`` that neither appear in ``evidence`` nor follow from it."""
    big = [e for e in evidence if e >= 1]
    derived = set(evidence) | {e * 2 for e in big}
    bad = []
    for tok in _ANSWER_FIGURE.findall(text):
        v = _num(tok)
        if v is None or v < FIGURE_MIN or v in derived:
            continue
        if len(big) <= 400 and any((v - a) in evidence for a in big):
            continue                                   # the sum of two retrieved numbers
        shown = tok.rstrip(".,")
        if shown not in bad:
            bad.append(shown)
    return bad


def claims_not_read(messages: list[dict]) -> bool:
    """The same idea for a statement of absence ("she has no open claims", said without looking):
    the question is about a claim, a customer was looked up for it, and no query since that
    question read the claims table. A turn that used a write tool is left alone."""
    last = max((i for i, m in enumerate(messages) if m.get("role") == "user" and not m.get("_check")), default=-1)
    if last < 0 or not re.search(r"(?i)\bclaims?\b", str(messages[last].get("content") or "")):
        return False
    read = set()
    for m in messages[last:]:
        for c in m.get("tool_calls") or []:
            fn = c.get("function") or {}
            if fn.get("name") in WRITE_TOOLS:
                return False
            if fn.get("name") == "query_database":
                read.update(t.lower() for t in re.findall(r"(?i)\b(customers|claims)\b", str(fn.get("arguments"))))
    return "customers" in read and "claims" not in read


def answer(messages: list[dict], writes: str = "deny") -> str:
    """writes: 'deny' (read-only), 'confirm' (ask the person at the terminal) or 'allow'."""
    figure_rounds, claims_asked = 0, False
    for _ in range(MAX_TOOL_ROUNDS + FIGURE_RETRIES):
        msg = chat(messages, TOOLS)
        messages.append(msg)
        calls = msg.get("tool_calls") or []
        if not calls:
            text = (msg.get("content") or "").strip()
            if text and not claims_asked and claims_not_read(messages):
                claims_asked = True
                print(f"{DIM}  claims check: the question is about a claim and the claims table was not read; asking the model to read it{OFF}", flush=True)
                messages.append({"role": "user", "_check": True, "content":
                                 "Check before answering: the question is about a claim, and you have not read the claims "
                                 "table. Query claims for this customer (by customer_id) with query_database, then give the "
                                 "complete answer again, stating each claim that is not paid or rejected with its status."})
                continue
            if text:
                bad = unsupported_figures(text, _evidence_numbers(messages))
                if not bad:
                    return text
                if figure_rounds >= FIGURE_RETRIES:
                    return text + "\n\n(Not confirmed by the handbook or the database: " + ", ".join(bad) + ".)"
                figure_rounds += 1
                print(f"{DIM}  figure check: {', '.join(bad)} is not in anything retrieved; asking the model to look it up{OFF}", flush=True)
                messages.append({"role": "user", "_check": True, "content":
                                 "Check before answering: the figure(s) " + ", ".join(bad) + " in your answer do not appear in "
                                 "anything the tools returned in this conversation. Do not state a figure from memory. Call "
                                 "search_handbook for the rule that gives the figure (for example \"deductible\" or the limit "
                                 "in question) or query_database for the data, then give the complete answer again with the "
                                 "figures exactly as retrieved."})
                continue
            # some local models now and then return an empty turn instead of a tool call
            messages.pop()
            messages.append({"role": "user", "content": "Go on: call the tools you need, then answer."})
            continue
        for c in calls:
            name = c["function"]["name"]
            args = c["function"].get("arguments") or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except ValueError:
                    args = {}
            shown = json.dumps(args, ensure_ascii=False)
            print(f"{DIM}  → {name} {shown[:200]}{OFF}", flush=True)
            t0 = time.time()
            try:
                refused = _write_allowed(name, args, writes) if name in WRITE_TOOLS else ""
                if refused:
                    result = {"error": refused}
                else:
                    result = TOOL_IMPL[name](**args) if name in TOOL_IMPL else {"error": f"unknown tool {name}"}
            except TypeError as e:
                result = {"error": f"bad arguments: {e}"}
            except Exception as e:
                result = {"error": str(e).strip().splitlines()[0][:300]}
            note = result.get("error") or (f"{result['row_count']} rows" if "row_count" in result else
                                           f"{len(result['passages'])} passages" if "passages" in result else "done")
            print(f"{DIM}    {note} ({time.time() - t0:.1f} s){OFF}", flush=True)
            messages.append({"role": "tool", "tool_name": name, "content": json.dumps(result, ensure_ascii=False)})
    return "I could not finish within the allowed number of steps."


# ───────────────────────────── sample data ─────────────────────────────
CUSTOMERS = [
    ("C-101", "Dana Levi", "Haifa", "plus", "054-555-0101", "000000018", "Prefers phone calls after 17:00."),
    ("C-102", "Yossi Mizrahi", "Tiberias", "basic", "052-555-0102", "000000026", "Second apartment rented out."),
    ("C-103", "Noa Friedman", "Karmiel", "premium", "050-555-0103", "000000034", "Home office with equipment."),
    ("C-104", "Amir Haddad", "Nazareth", "plus", "053-555-0104", "000000042", "Ground floor, garden."),
    ("C-105", "Tamar Cohen", "Safed", "premium", "054-555-0105", "000000059", "Stone house built in 1930."),
    ("C-106", "Eli Ben-David", "Haifa", "basic", "058-555-0106", "000000067", "New customer since March."),
    ("C-107", "Maya Shapiro", "Akko", "plus", "052-555-0107", "000000075", "Two dogs."),
    ("C-108", "Omar Khoury", "Haifa", "premium", "050-555-0108", "000000083", "Jewellery rider on file."),
]
CLAIMS = [
    ("CL-9001", "C-101", "2026-10-02", "in_review", "water", 18500, "Burst pipe under the kitchen sink, parquet floor damaged."),
    ("CL-9002", "C-101", "2026-03-14", "paid", "storm", 4200, "Roof tiles blown off in the March storm."),
    ("CL-9003", "C-102", "2026-09-20", "rejected", "water", 9000, "Damp wall from slow seepage over several months."),
    ("CL-9004", "C-103", "2026-10-28", "open", "theft", 32000, "Break-in through the balcony, two laptops and a camera taken."),
    ("CL-9005", "C-104", "2026-08-05", "approved", "fire", 15700, "Kitchen fire from a faulty oven, cabinets and ceiling."),
    ("CL-9006", "C-105", "2026-11-01", "open", "water", 27000, "Water heater on the roof burst, ceiling of the bedroom collapsed."),
    ("CL-9007", "C-107", "2026-07-11", "paid", "other", 2300, "Window broken by a ball from the street."),
    ("CL-9008", "C-108", "2026-10-15", "in_review", "theft", 61000, "Jewellery missing after renovation works."),
    ("CL-9009", "C-106", "2026-11-05", "open", "storm", 6800, "Pergola collapsed in strong wind."),
    ("CL-9010", "C-104", "2026-02-22", "paid", "water", 5100, "Washing machine hose came off, neighbour's ceiling stained."),
]


def handbook_sections() -> list[tuple[str, str]]:
    text = (HERE / "handbook.md").read_text(encoding="utf-8")
    out = []
    for block in re.split(r"(?m)^## ", text)[1:]:
        title, _, body = block.partition("\n")
        out.append((title.strip(), " ".join(body.split())))
    return out


def seed() -> None:
    sections = handbook_sections()
    print(f"embedding {len(sections)} handbook sections with {EMBED_MODEL}")
    embs = embed([f"{t}. {b}" for t, b in sections])
    dim = len(embs[0])
    tables = ("handbook_chunk", "claims", "customers")

    def exists(t):
        try:
            run(f'SELECT count(*) FROM "{t}";')
            return True
        except psycopg2.Error:
            return False

    if all(exists(t) for t in tables) and os.environ.get("RESEED") != "drop":
        # a reload: empty the tables and keep them. (Dropping a table and creating it again
        # right away can reach a share store in the wrong order; RESEED=drop forces it, for a
        # change of embedding model, and the creation below is retried.)
        for t in tables:
            run(f'DELETE FROM "{t}";', fetch=False)
        _fill(sections, embs, dim)
        return
    for t in tables:
        run(f'DROP TABLE IF EXISTS "{t}";', fetch=False)
    time.sleep(5)
    # Each table is created together with its Secret markings, in one batch, so that a column
    # is never created as an ordinary one first (the vector column could not be: the share
    # stores have no vector type, a Secret vector is stored there as shares of its numbers).
    ddl = [
        "CREATE TABLE customers (id TEXT PRIMARY KEY, name TEXT, city TEXT, plan TEXT, phone TEXT, national_id TEXT, notes TEXT);"
        " COMMENT ON COLUMN customers.phone IS 'SSDB: secret';"
        " COMMENT ON COLUMN customers.national_id IS 'SSDB: secret';"
        " COMMENT ON COLUMN customers.notes IS 'SSDB: secret';",
        "CREATE TABLE claims (id TEXT PRIMARY KEY, customer_id TEXT, opened DATE, status TEXT, kind TEXT, amount_ils BIGINT, description TEXT);"
        " COMMENT ON COLUMN claims.amount_ils IS 'SSDB: secret';"
        " COMMENT ON COLUMN claims.description IS 'SSDB: secret';",
        f'CREATE TABLE "handbook_chunk" ("_id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "seq" INT, "title" TEXT, "emb" intvector({dim}), "chunk" TEXT);'
        ' COMMENT ON COLUMN "handbook_chunk"."emb" IS \'SSDB: secret\';'
        ' COMMENT ON COLUMN "handbook_chunk"."chunk" IS \'SSDB: secret\';',
    ]
    for stmt in ddl:
        for attempt in range(6):
            try:
                run(stmt, fetch=False)
                break
            except psycopg2.Error:
                if attempt == 5:
                    raise
                time.sleep(5)
    _fill(sections, embs, dim)


def _fill(sections, embs, dim) -> None:
    for c in CUSTOMERS:
        run("INSERT INTO customers (id, name, city, plan, phone, national_id, notes) VALUES (%s,%s,%s,%s,%s,%s,%s);", c, fetch=False)
    for c in CLAIMS:
        run("INSERT INTO claims (id, customer_id, opened, status, kind, amount_ils, description) VALUES (%s,%s,%s,%s,%s,%s,%s);", c, fetch=False)
    for i, ((title, body), e) in enumerate(zip(sections, embs)):
        # the vector cast comes before the text: the proxy drops '--' line comments before it reads a
        # statement, and a text ending in a line that starts with '--' would otherwise hide the cast
        run('INSERT INTO "handbook_chunk" ("seq","title","emb","chunk") VALUES (%s,%s,%s::intvector,%s);',
            (i, title, vec(e), body), fetch=False)
    print(f"loaded {len(CUSTOMERS)} customers, {len(CLAIMS)} claims, {len(sections)} handbook sections ({dim}-d vectors)")
    # the proxy acknowledges a write and then distributes the shares; give that a moment
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if len(search_handbook("burst pipe water damage", k=1)["passages"]) == 1:
                return
        except Exception:
            pass
        time.sleep(2)
    raise SystemExit("the handbook is loaded but the vector search returns nothing; run: agent.py check")


def check() -> None:
    ok = True

    def line(name, fn):
        nonlocal ok
        try:
            print(f"  ok    {name}: {fn()}")
        except Exception as e:
            ok = False
            print(f"  FAIL  {name}: {str(e).strip().splitlines()[0][:200]}")

    line("SecretSkyDB proxy", lambda: f"{SSDB['host']}:{SSDB['port']}, " + str(run("SELECT count(*) FROM customers;")[1][0][0]) + " customers, "
         + str(run("SELECT count(*) FROM claims;")[1][0][0]) + " claims")
    line("secret column read", lambda: "phone of C-101 = " + str(clean(run("SELECT phone FROM customers WHERE id = 'C-101';")[1][0][0])))
    def roles():
        if ROLES["reader"] is SSDB or ROLES["writer"] is SSDB:
            raise RuntimeError("no reader / writer users in agent.env: the tools run as the admin user (run vm-setup.sh again)")
        n = run("SELECT count(*) FROM claims;", role="reader")[1][0][0]
        try:   # changes nothing even if it were allowed: no claim has this id
            run("UPDATE claims SET status = 'open' WHERE id = 'no-such-claim';", fetch=False, role="reader")
        except psycopg2.Error as e:
            refused = str(e).strip().splitlines()[0][:80]
        else:
            raise RuntimeError(f"the reader user {ROLES['reader']['user']} was allowed to run an UPDATE")
        try:
            run("CREATE TABLE agent_role_probe (x int);", fetch=False, role="writer")
        except psycopg2.Error:
            pass
        else:
            run("DROP TABLE agent_role_probe;", fetch=False)
            raise RuntimeError(f"the writer user {ROLES['writer']['user']} was allowed to run DDL")
        return (f"reads as {ROLES['reader']['user']} ({n} claims visible, UPDATE refused: {refused}); "
                f"writes as {ROLES['writer']['user']} (DDL refused)")
    line("least privilege", roles)
    line("model server", lambda: ", ".join(m["name"] for m in requests.get(f"{OLLAMA}/api/tags", timeout=10).json()["models"]))

    def where():
        chat([{"role": "user", "content": "Reply with the single word: ready"}], [])
        for m in requests.get(f"{OLLAMA}/api/ps", timeout=10).json().get("models", []):
            if m.get("name", "").split(":")[0] == MODEL.split(":")[0]:
                share = (m.get("size_vram") or 0) / (m.get("size") or 1)
                return f"{MODEL} loaded, {round(share * 100)}% on GPU" if share > 0 else f"{MODEL} loaded, on CPU (no GPU)"
        return f"{MODEL} answered"
    line("chat model", where)

    def rag():
        r = search_handbook("is a burst pipe covered", k=1)
        p = r["passages"][0]
        return f"top of {r['passages_scanned']} passages = \"{p['title']}\" (similarity {p['similarity']})"
    line("document search on the shares", rag)
    if not ok:
        raise SystemExit(1)


# ───────────────────────────── question set ─────────────────────────────
# Each case: the question, whether changes are allowed, what the answer must contain (every
# group needs at least one of its phrases; commas in numbers are ignored), and optionally a
# check of the database afterwards. Run after any change to the model or the instructions.
def _claims() -> dict:
    return {r[0]: r for r in run("SELECT id, customer_id, status, kind, amount_ils FROM claims;")[1]}


def _new_claim(before, after, customer, amount):
    new = [after[k] for k in after if k not in before]
    return len(new) == 1 and new[0][1] == customer and int(new[0][4]) == amount


CASES = [
    dict(q="Does Dana Levi have an open claim, and is a burst pipe covered on her plan? What deductible applies?",
         want=[["900"], ["in review", "in_review"], ["covered"]]),
    dict(q="Omar Khoury's jewellery was stolen during renovation works. Is it covered, and up to how much?",
         want=[["10000", "61000", "rider"], ["premium"]]),
    dict(q="Tamar Cohen's water heater burst. Is that covered, and what is her deductible?",
         want=[["400"], ["covered"]]),
    dict(q="Is earthquake damage covered for Yossi Mizrahi?",
         want=[["not covered", "not included", "is not", "isn't", "does not", "no,", "optional"]]),
    dict(q="By when must a claim be reported, and how fast is an approved claim paid?",
         want=[["30"], ["14"]]),
    dict(q="What is Noa Friedman's phone number?", want=[["050-555-0103"]]),
    dict(q="Which customers live in Haifa?", want=[["dana levi"], ["eli ben-david"], ["omar khoury"]]),
    dict(q="How many claims have the status paid?", want=[["3", "three"]]),
    dict(q="What is the total amount of the claims whose status is open?", want=[["65800"]]),
    dict(q="Open a storm claim for Maya Shapiro: fence blown down, 3200 shekels.", writes="allow",
         want=[["cl-"]], db=lambda b, a: _new_claim(b, a, "C-107", 3200), db_note="one new claim for C-107, 3200"),
    dict(q="Set claim CL-9004 to in review.", writes="allow", want=[],
         db=lambda b, a: a["CL-9004"][2] == "in_review" and len(a) == len(b), db_note="CL-9004 is in_review"),
]


def run_cases() -> None:
    print("reloading the sample data, so every run starts from the same state")
    seed()
    passed, t_all = 0, time.time()
    for n, c in enumerate(CASES, 1):
        writes = c.get("writes", "deny")
        before, t0 = _claims(), time.time()
        print(f"\n[{n}/{len(CASES)}] {c['q']}")
        try:
            text = answer([{"role": "system", "content": SYSTEM}, {"role": "user", "content": c["q"]}], writes)
        except Exception as e:
            text = f"(error: {e})"
        time.sleep(3)   # the shares follow a write by a moment
        after = _claims()
        flat = text.lower().replace(",", "")
        missing = [g for g in c["want"] if not any(w in flat for w in g)]
        problems = [f"answer lacks {' / '.join(g)}" for g in missing]
        if "db" in c:
            if not c["db"](before, after):
                problems.append(f"database check failed ({c['db_note']})")
        elif {k: tuple(v) for k, v in after.items()} != {k: tuple(v) for k, v in before.items()}:
            problems.append("the data was changed although nothing asked for it")
        ok = not problems
        passed += ok
        print("    " + " ".join(text.split())[:400])
        print(f"  {'PASS' if ok else 'FAIL'} ({time.time() - t0:.0f} s)" + ("" if ok else ": " + "; ".join(problems)))
    print(f"\n{passed} of {len(CASES)} passed with {MODEL} in {time.time() - t_all:.0f} s")
    raise SystemExit(0 if passed == len(CASES) else 1)


# ───────────────────────────── entry ─────────────────────────────
def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "seed":
        seed()
    elif cmd == "check":
        check()
    elif cmd == "ask":
        rest = sys.argv[2:]
        writes = "deny"
        if rest[:1] == ["--write"]:
            writes, rest = "allow", rest[1:]
        q = base64.b64decode(rest[1]).decode("utf-8") if rest[:1] == ["--b64"] and len(rest) > 1 else " ".join(rest)
        if not q.strip():
            raise SystemExit('usage: agent.py ask [--write] "question"')
        print(answer([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}], writes))
    elif cmd == "chat":
        print(f"Agent on SecretSkyDB, model {MODEL} (local). Empty line or Ctrl-D to leave.")
        messages = [{"role": "system", "content": SYSTEM}]
        while True:
            try:
                q = input("\nyou> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not q:
                break
            messages.append({"role": "user", "content": q})
            print("\n" + answer(messages, "confirm"))
    elif cmd == "test":
        run_cases()
    else:
        print(__doc__)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
