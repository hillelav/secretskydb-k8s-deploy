# SecretSkyDB — Third-Party Notices

**Applies to:** SecretSkyDB container images and Helm chart, release 0.3.0 (Google Cloud Marketplace), and later releases until superseded.
**Last updated:** 23 October 2026. Contact: legal@secretskydb.com

This file lists the third-party and open-source components distributed with the Software, with their licenses, as
referred to in Section 5 of the SecretSkyDB End User License Agreement. Those components are governed by their own
license terms, which are not altered by the EULA. Components under LGPL or similar licenses are used unmodified as
separately installed libraries; their source code is available from the upstream locations listed. Copies of the
license texts are available from the upstream projects or on request from legal@secretskydb.com.

Package versions below are those resolved for the 0.3.0 build; a rebuild of the same release may pick up newer patch
versions of the same packages under the same licenses.

## 1. Proxy image

**Base image:** `gcr.io/distroless/python3-debian12` (GoogleContainerTools distroless, Apache-2.0), with Debian 12
packages updated from `debian:12-slim`: glibc (LGPL-2.1-or-later), OpenSSL 3 (Apache-2.0), MIT Kerberos krb5 (MIT),
expat (MIT), xz / liblzma (0BSD / public domain), Python 3.11 (PSF-2.0). Debian package licenses are recorded in each
package's `copyright` file under `/usr/share/doc` in the base image.

**Python packages** (installed from PyPI into the image):

| Package | Version | License | Source |
|---|---|---|---|
| annotated-doc | 0.0.5 | MIT | https://github.com/fastapi/annotated-doc |
| annotated-types | 0.8.0 | MIT | https://github.com/annotated-types/annotated-types |
| anyio | 4.15.1 | MIT | https://pypi.org/project/anyio/ |
| buenavista | 0.5.0 | Apache-2.0 | https://github.com/jwills/buenavista |
| certifi | 2026.10.19 | MPL-2.0 | https://github.com/certifi/python-certifi |
| charset-normalizer | 3.5.2 | MIT | https://pypi.org/project/charset-normalizer/ |
| dnspython | 2.9.0 | ISC | https://pypi.org/project/dnspython/ |
| fastapi | 0.161.1 | MIT | https://github.com/fastapi/fastapi |
| galois | 0.4.11 | MIT | https://github.com/mhostetter/galois |
| idna | 3.20 | BSD-3-Clause | https://github.com/kjd/idna |
| llvmlite | 0.50.0 | BSD-2-Clause AND Apache-2.0 WITH LLVM-exception | http://llvmlite.readthedocs.io |
| mpmath | 1.3.0 | BSD-3-Clause | http://mpmath.org/ |
| numba | 0.68.0 | BSD-3-Clause | https://numba.pydata.org |
| numpy | 2.4.6 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | https://pypi.org/project/numpy/ |
| opentelemetry-api | 1.45.1 | Apache-2.0 | https://github.com/open-telemetry/opentelemetry-python/tree/main/opentelemetry-api |
| pandas | 2.3.3 | BSD-3-Clause | https://pypi.org/project/pandas/ |
| psycopg | 3.3.6 | LGPL-3.0-only | https://psycopg.org/ |
| psycopg-binary | 3.3.6 | LGPL-3.0-only | https://psycopg.org/ |
| psycopg-pool | 3.3.3 | LGPL-3.0-only | https://psycopg.org/ |
| pydantic | 2.14.1 | MIT | https://github.com/pydantic/pydantic |
| pydantic_core | 2.50.1 | MIT | https://github.com/pydantic/pydantic |
| pymongo | 4.19.0 | Apache-2.0 | https://www.mongodb.org |
| python-dateutil | 2.9.0.post0 | Apache-2.0 OR BSD-3-Clause | https://github.com/dateutil/dateutil |
| pytz | 2026.5 | MIT | http://pythonhosted.org/pytz |
| requests | 2.34.2 | Apache-2.0 | https://github.com/psf/requests |
| six | 1.17.0 | MIT | https://github.com/benjaminp/six |
| sqlglot | 30.24.0 | MIT | https://sqlglot.com/ |
| starlette | 1.9.0 | BSD-3-Clause | https://github.com/Kludex/starlette |
| sympy | 1.14.0 | BSD-3-Clause | https://sympy.org |
| typing-inspection | 0.4.4 | MIT | https://github.com/pydantic/typing-inspection |
| typing_extensions | 4.16.0 | PSF-2.0 | https://pypi.org/project/typing_extensions/ |
| tzdata | 2026.5 | Apache-2.0 | https://github.com/python/tzdata |
| urllib3 | 2.8.0 | MIT | https://pypi.org/project/urllib3/ |

Notes:
- **psycopg, psycopg-binary, psycopg-pool** (LGPL-3.0-only) are used unmodified as dynamically imported libraries.
  Source: https://github.com/psycopg/psycopg. The `psycopg-binary` wheel bundles **libpq** (PostgreSQL License) and
  **OpenSSL 3.5** (Apache-2.0).
- **llvmlite** and **numba** bundle parts of **LLVM** (Apache-2.0 WITH LLVM-exception).
- **numpy** bundles **OpenBLAS** (BSD-3-Clause) in its wheel.

**Build-time only, not present in the shipped image:** Cython 3.2.9 (Apache-2.0), GCC (GPL-3.0-or-later with
runtime-library exception), pip and setuptools (MIT), `python:3.11-slim-bookworm` builder image.

## 2. Cache image

**Base image:** `postgres:16-alpine` (Docker official image, MIT for the image scripts), containing
**PostgreSQL 16** (PostgreSQL License) and **Alpine Linux** packages (musl libc MIT, BusyBox GPL-2.0-only, OpenSSL
Apache-2.0, zlib Zlib, and others under their respective licenses as recorded by `apk`).

Added, built from source:
- **wal2json** — BSD-3-Clause — https://github.com/eulerto/wal2json (logical-decoding output plugin).
- **gosu** — Apache-2.0 — https://github.com/tianon/gosu, built with the Go 1.26.9 toolchain; the Go standard
  library is BSD-3-Clause.

## 3. Deployer image

**Base image:** `gcr.io/cloud-marketplace-tools/k8s/deployer_helm` (Google Cloud Marketplace tools, Apache-2.0,
https://github.com/GoogleCloudPlatform/marketplace-k8s-app-tools) on Ubuntu packages under their respective licenses.

Replaced with from-source builds using the Go 1.26.9 toolchain:
- **Helm** — Apache-2.0 — https://github.com/helm/helm
- **kubectl** (Kubernetes) — Apache-2.0 — https://github.com/kubernetes/kubernetes
- Go standard library — BSD-3-Clause — https://go.dev

## 4. Usage-metering agent image

- **ubbagent** — Apache-2.0 — https://github.com/GoogleCloudPlatform/ubbagent, built from source with the Go
  1.26.9 toolchain (Go standard library BSD-3-Clause).

## 5. Helm chart and deployment scripts

The chart, schema and scripts are SecretSkyDB's own work and contain no third-party code beyond standard Kubernetes
API objects.

## 6. SecretSkyDB components

Everything not listed above — the proxy, reassembly engine, secret-sharing and relay extensions, cache integration,
dashboard and tools — is proprietary to SECRETSKYDB LTD and licensed under the EULA. It is not open source.
