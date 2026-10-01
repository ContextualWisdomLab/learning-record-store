#!/usr/bin/env bash
set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=learning_record_store}"
: "${PGUSER:=postgres}"
: "${PGPASSWORD:=postgres}"
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

fixture_stage="${1:?usage: postgres_fixture_setup.sh <evidence|atomic|principal|batch-outcomes|batch-transaction>}"

psql -v ON_ERROR_STOP=1 <<'SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT USAGE ON SCHEMA public TO PUBLIC;
SQL

for fixture_role in lrs_app lrs_tenant_alpha lrs_tenant_beta lrs_evidence_writer; do
  if [[ "$(psql -Atq -v role_name="$fixture_role" <<'SQL'
SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'role_name';
SQL
)" == "1" ]]; then
    psql -v ON_ERROR_STOP=1 -v role_name="$fixture_role" <<'SQL'
SELECT format('DROP OWNED BY %I', :'role_name') \gexec
SELECT format('DROP ROLE %I', :'role_name') \gexec
SQL
  fi
done

apply_migration() {
  psql -v ON_ERROR_STOP=1 -f "$1"
}

create_legacy_app_fixture() {
  psql -v ON_ERROR_STOP=1 -v database_name="$PGDATABASE" <<'SQL'
CREATE ROLE lrs_app LOGIN PASSWORD 'lrs-app-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
GRANT CONNECT ON DATABASE :"database_name" TO lrs_app;
GRANT USAGE ON SCHEMA public TO lrs_app;
GRANT SELECT, INSERT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation TO lrs_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO lrs_app;
GRANT EXECUTE ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) TO lrs_app;
INSERT INTO tenant_partition (tenant_key) VALUES ('tenant-alpha'), ('tenant-beta');
SQL
}

create_principal_fixture() {
  psql -v ON_ERROR_STOP=1 -v database_name="$PGDATABASE" <<'SQL'
CREATE ROLE lrs_tenant_alpha LOGIN PASSWORD 'lrs-alpha-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
CREATE ROLE lrs_tenant_beta LOGIN PASSWORD 'lrs-beta-test' NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;

INSERT INTO tenant_partition (tenant_key) VALUES ('tenant-alpha'), ('tenant-beta');
INSERT INTO tenant_database_principal (database_principal_name, tenant_key)
VALUES
    ('lrs_tenant_alpha', 'tenant-alpha'),
    ('lrs_tenant_beta', 'tenant-beta');

GRANT CONNECT ON DATABASE :"database_name" TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT USAGE ON SCHEMA public TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT SELECT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation
    TO lrs_tenant_alpha, lrs_tenant_beta;
GRANT EXECUTE ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) TO lrs_tenant_alpha, lrs_tenant_beta;
SQL
}

case "$fixture_stage" in
  evidence|atomic)
    apply_migration migrations/0001_statement_evidence.sql
    create_legacy_app_fixture
    ;;
  principal)
    apply_migration migrations/0001_statement_evidence.sql
    apply_migration migrations/0002_database_principal_boundary.sql
    create_principal_fixture
    ;;
  batch-outcomes)
    apply_migration migrations/0001_statement_evidence.sql
    apply_migration migrations/0003_batch_rejection_outcome.sql
    psql -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO tenant_partition (tenant_key) VALUES ('tenant-alpha');
SQL
    ;;
  batch-transaction)
    apply_migration migrations/0001_statement_evidence.sql
    apply_migration migrations/0002_database_principal_boundary.sql
    apply_migration migrations/0003_batch_rejection_outcome.sql
    apply_migration migrations/0004_atomic_statement_batch.sql
    create_principal_fixture
    psql -v ON_ERROR_STOP=1 <<'SQL'
GRANT EXECUTE ON FUNCTION persist_statement_batch(
    text, text, bytea, text[], text[], bytea[], bytea[]
) TO lrs_tenant_alpha;
SQL
    ;;
  *)
    echo "unknown PostgreSQL fixture stage: $fixture_stage" >&2
    exit 64
    ;;
esac
