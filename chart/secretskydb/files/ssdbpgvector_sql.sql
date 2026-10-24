-- Pure-SQL equivalent of the ssdbpgvector C extension.
-- Works on ANY PostgreSQL (Supabase, Neon, RDS, CloudSQL, etc.)
-- Uses BIGINT[] instead of intvector type, NUMERIC for overflow-safe modular arithmetic.
--
-- The proxy auto-installs this on shares that lack the C extension.

-- Finite-field inner product: SUM(a[i] * b[i] mod p) mod p
-- Returns raw field element in [0, p) for Lagrange reconstruction.
-- Matches intvec_ff_inner_product() from the C extension exactly.
CREATE OR REPLACE FUNCTION ssdb_ff_inner_product(
    a BIGINT[],
    b BIGINT[],
    p BIGINT DEFAULT 2305843009213693951  -- 2^61 - 1 (Mersenne prime M61)
)
RETURNS BIGINT
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    -- unnest(a, b) instead of generate_series + a[i]/b[i]: the per-element
    -- subscripts were ~80% of the scan (4x per core measured, 1 Oct 2026,
    -- ssdb/experiments/pg/bench_ff_dot.py); the NUMERIC product itself is <5%.
    -- Arrays of unequal length: the shorter is padded with NULLs, whose
    -- products are NULL and drop out of SUM, matching LEAST(...) before.
    SELECT (
        COALESCE(
            SUM((x::NUMERIC * y::NUMERIC) % p::NUMERIC) % p::NUMERIC,
            0
        )
    )::BIGINT
    FROM unnest(a, b) AS t(x, y)
$$;

-- Inner product with sign recovery (for distance ranking).
-- Values > p/2 are treated as negative (two's complement in GF(p)).
CREATE OR REPLACE FUNCTION ssdb_inner_product(
    a BIGINT[],
    b BIGINT[],
    p BIGINT DEFAULT 2305843009213693951
)
RETURNS FLOAT8
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE
        WHEN r > p / 2 THEN (r - p)::FLOAT8
        ELSE r::FLOAT8
    END
    FROM (SELECT ssdb_ff_inner_product(a, b, p) AS r) sub
$$;

-- Negative inner product (for ORDER BY — lower = more similar).
CREATE OR REPLACE FUNCTION ssdb_negative_inner_product(
    a BIGINT[],
    b BIGINT[],
    p BIGINT DEFAULT 2305843009213693951
)
RETURNS FLOAT8
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT -ssdb_inner_product(a, b, p)
$$;

-- Vector dimensions
CREATE OR REPLACE FUNCTION ssdb_vector_dims(a BIGINT[])
RETURNS INTEGER
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT array_length(a, 1)
$$;
