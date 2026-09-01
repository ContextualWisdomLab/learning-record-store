#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

psql -v ON_ERROR_STOP=1 <<'SQL'
GRANT EXECUTE ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) TO lrs_app;
SQL

app_psql() {
  PGUSER=lrs_app PGPASSWORD=lrs-app-test psql -v ON_ERROR_STOP=1 "$@"
}

accepted_outcome="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"statement-atomic"}', 'UTF8'),
    0,
    'statement-atomic',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-atomic"}', 'UTF8'),
    convert_to('{"id":"statement-atomic"}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$accepted_outcome" == "accepted" ]] || {
  echo "expected first durable occurrence to be accepted, got: $accepted_outcome" >&2
  exit 1
}

replay_outcome="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{ "id" : "statement-atomic" }', 'UTF8'),
    0,
    'statement-atomic',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-atomic"}', 'UTF8'),
    convert_to('{ "id" : "statement-atomic" }', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$replay_outcome" == "replayed" ]] || {
  echo "expected equivalent durable retry to be replayed, got: $replay_outcome" >&2
  exit 1
}

conflict_outcome="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"statement-atomic","conflict":true}', 'UTF8'),
    0,
    'statement-atomic',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-atomic","conflict":true}', 'UTF8'),
    convert_to('{"id":"statement-atomic","conflict":true}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$conflict_outcome" == "conflict" ]] || {
  echo "expected conflicting durable retry to be retained as conflict, got: $conflict_outcome" >&2
  exit 1
}

version_conflict_outcome="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '1.0.3',
    convert_to('{"id":"statement-atomic"}', 'UTF8'),
    0,
    'statement-atomic',
    'xapi-1.0.3-statement-comparison/v1',
    convert_to('{"id":"statement-atomic"}', 'UTF8'),
    convert_to('{"id":"statement-atomic"}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$version_conflict_outcome" == "conflict" ]] || {
  echo "expected cross-version durable retry to fail closed, got: $version_conflict_outcome" >&2
  exit 1
}

canonical_hash_matches="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT content_hash = sha256(comparison_bytes)
FROM statement_record
WHERE tenant_key = 'tenant-alpha' AND statement_key = 'statement-atomic';
SQL
} | tail -n 1)"
[[ "$canonical_hash_matches" == "t" ]] || {
  echo "canonical content hash was not derived from retained comparison bytes" >&2
  exit 1
}

receipt_hash_mismatch_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*)
FROM ingestion_receipt
WHERE request_content_hash <> sha256(raw_request_bytes);
SQL
} | tail -n 1)"
[[ "$receipt_hash_mismatch_count" == "0" ]] || {
  echo "request digest does not match immutable request bytes" >&2
  exit 1
}

conflict_audit_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha'
  AND submitted_statement_key = 'statement-atomic'
  AND comparison_outcome = 'conflict';
SQL
} | tail -n 1)"
[[ "$conflict_audit_count" == "2" ]] || {
  echo "expected both content and version conflicts to survive as audit evidence, got: $conflict_audit_count" >&2
  exit 1
}

if app_psql <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT *
FROM persist_statement_occurrence(
    'tenant-beta',
    '2.0',
    convert_to('{"id":"statement-cross-scope"}', 'UTF8'),
    0,
    'statement-cross-scope',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-cross-scope"}', 'UTF8'),
    convert_to('{"id":"statement-cross-scope"}', 'UTF8')
);
SQL
then
  echo "cross-tenant transactional ingest unexpectedly succeeded" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

run_concurrent_ingest() {
  local request_variant="$1"
  local output_file="$2"
  PGUSER=lrs_app PGPASSWORD=lrs-app-test psql -v ON_ERROR_STOP=1 -At >"$output_file" <<SQL
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"statement-concurrent","request":"${request_variant}"}', 'UTF8'),
    0,
    'statement-concurrent',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-concurrent"}', 'UTF8'),
    convert_to('{"id":"statement-concurrent"}', 'UTF8')
);
SQL
}

run_concurrent_ingest first "$work_dir/first.out" &
first_pid=$!
run_concurrent_ingest second "$work_dir/second.out" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

concurrent_outcomes="$(cat "$work_dir/first.out" "$work_dir/second.out" | grep -E '^(accepted|replayed)$' | sort | tr '\n' ' ')"
[[ "$concurrent_outcomes" == "accepted replayed " ]] || {
  echo "expected one accepted and one replayed concurrent outcome, got: $concurrent_outcomes" >&2
  exit 1
}

concurrent_statement_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-alpha' AND statement_key = 'statement-concurrent';
SQL
} | tail -n 1)"
[[ "$concurrent_statement_count" == "1" ]] || {
  echo "concurrent identical ingests created duplicate canonical statements" >&2
  exit 1
}

concurrent_receipt_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha' AND submitted_statement_key = 'statement-concurrent';
SQL
} | tail -n 1)"
[[ "$concurrent_receipt_count" == "2" ]] || {
  echo "concurrent ingests did not retain both request occurrences" >&2
  exit 1
}

run_concurrent_conflict() {
  local request_variant="$1"
  local comparison_variant="$2"
  local output_file="$3"
  PGUSER=lrs_app PGPASSWORD=lrs-app-test psql -v ON_ERROR_STOP=1 -At >"$output_file" <<SQL
SET app.tenant_key = 'tenant-alpha';
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-alpha',
    '2.0',
    convert_to('{"id":"statement-race-conflict","request":"${request_variant}"}', 'UTF8'),
    0,
    'statement-race-conflict',
    'xapi-2.0-statement-comparison/v1',
    convert_to('{"id":"statement-race-conflict","variant":"${comparison_variant}"}', 'UTF8'),
    convert_to('{"id":"statement-race-conflict","variant":"${comparison_variant}"}', 'UTF8')
);
SQL
}

run_concurrent_conflict first first "$work_dir/conflict-first.out" &
conflict_first_pid=$!
run_concurrent_conflict second second "$work_dir/conflict-second.out" &
conflict_second_pid=$!
wait "$conflict_first_pid"
wait "$conflict_second_pid"

conflicting_race_outcomes="$(cat "$work_dir/conflict-first.out" "$work_dir/conflict-second.out" | grep -E '^(accepted|conflict)$' | sort | tr '\n' ' ')"
[[ "$conflicting_race_outcomes" == "accepted conflict " ]] || {
  echo "expected one accepted and one conflict outcome for competing content, got: $conflicting_race_outcomes" >&2
  exit 1
}

conflicting_race_statement_count="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-alpha' AND statement_key = 'statement-race-conflict';
SQL
} | tail -n 1)"
[[ "$conflicting_race_statement_count" == "1" ]] || {
  echo "competing content created duplicate canonical statements" >&2
  exit 1
}

conflicting_race_audit="$({ app_psql -At <<'SQL'
SET app.tenant_key = 'tenant-alpha';
SELECT string_agg(comparison_outcome, ',' ORDER BY comparison_outcome)
FROM statement_ingestion_item
WHERE tenant_key = 'tenant-alpha' AND submitted_statement_key = 'statement-race-conflict';
SQL
} | tail -n 1)"
[[ "$conflicting_race_audit" == "accepted,conflict" ]] || {
  echo "competing content did not preserve accepted/conflict audit evidence, got: $conflicting_race_audit" >&2
  exit 1
}

echo "postgres atomic ingestion transaction tests passed"
