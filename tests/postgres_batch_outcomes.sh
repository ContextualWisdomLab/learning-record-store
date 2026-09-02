#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 -f migrations/0003_batch_rejection_outcome.sql

receipt_number="$({ psql -At <<'SQL'
INSERT INTO ingestion_receipt (
    tenant_key,
    received_xapi_version,
    raw_request_bytes,
    request_content_hash
) VALUES (
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"batch-a"},{"id":"batch-b"}]', 'UTF8'),
    sha256(convert_to('[{"id":"batch-a"},{"id":"batch-b"}]', 'UTF8'))
)
RETURNING receipt_number;
SQL
} | tail -n 1)"

psql -v ON_ERROR_STOP=1 -v receipt_number="$receipt_number" <<'SQL'
INSERT INTO statement_ingestion_item (
    tenant_key,
    receipt_number,
    request_statement_index,
    submitted_statement_key,
    comparison_outcome,
    resolved_statement_key
) VALUES
(
    'tenant-alpha',
    :'receipt_number'::bigint,
    0,
    'batch-a',
    'batch_rejected',
    NULL
),
(
    'tenant-alpha',
    :'receipt_number'::bigint,
    1,
    'batch-b',
    'batch_rejected',
    NULL
);
SQL

batch_rejected_count="$(psql -At -v receipt_number="$receipt_number" <<'SQL'
SELECT count(*)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha'
  AND receipt_number = :'receipt_number'::bigint
  AND comparison_outcome = 'batch_rejected'
  AND resolved_statement_key IS NULL;
SQL
)"
[[ "$batch_rejected_count" == "2" ]] || {
  echo "expected two durable batch_rejected evidence rows, got: $batch_rejected_count" >&2
  exit 1
}

if psql -v ON_ERROR_STOP=1 -v receipt_number="$receipt_number" <<'SQL'
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
    2,
    'batch-invalid-resolution',
    'batch_rejected',
    'statement-001'
);
SQL
then
  echo "batch_rejected occurrence unexpectedly resolved to canonical evidence" >&2
  exit 1
fi

for successful_outcome in accepted replayed; do
  if psql -v ON_ERROR_STOP=1 -v receipt_number="$receipt_number" -v successful_outcome="$successful_outcome" <<'SQL'
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
    CASE WHEN :'successful_outcome' = 'accepted' THEN 3 ELSE 4 END,
    'batch-missing-canonical-link',
    :'successful_outcome',
    NULL
);
SQL
  then
    echo "$successful_outcome occurrence unexpectedly accepted without a canonical resolved statement" >&2
    exit 1
  fi
done

echo "postgres batch rejection outcome tests passed"
