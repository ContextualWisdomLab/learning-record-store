#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 -f migrations/0002_database_principal_boundary.sql

psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lrs_tenant_alpha') THEN
        CREATE ROLE lrs_tenant_alpha LOGIN PASSWORD 'lrs-alpha-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lrs_tenant_beta') THEN
        CREATE ROLE lrs_tenant_beta LOGIN PASSWORD 'lrs-beta-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END
$$;

INSERT INTO tenant_partition (tenant_key)
VALUES ('tenant-alpha'), ('tenant-beta')
ON CONFLICT (tenant_key) DO NOTHING;

INSERT INTO tenant_database_principal (database_principal_name, tenant_key)
VALUES
    ('lrs_tenant_alpha', 'tenant-alpha'),
    ('lrs_tenant_beta', 'tenant-beta')
ON CONFLICT (database_principal_name)
DO UPDATE SET tenant_key = EXCLUDED.tenant_key;

GRANT CONNECT ON DATABASE learning_record_store TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT USAGE ON SCHEMA public TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT SELECT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation
    TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT EXECUTE ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) TO lrs_tenant_alpha, lrs_tenant_beta;
SQL

alpha_psql() {
  PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -v ON_ERROR_STOP=1 "$@"
}

beta_psql() {
  PGUSER=lrs_tenant_beta PGPASSWORD=lrs-beta-test psql -v ON_ERROR_STOP=1 "$@"
}

alpha_visible="$({ alpha_psql -At <<'SQL'
SET app.tenant_key = 'tenant-beta';
SELECT string_agg(tenant_key, ',' ORDER BY tenant_key) FROM tenant_partition;
SQL
} | tail -n 1)"
[[ "$alpha_visible" == "tenant-alpha" ]] || {
  echo "database principal binding was spoofed by caller-selected GUC: $alpha_visible" >&2
  exit 1
}

if alpha_psql <<'SQL'
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
    'direct-write-must-fail',
    '2.0',
    'xapi-2.0-statement-comparison/v1',
    sha256(decode('aa', 'hex')),
    decode('aa', 'hex'),
    convert_to('{"id":"direct-write-must-fail"}', 'UTF8')
);
SQL
then
  echo "tenant application principal unexpectedly bypassed the ingestion function" >&2
  exit 1
fi

alpha_outcome="$({ alpha_psql -At <<'SQL'
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"principal-alpha-001"}', 'UTF8'),
    0,
    'principal-alpha-001',
    'xapi-2.0-statement-comparison/v1',
    convert_to('comparison-alpha-001', 'UTF8'),
    convert_to('{"id":"principal-alpha-001"}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$alpha_outcome" == "accepted" ]] || {
  echo "expected tenant-alpha function ingest to be accepted, got: $alpha_outcome" >&2
  exit 1
}

if alpha_psql <<'SQL'
SELECT *
FROM persist_statement_occurrence(
    'tenant-beta',
    '2.0',
    convert_to('{"id":"principal-spoof"}', 'UTF8'),
    0,
    'principal-spoof',
    'xapi-2.0-statement-comparison/v1',
    convert_to('comparison-spoof', 'UTF8'),
    convert_to('{"id":"principal-spoof"}', 'UTF8')
);
SQL
then
  echo "tenant-alpha principal unexpectedly ingested tenant-beta evidence" >&2
  exit 1
fi

for field_case in version statement_key comparison_version; do
  case "$field_case" in
    version)
      received_version=$'\t'
      statement_key='whitespace-version-001'
      comparison_version='xapi-2.0-statement-comparison/v1'
      ;;
    statement_key)
      received_version='2.0'
      statement_key=$'\n'
      comparison_version='xapi-2.0-statement-comparison/v1'
      ;;
    comparison_version)
      received_version='2.0'
      statement_key='whitespace-comparison-version-001'
      comparison_version=$'\t\n'
      ;;
  esac
  if PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -v ON_ERROR_STOP=1 \
      -v received_version="$received_version" \
      -v statement_key="$statement_key" \
      -v comparison_version="$comparison_version" <<'SQL'
SELECT *
FROM persist_statement_occurrence(
    'tenant-alpha',
    :'received_version',
    convert_to('{"id":"whitespace-contract"}', 'UTF8'),
    0,
    :'statement_key',
    :'comparison_version',
    convert_to('comparison-whitespace-contract', 'UTF8'),
    convert_to('{"id":"whitespace-contract"}', 'UTF8')
);
SQL
  then
    echo "persist_statement_occurrence accepted whitespace-only $field_case" >&2
    exit 1
  fi
done

if psql -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO ingestion_receipt (
    tenant_key,
    received_xapi_version,
    raw_request_bytes,
    request_content_hash
) VALUES (
    'tenant-alpha',
    E'\t',
    convert_to('{"id":"whitespace-table-version"}', 'UTF8'),
    sha256(convert_to('{"id":"whitespace-table-version"}', 'UTF8'))
);
SQL
then
  echo "ingestion_receipt accepted a whitespace-only xAPI version" >&2
  exit 1
fi

for table_field_case in statement_key comparison_version; do
  case "$table_field_case" in
    statement_key)
      table_statement_key=$'\n'
      table_comparison_version='xapi-2.0-statement-comparison/v1'
      table_raw_statement='{"id":"whitespace-table-statement-key"}'
      ;;
    comparison_version)
      table_statement_key='whitespace-table-comparison-version'
      table_comparison_version=$'\t'
      table_raw_statement='{"id":"whitespace-table-comparison-version"}'
      ;;
  esac
  if psql -v ON_ERROR_STOP=1 \
      -v table_statement_key="$table_statement_key" \
      -v table_comparison_version="$table_comparison_version" \
      -v table_raw_statement="$table_raw_statement" <<'SQL'
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
    :'table_statement_key',
    '2.0',
    :'table_comparison_version',
    sha256(convert_to('comparison-whitespace-table', 'UTF8')),
    convert_to('comparison-whitespace-table', 'UTF8'),
    convert_to(:'table_raw_statement', 'UTF8')
);
SQL
  then
    echo "statement_record accepted whitespace-only $table_field_case" >&2
    exit 1
  fi
done

beta_outcome="$({ beta_psql -At <<'SQL'
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-beta',
    '2.0',
    convert_to('{"id":"principal-beta-001"}', 'UTF8'),
    0,
    'principal-beta-001',
    'xapi-2.0-statement-comparison/v1',
    convert_to('comparison-beta-001', 'UTF8'),
    convert_to('{"id":"principal-beta-001"}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$beta_outcome" == "accepted" ]] || {
  echo "expected tenant-beta function ingest to be accepted, got: $beta_outcome" >&2
  exit 1
}

alpha_statement_count="$({ alpha_psql -At <<'SQL'
SELECT count(*) FROM statement_record WHERE statement_key IN ('principal-alpha-001', 'principal-beta-001');
SQL
} | tail -n 1)"
[[ "$alpha_statement_count" == "1" ]] || {
  echo "tenant-alpha unexpectedly observed cross-tenant canonical evidence: $alpha_statement_count" >&2
  exit 1
}

security_definer_count="$(psql -At <<'SQL'
SELECT count(*)
FROM pg_proc AS p
JOIN pg_roles AS r ON r.oid = p.proowner
WHERE p.proname = 'persist_statement_occurrence'
  AND p.prosecdef
  AND r.rolname = 'lrs_evidence_writer'
  AND NOT r.rolsuper
  AND NOT r.rolbypassrls;
SQL
)"
[[ "$security_definer_count" == "1" ]] || {
  echo "persist_statement_occurrence is not owned by the expected constrained security-definer role" >&2
  exit 1
}

for principal in lrs_tenant_alpha lrs_tenant_beta; do
  direct_write="$(psql -At -v principal="$principal" <<'SQL'
SELECT has_table_privilege(:'principal', 'statement_record', 'INSERT')
    OR has_table_privilege(:'principal', 'ingestion_receipt', 'INSERT')
    OR has_table_privilege(:'principal', 'statement_ingestion_item', 'INSERT');
SQL
)"
  [[ "$direct_write" == "f" ]] || {
    echo "$principal retained direct immutable-evidence write privileges" >&2
    exit 1
  }
done

echo "postgres authenticated database-principal boundary tests passed"
