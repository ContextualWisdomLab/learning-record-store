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
    sha256(decode('aa', 'hex')),
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
    sha256(decode('bb', 'hex')),
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
    sha256(decode('cc', 'hex')),
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
    'statement-corrupt-digest',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    decode(repeat('99', 32), 'hex'),
    convert_to('comparison-digest-contract', 'UTF8'),
    convert_to('{"id":"statement-corrupt-digest"}', 'UTF8')
);
SQL
then
  echo "statement_record accepted a content hash that does not match comparison bytes" >&2
  exit 1
fi

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO ingestion_receipt (
    tenant_key,
    received_xapi_version,
    raw_request_bytes,
    request_content_hash
) VALUES (
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"receipt-corrupt-digest"}', 'UTF8'),
    decode(repeat('88', 32), 'hex')
);
SQL
then
  echo "ingestion_receipt accepted a request hash that does not match immutable request bytes" >&2
  exit 1
fi

receipt_number="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO ingestion_receipt (
    tenant_key,
    received_xapi_version,
    raw_request_bytes,
    request_content_hash
) VALUES (
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"statement-001"}', 'UTF8'),
    sha256(convert_to('{"id":"statement-001"}', 'UTF8'))
);
SELECT max(receipt_number) FROM ingestion_receipt;
SQL
} | tail -n 1)"

if app_psql -v receipt_number="$receipt_number" <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO statement_ingestion_item (
    tenant_key,
    receipt_number,
    request_statement_index,
    submitted_statement_key,
    comparison_outcome,
    resolved_statement_key
) VALUES (
    'tenant-alpha',
    :'receipt_number'::bigint,
    0,
    'statement-wrong-key',
    'accepted',
    'statement-001'
);
SQL
then
  echo "accepted occurrence resolved to a different Statement key" >&2
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
) VALUES
(
    'tenant-alpha',
    'statement-voiding',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    sha256(decode('dd', 'hex')),
    decode('dd', 'hex'),
    convert_to('{"id":"statement-voiding"}', 'UTF8')
),
(
    'tenant-alpha',
    'statement-target-a',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    sha256(decode('ee', 'hex')),
    decode('ee', 'hex'),
    convert_to('{"id":"statement-target-a"}', 'UTF8')
),
(
    'tenant-alpha',
    'statement-target-b',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    sha256(decode('ff', 'hex')),
    decode('ff', 'hex'),
    convert_to('{"id":"statement-target-b"}', 'UTF8')
);

INSERT INTO voiding_relation (
    tenant_key,
    voiding_statement_key,
    voided_statement_key
) VALUES (
    'tenant-alpha',
    'statement-voiding',
    'statement-target-a'
);
SQL

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO voiding_relation (
    tenant_key,
    voiding_statement_key,
    voided_statement_key
) VALUES (
    'tenant-alpha',
    'statement-voiding',
    'statement-target-b'
);
SQL
then
  echo "one voiding Statement unexpectedly acquired multiple targets" >&2
  exit 1
fi

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
INSERT INTO voiding_relation (
    tenant_key,
    voiding_statement_key,
    voided_statement_key
) VALUES (
    'tenant-alpha',
    'statement-target-b',
    'statement-target-b'
);
SQL
then
  echo "self-voiding relation unexpectedly succeeded" >&2
  exit 1
fi

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
