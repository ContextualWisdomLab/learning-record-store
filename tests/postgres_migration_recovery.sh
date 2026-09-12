#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

bash tests/postgres_fixture_setup.sh batch-transaction

# Recovery rollback is intentionally limited to an empty pre-release schema.
psql -v ON_ERROR_STOP=1 <<'SQL'
TRUNCATE TABLE
    tenant_database_principal,
    voiding_relation,
    statement_ingestion_item,
    statement_record,
    ingestion_receipt,
    tenant_partition
RESTART IDENTITY CASCADE;
SQL

psql -v ON_ERROR_STOP=1 -f migrations/rollback_statement_evidence.sql

remaining_objects="$(psql -At <<'SQL'
SELECT count(*)
FROM (
    VALUES
        (to_regclass('public.tenant_partition')::text),
        (to_regclass('public.tenant_database_principal')::text),
        (to_regclass('public.ingestion_receipt')::text),
        (to_regclass('public.statement_record')::text),
        (to_regclass('public.statement_ingestion_item')::text),
        (to_regclass('public.voiding_relation')::text),
        (to_regprocedure('public.persist_statement_occurrence(text,text,bytea,integer,text,text,bytea,bytea)')::text),
        (to_regprocedure('public.persist_statement_batch(text,text,bytea,text[],text[],bytea[],bytea[])')::text)
) AS recovered_object(object_name)
WHERE object_name IS NOT NULL;
SQL
)"
[[ "$remaining_objects" == "0" ]] || {
  echo "rollback left $remaining_objects schema objects behind" >&2
  exit 1
}

for migration in \
  migrations/0001_statement_evidence.sql \
  migrations/0002_database_principal_boundary.sql \
  migrations/0003_batch_rejection_outcome.sql \
  migrations/0004_atomic_statement_batch.sql
do
  psql -v ON_ERROR_STOP=1 -f "$migration"
done

psql -v ON_ERROR_STOP=1 -v database_name="$PGDATABASE" <<'SQL'
INSERT INTO tenant_partition (tenant_key) VALUES ('tenant-recovery');
INSERT INTO tenant_database_principal (database_principal_name, tenant_key)
VALUES ('lrs_tenant_alpha', 'tenant-recovery');
GRANT CONNECT ON DATABASE :"database_name" TO lrs_tenant_alpha;
GRANT USAGE ON SCHEMA public TO lrs_tenant_alpha;
GRANT SELECT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation
    TO lrs_tenant_alpha;
GRANT EXECUTE ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) TO lrs_tenant_alpha;
SQL

writer_log="$(mktemp)"
rollback_log="$(mktemp)"
cleanup_concurrency_probe() {
  rm -f "$writer_log" "$rollback_log"
}
trap cleanup_concurrency_probe EXIT

PGAPPNAME=lrs_recovery_writer \
PGUSER=lrs_tenant_alpha \
PGPASSWORD=lrs-alpha-test \
psql -v ON_ERROR_STOP=1 >"$writer_log" 2>&1 <<'SQL' &
BEGIN;
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-recovery',
    '2.0.0',
    convert_to('{"id":"concurrent-recovery-statement"}', 'UTF8'),
    0,
    'concurrent-recovery-statement',
    'xapi-2.0-statement-comparison/v1',
    convert_to('comparison-concurrent-recovery-statement', 'UTF8'),
    convert_to('{"id":"concurrent-recovery-statement"}', 'UTF8')
);
SELECT pg_sleep(4);
COMMIT;
SQL
writer_pid=$!

writer_ready=""
for _ in $(seq 1 100); do
  writer_ready="$(psql -Atq <<'SQL'
SELECT 1
FROM pg_stat_activity
WHERE application_name = 'lrs_recovery_writer'
  AND state = 'active'
  AND wait_event = 'PgSleep';
SQL
)"
  [[ "$writer_ready" == "1" ]] && break
  sleep 0.05
done
[[ "$writer_ready" == "1" ]] || {
  echo "concurrent recovery writer never reached its open transaction" >&2
  wait "$writer_pid" || true
  exit 1
}

PGAPPNAME=lrs_recovery_rollback \
psql -v ON_ERROR_STOP=1 -f migrations/rollback_statement_evidence.sql \
  >"$rollback_log" 2>&1 &
rollback_pid=$!

rollback_wait_query=""
for _ in $(seq 1 100); do
  rollback_wait_query="$(psql -Atq <<'SQL'
SELECT query
FROM pg_stat_activity
WHERE application_name = 'lrs_recovery_rollback'
  AND wait_event_type = 'Lock';
SQL
)"
  [[ -n "$rollback_wait_query" ]] && break
  sleep 0.05
done

writer_status=0
wait "$writer_pid" || writer_status=$?
rollback_status=0
wait "$rollback_pid" || rollback_status=$?

[[ "$writer_status" == "0" ]] || {
  echo "concurrent recovery writer failed:" >&2
  cat "$writer_log" >&2
  exit 1
}
[[ "$rollback_wait_query" == *"LOCK TABLE"* ]] || {
  echo "rollback did not wait at the reviewed table-lock barrier: $rollback_wait_query" >&2
  cat "$rollback_log" >&2
  exit 1
}
[[ "$rollback_status" != "0" ]] || {
  echo "rollback discarded evidence committed while it waited for exclusion" >&2
  exit 1
}
rollback_error="$(cat "$rollback_log")"
[[ "$rollback_error" == *"refusing rollback while learning record evidence or tenant bindings exist"* ]] || {
  echo "concurrent rollback returned the wrong error: $rollback_error" >&2
  exit 1
}

concurrent_retained_count="$(psql -At <<'SQL'
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-recovery'
  AND statement_key = 'concurrent-recovery-statement';
SQL
)"
[[ "$concurrent_retained_count" == "1" ]] || {
  echo "failed concurrent rollback did not preserve committed evidence" >&2
  exit 1
}

recovered_outcome="$({
  PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -At -v ON_ERROR_STOP=1 <<'SQL'
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-recovery',
    '2.0.0',
    convert_to('{"id":"recovered-statement"}', 'UTF8'),
    0,
    'recovered-statement',
    'xapi-2.0-statement-comparison/v1',
    convert_to('comparison-recovered-statement', 'UTF8'),
    convert_to('{"id":"recovered-statement"}', 'UTF8')
);
SQL
} | tail -n 1)"
[[ "$recovered_outcome" == "accepted" ]] || {
  echo "reapplied migration set could not accept evidence: $recovered_outcome" >&2
  exit 1
}

if rollback_error="$(psql -v ON_ERROR_STOP=1 -f migrations/rollback_statement_evidence.sql 2>&1)"; then
  echo "rollback unexpectedly discarded retained evidence" >&2
  exit 1
fi
[[ "$rollback_error" == *"refusing rollback while learning record evidence or tenant bindings exist"* ]] || {
  echo "nonempty rollback returned the wrong error: $rollback_error" >&2
  exit 1
}

retained_count="$(psql -At <<'SQL'
SELECT count(*)
FROM statement_record
WHERE tenant_key = 'tenant-recovery'
  AND statement_key = 'recovered-statement';
SQL
)"
[[ "$retained_count" == "1" ]] || {
  echo "failed rollback did not preserve retained evidence" >&2
  exit 1
}

echo "postgres empty-schema rollback, reapply, and nonempty refusal tests passed"
