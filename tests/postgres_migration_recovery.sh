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

recovered_outcome="$({
  PGUSER=lrs_tenant_alpha PGPASSWORD=lrs-alpha-test psql -At -v ON_ERROR_STOP=1 <<'SQL'
SELECT persistence_outcome
FROM persist_statement_occurrence(
    'tenant-recovery',
    '2.0',
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
