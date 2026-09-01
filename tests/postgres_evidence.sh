#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 -f migrations/0001_statement_evidence.sql

psql -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE lrs_app LOGIN PASSWORD 'lrs-app-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT CONNECT ON DATABASE learning_record_store TO lrs_app;
GRANT USAGE ON SCHEMA public TO lrs_app;
GRANT SELECT, INSERT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation TO lrs_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO lrs_app;
INSERT INTO tenant_partition (tenant_key) VALUES ('tenant-alpha'), ('tenant-beta');
SQL

app_psql() {
  PGUSER=lrs_app PGPASSWORD=lrs-app-test psql -v ON_ERROR_STOP=1 "$@"
}

alpha_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*) FROM tenant_partition;
SQL
} | tail -n 1)"
[[ "$alpha_count" == "1" ]] || {
  echo "expected tenant-alpha to see exactly one tenant row, got: $alpha_count" >&2
  exit 1
}

unset_count="$({ app_psql -At <<'SQL'
RESET app.tenant_key;
SELECT count(*) FROM tenant_partition;
SQL
} | tail -n 1)"
[[ "$unset_count" == "0" ]] || {
  echo "expected absent tenant context to fail closed, got: $unset_count" >&2
  exit 1
}

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO statement_record (
    tenant_key,
    statement_key,
    received_xapi_version,
    statement_comparison_version,
    content_hash,
    comparison_bytes,
    raw_statement_bytes
) VALUES (
    'tenant-beta',
    'statement-cross-tenant',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    decode(repeat('11', 32), 'hex'),
    decode('aa', 'hex'),
    convert_to('{"id":"statement-cross-tenant"}', 'UTF8')
);
SQL
then
  echo "cross-tenant statement insert unexpectedly succeeded" >&2
  exit 1
fi

app_psql -v ON_ERROR_STOP=1 <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO statement_record (
    tenant_key,
    statement_key,
    received_xapi_version,
    statement_comparison_version,
    content_hash,
    comparison_bytes,
    raw_statement_bytes
) VALUES (
    'tenant-alpha',
    'statement-001',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    decode(repeat('22', 32), 'hex'),
    decode('bb', 'hex'),
    convert_to('{"id":"statement-001"}', 'UTF8')
);
SQL

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO statement_record (
    tenant_key,
    statement_key,
    received_xapi_version,
    statement_comparison_version,
    content_hash,
    comparison_bytes,
    raw_statement_bytes
) VALUES (
    'tenant-alpha',
    'statement-001',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    decode(repeat('33', 32), 'hex'),
    decode('cc', 'hex'),
    convert_to('{"id":"statement-001","conflict":true}', 'UTF8')
);
SQL
then
  echo "duplicate canonical statement identity unexpectedly succeeded" >&2
  exit 1
fi

canonical_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*) FROM statement_record WHERE statement_key = 'statement-001';
SQL
} | tail -n 1)"
[[ "$canonical_count" == "1" ]] || {
  echo "expected one canonical statement row, got: $canonical_count" >&2
  exit 1
}

psql -v ON_ERROR_STOP=1 <<'SQL'
SELECT
    c.relname AS relation_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class AS c
WHERE c.relname IN (
    'tenant_partition',
    'ingestion_receipt',
    'statement_record',
    'statement_ingestion_item',
    'voiding_relation'
)
  AND c.relkind = 'r'
  AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
SQL

rls_gap_count="$(psql -At <<'SQL'
SELECT count(*)
FROM pg_class AS c
WHERE c.relname IN (
    'tenant_partition',
    'ingestion_receipt',
    'statement_record',
    'statement_ingestion_item',
    'voiding_relation'
)
  AND c.relkind = 'r'
  AND NOT (c.relrowsecurity AND c.relforcerowsecurity);
SQL
)"
[[ "$rls_gap_count" == "0" ]] || {
  echo "expected forced RLS on every tenant relation, got $rls_gap_count gaps" >&2
  exit 1
}

echo "postgres statement evidence boundary tests passed"
