#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

bash tests/postgres_fixture_setup.sh batch-transaction

alpha_psql() {
  PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -v ON_ERROR_STOP=1 "$@"
}

if version_error="$({ alpha_psql <<'SQL'
SELECT *
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0.0',
    convert_to('[{"id":"batch-mismatched-version"}]', 'UTF8'),
    ARRAY['batch-mismatched-version'],
    ARRAY['xapi-1.0.3-statement-comparison/v1'],
    ARRAY[convert_to('comparison-batch-mismatched-version', 'UTF8')],
    ARRAY[convert_to('{"id":"batch-mismatched-version"}', 'UTF8')]
);
SQL
} 2>&1)"; then
  echo "batch writer accepted an incompatible xAPI/comparison-version pair" >&2
  exit 1
fi
[[ "$version_error" == *"xAPI version and Statement comparison version are incompatible"* ]] || {
  echo "batch writer returned the wrong version-pair error: $version_error" >&2
  exit 1
}

shorthand_batch="$(alpha_psql -At -F '|' <<'SQL'
SELECT request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0',
    convert_to('[{"id":"two-zero-batch-version"}]', 'UTF8'),
    ARRAY['two-zero-batch-version'],
    ARRAY['xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('comparison-two-zero-batch-version', 'UTF8')],
    ARRAY[convert_to('{"id":"two-zero-batch-version"}', 'UTF8')]
);
SQL
)"
[[ "$shorthand_batch" == "0|accepted|two-zero-batch-version" ]] || {
  echo "batch writer did not accept xAPI 2.0 as 2.0.0: $shorthand_batch" >&2
  exit 1
}
[[ "$(psql -At -c "SELECT received_xapi_version FROM ingestion_receipt WHERE tenant_key = 'tenant-alpha' AND raw_request_bytes = convert_to('[{\"id\":\"two-zero-batch-version\"}]', 'UTF8');")" == "2.0" ]] || {
  echo "batch writer did not retain the received xAPI 2.0 header" >&2
  exit 1
}
[[ "$(psql -At -c "SELECT received_xapi_version FROM statement_record WHERE tenant_key = 'tenant-alpha' AND statement_key = 'two-zero-batch-version';")" == "2.0.0" ]] || {
  echo "batch writer did not normalize xAPI 2.0 canonical processing to 2.0.0" >&2
  exit 1
}

canonical_batch_replay="$(alpha_psql -At -F '|' <<'SQL'
SELECT request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0.0',
    convert_to('[{"id":"two-zero-batch-version"}]', 'UTF8'),
    ARRAY['two-zero-batch-version'],
    ARRAY['xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('comparison-two-zero-batch-version', 'UTF8')],
    ARRAY[convert_to('{"id":"two-zero-batch-version"}', 'UTF8')]
);
SQL
)"
[[ "$canonical_batch_replay" == "0|replayed|two-zero-batch-version" ]] || {
  echo "batch writer did not treat xAPI 2.0 and 2.0.0 as the same protocol surface: $canonical_batch_replay" >&2
  exit 1
}

one_zero_batch="$(alpha_psql -At -F '|' <<'SQL'
SELECT request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '1.0',
    convert_to('[{"id":"one-zero-batch-version"}]', 'UTF8'),
    ARRAY['one-zero-batch-version'],
    ARRAY['xapi-1.0.3-statement-comparison/v1'],
    ARRAY[convert_to('comparison-one-zero-batch-version', 'UTF8')],
    ARRAY[convert_to('{"id":"one-zero-batch-version"}', 'UTF8')]
);
SQL
)"
[[ "$one_zero_batch" == "0|accepted|one-zero-batch-version" ]] || {
  echo "batch writer did not accept xAPI 1.0 as 1.0.0: $one_zero_batch" >&2
  exit 1
}
[[ "$(psql -At -c "SELECT received_xapi_version FROM ingestion_receipt WHERE tenant_key = 'tenant-alpha' AND raw_request_bytes = convert_to('[{\"id\":\"one-zero-batch-version\"}]', 'UTF8');")" == "1.0" ]] || {
  echo "batch writer did not retain the received xAPI 1.0 header" >&2
  exit 1
}
[[ "$(psql -At -c "SELECT received_xapi_version FROM statement_record WHERE tenant_key = 'tenant-alpha' AND statement_key = 'one-zero-batch-version';")" == "1.0.0" ]] || {
  echo "batch writer did not normalize xAPI 1.0 processing to 1.0.0" >&2
  exit 1
}

one_zero_batch_replay="$(alpha_psql -At -F '|' <<'SQL'
SELECT request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '1.0.3',
    convert_to('[{"id":"one-zero-batch-version"}]', 'UTF8'),
    ARRAY['one-zero-batch-version'],
    ARRAY['xapi-1.0.3-statement-comparison/v1'],
    ARRAY[convert_to('comparison-one-zero-batch-version', 'UTF8')],
    ARRAY[convert_to('{"id":"one-zero-batch-version"}', 'UTF8')]
);
SQL
)"
[[ "$one_zero_batch_replay" == "0|replayed|one-zero-batch-version" ]] || {
  echo "batch writer did not treat xAPI 1.0 and 1.0.3 as one compatible surface: $one_zero_batch_replay" >&2
  exit 1
}

invalid_one_zero_batch_before="$(psql -At -F '|' <<'SQL'
SELECT
    (SELECT count(*) FROM ingestion_receipt
     WHERE tenant_key = 'tenant-alpha'
       AND raw_request_bytes = convert_to('[{"id":"invalid-one-zero-batch-version"}]', 'UTF8')),
    (SELECT count(*) FROM statement_record
     WHERE tenant_key = 'tenant-alpha'
       AND statement_key = 'invalid-one-zero-batch-version');
SQL
)"
if invalid_one_zero_batch_error="$({ alpha_psql <<'SQL'
\set VERBOSITY verbose
SELECT *
FROM persist_statement_batch(
    'tenant-alpha',
    '1.0.03',
    convert_to('[{"id":"invalid-one-zero-batch-version"}]', 'UTF8'),
    ARRAY['invalid-one-zero-batch-version'],
    ARRAY['xapi-1.0.3-statement-comparison/v1'],
    ARRAY[convert_to('comparison-invalid-one-zero-batch-version', 'UTF8')],
    ARRAY[convert_to('{"id":"invalid-one-zero-batch-version"}', 'UTF8')]
);
SQL
} 2>&1)"; then
  echo "batch writer accepted a non-SemVer xAPI 1.0 patch label" >&2
  exit 1
fi
[[ "$invalid_one_zero_batch_error" == *"22023"* ]] || {
  echo "batch writer returned the wrong SQLSTATE for malformed xAPI 1.0: $invalid_one_zero_batch_error" >&2
  exit 1
}
[[ "$invalid_one_zero_batch_error" == *"xAPI version and Statement comparison version are incompatible"* ]] || {
  echo "batch writer returned the wrong error for malformed xAPI 1.0: $invalid_one_zero_batch_error" >&2
  exit 1
}
invalid_one_zero_batch_after="$(psql -At -F '|' <<'SQL'
SELECT
    (SELECT count(*) FROM ingestion_receipt
     WHERE tenant_key = 'tenant-alpha'
       AND raw_request_bytes = convert_to('[{"id":"invalid-one-zero-batch-version"}]', 'UTF8')),
    (SELECT count(*) FROM statement_record
     WHERE tenant_key = 'tenant-alpha'
       AND statement_key = 'invalid-one-zero-batch-version');
SQL
)"
[[ "$invalid_one_zero_batch_before" == "0|0" && "$invalid_one_zero_batch_after" == "$invalid_one_zero_batch_before" ]] || {
  echo "batch writer mutated evidence for malformed xAPI 1.0: before=$invalid_one_zero_batch_before after=$invalid_one_zero_batch_after" >&2
  exit 1
}

first_batch="$({ alpha_psql -At -F '|' <<'SQL'
SELECT persisted_receipt_number, request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0.0',
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
    '2.0.0',
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
    '2.0.0',
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

duplicate_batch="$({ alpha_psql -At -F '|' <<'SQL'
SELECT persisted_receipt_number, request_statement_index, persistence_outcome, persisted_statement_key
FROM persist_statement_batch(
    'tenant-alpha',
    '2.0.0',
    convert_to('[{"id":"duplicate-batch"},{"id":"duplicate-batch"}]', 'UTF8'),
    ARRAY['duplicate-batch', 'duplicate-batch'],
    ARRAY['xapi-2.0-statement-comparison/v1', 'xapi-2.0-statement-comparison/v1'],
    ARRAY[convert_to('duplicate-a', 'UTF8'), convert_to('duplicate-b', 'UTF8')],
    ARRAY[convert_to('{"id":"duplicate-batch"}', 'UTF8'), convert_to('{"id":"duplicate-batch"}', 'UTF8')]
);
SQL
} )"

duplicate_receipt_count="$(printf '%s\n' "$duplicate_batch" | cut -d'|' -f1 | sort -u | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$duplicate_receipt_count" == "1" ]] || {
  echo "expected duplicate items to share one durable receipt, got: $duplicate_batch" >&2
  exit 1
}

duplicate_outcomes="$(printf '%s\n' "$duplicate_batch" | cut -d'|' -f2-4)"
[[ "$duplicate_outcomes" == $'0|batch_rejected|\n1|batch_rejected|' ]] || {
  echo "unexpected duplicate-batch outcomes: $duplicate_batch" >&2
  exit 1
}

duplicate_receipt="$(printf '%s\n' "$duplicate_batch" | sed -n '1s/|.*//p')"
duplicate_occurrence_count="$(psql -At -v receipt_number="$duplicate_receipt" <<'SQL'
SELECT count(*)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha'
  AND receipt_number = :'receipt_number'::bigint
  AND submitted_statement_key = 'duplicate-batch'
  AND comparison_outcome = 'batch_rejected'
  AND resolved_statement_key IS NULL;
SQL
)"
[[ "$duplicate_occurrence_count" == "2" ]] || {
  echo "expected both duplicate indexes to retain batch_rejected evidence, got: $duplicate_occurrence_count" >&2
  exit 1
}

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
