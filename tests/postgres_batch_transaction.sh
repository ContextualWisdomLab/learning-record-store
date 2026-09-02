#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 -f migrations/0004_atomic_statement_batch.sql

psql -v ON_ERROR_STOP=1 <<'SQL'
GRANT EXECUTE ON FUNCTION persist_statement_batch(
    text, text, bytea, text[], text[], bytea[], bytea[]
) TO lrs_tenant_alpha;
SQL

alpha_psql() {
  PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -v ON_ERROR_STOP=1 "$@"
}

first_batch="$({ alpha_psql -At -F '|' <<'SQL'
SELECT persisted_receipt_number, request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"durable-batch-001"},{"id":"durable-batch-002"}]', 'UTF8'),
    ARRAY['durable-batch-001', 'durable-batch-002'],
    ARRAY['xapi-2.0-statement-comparison/v1', 'xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('comparison-durable-batch-001', 'UTF8'), convert_to('comparison-durable-batch-002', 'UTF8')],
    ARRAY[convert_to('{"id":"durable-batch-001"}', 'UTF8'), convert_to('{"id":"durable-batch-002"}', 'UTF8')]
)
ORDER BY request_statement_index;
SQL
} )"

first_receipt_count="$(printf '%s\n' "$first_batch" | cut -d'|' -f1 | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$first_receipt_count" == "1" ]] || {
  echo "expected one shared receipt for a two-item accepted batch, got: $first_batch" >&2
  exit 1
}

first_outcomes="$(printf '%s\n' "$first_batch" | cut -d'|' -f2-4)"
[[ "$first_outcomes" == $'0|accepted|durable-batch-001\n1|accepted|durable-batch-002' ]] || {
  echo "unexpected first-batch outcomes: $first_batch" >&2
  exit 1
}

first_receipt="$(printf '%s\n' "$first_batch" | head -n 1 | cut -d'|' -f1)"
first_occurrence_count="$(psql -At -v receipt_number="$first_receipt" <<'SQL'
SELECT count(*)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha'
  AND receipt_number = :'receipt_number'::bigint;
SQL
)"
[[ "$first_occurrence_count" == "2" ]] || {
  echo "expected two durable occurrences on the shared receipt, got: $first_occurrence_count" >&2
  exit 1
}

replay_batch="$({ alpha_psql -At -F '|' <<'SQL'
SELECT persisted_receipt_number, request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"durable-batch-001"},{"id":"durable-batch-002"}]', 'UTF8'),
    ARRAY['durable-batch-001', 'durable-batch-002'],
    ARRAY['xapi-2.0-statement-comparison/v1', 'xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('comparison-durable-batch-001', 'UTF8'), convert_to('comparison-durable-batch-002', 'UTF8')],
    ARRAY[convert_to('{"id":"durable-batch-001"}', 'UTF8'), convert_to('{"id":"durable-batch-002"}', 'UTF8')]
)
ORDER BY request_statement_index;
SQL
} )"

replay_outcomes="$(printf '%s\n' "$replay_batch" | cut -d'|' -f2-4)"
[[ "$replay_outcomes" == $'0|replayed|durable-batch-001\n1|replayed|durable-batch-002' ]] || {
  echo "unexpected replay-batch outcomes: $replay_batch" >&2
  exit 1
}

conflict_batch="$({ alpha_psql -At -F '|' <<'SQL'
SELECT persisted_receipt_number, request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"durable-batch-001","changed":true},{"id":"durable-batch-003"}]', 'UTF8'),
    ARRAY['durable-batch-001', 'durable-batch-003'],
    ARRAY['xapi-2.0-statement-comparison/v1', 'xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('comparison-durable-batch-001-conflict', 'UTF8'), convert_to('comparison-durable-batch-003', 'UTF8')],
    ARRAY[convert_to('{"id":"durable-batch-001","changed":true}', 'UTF8'), convert_to('{"id":"durable-batch-003"}', 'UTF8')]
)
ORDER BY request_statement_index;
SQL
} )"

conflict_outcomes="$(printf '%s\n' "$conflict_batch" | cut -d'|' -f2-4)"
[[ "$conflict_outcomes" == $'0|conflict|\n1|batch_rejected|' ]] || {
  echo "unexpected rejected-batch outcomes: $conflict_batch" >&2
  exit 1
}

conflict_receipt_count="$(printf '%s\n' "$conflict_batch" | cut -d'|' -f1 | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$conflict_receipt_count" == "1" ]] || {
  echo "expected rejected items to share one receipt, got: $conflict_batch" >&2
  exit 1
}

unexpected_sibling_count="$(psql -At <<'SQL'
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-alpha'
  AND statement_key = 'durable-batch-003';
SQL
)"
[[ "$unexpected_sibling_count" == "0" ]] || {
  echo "conflicted batch leaked a non-conflicting sibling into canonical evidence" >&2
  exit 1
}

canonical_original="$(psql -At <<'SQL'
SELECT convert_from(comparison_bytes, 'UTF8')
FROM statement_record
WHERE tenant_key = 'tenant-alpha'
  AND statement_key = 'durable-batch-001';
SQL
)"
[[ "$canonical_original" == "comparison-durable-batch-001" ]] || {
  echo "conflicted batch overwrote canonical evidence: $canonical_original" >&2
  exit 1
}

if alpha_psql <<'SQL'
SELECT *
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"duplicate-batch"},{"id":"duplicate-batch"}]', 'UTF8'),
    ARRAY['duplicate-batch', 'duplicate-batch'],
    ARRAY['xapi-2.0-statement-comparison/v1', 'xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('duplicate-a', 'UTF8'), convert_to('duplicate-b', 'UTF8')],
    ARRAY[convert_to('{"id":"duplicate-batch"}', 'UTF8'), convert_to('{"id":"duplicate-batch"}', 'UTF8')]
);
SQL
then
  echo "durable batch primitive accepted duplicate statement identities" >&2
  exit 1
fi

unexpected_duplicate_count="$(psql -At <<'SQL'
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-alpha'
  AND statement_key = 'duplicate-batch';
SQL
)"
[[ "$unexpected_duplicate_count" == "0" ]] || {
  echo "duplicate batch created canonical evidence" >&2
  exit 1
}

echo "postgres shared-receipt batch transaction tests passed"
