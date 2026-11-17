#!/usr/bin/env python3
#
# SecretSkyDB deployment assets — Copyright (c) 2026 SECRETSKYDB LTD.
# Licensed under the Apache License, Version 2.0.
"""Make the agent's two proxy users (vm-setup.sh runs this on the VM).

    agent_reader   role reader: SELECT only            -> everything the model reads
    agent_writer   role writer: + INSERT/UPDATE/DELETE -> the two write tools; no DDL

Prints the users file for the proxy on stdout (chart value users.existingSecret, key
users.json). It holds SCRAM-SHA-256 verifiers only: the proxy can check a login with one, not
make one. The passwords are written to the file named by USERS_ENV, for the agent.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets


def verifier(password: str, iterations: int = 4096) -> str:
    """PostgreSQL's verifier format: SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>."""
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    stored = hashlib.sha256(hmac.new(salted, b"Client Key", hashlib.sha256).digest()).digest()
    server = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b = lambda x: base64.b64encode(x).decode()
    return f"SCRAM-SHA-256${iterations}:{b(salt)}${b(stored)}:{b(server)}"


def main() -> None:
    users, env = [], []
    for name, role in (("agent_reader", "reader"), ("agent_writer", "writer")):
        pw = secrets.token_urlsafe(24)
        users.append({"name": name, "role": role, "scram": verifier(pw)})
        env += [f"SSDB_{role.upper()}_USER={name}", f"SSDB_{role.upper()}_PASSWORD={pw}"]
    with open(os.environ["USERS_ENV"], "w", encoding="utf-8") as f:
        f.write("\n".join(env) + "\n")
    print(json.dumps({"users": users}))


if __name__ == "__main__":
    main()
