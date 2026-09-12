BEGIN;

LOCK TABLE
    tenant_partition,
    tenant_database_principal,
    ingestion_receipt,
    statement_record,
    statement_ingestion_item,
    voiding_relation
IN ACCESS EXCLUSIVE MODE;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM tenant_partition)
       OR EXISTS (SELECT 1 FROM tenant_database_principal)
       OR EXISTS (SELECT 1 FROM ingestion_receipt)
       OR EXISTS (SELECT 1 FROM statement_record)
       OR EXISTS (SELECT 1 FROM statement_ingestion_item)
       OR EXISTS (SELECT 1 FROM voiding_relation) THEN
        RAISE EXCEPTION 'refusing rollback while learning record evidence or tenant bindings exist'
            USING ERRCODE = '55000';
    END IF;
END
$$;

DROP FUNCTION persist_statement_batch(text, text, bytea, text[], text[], bytea[], bytea[]);
DROP FUNCTION persist_statement_occurrence(text, text, bytea, integer, text, text, bytea, bytea);

DROP TABLE voiding_relation;
DROP TABLE statement_ingestion_item;
DROP TABLE statement_record;
DROP TABLE ingestion_receipt;
DROP TABLE tenant_database_principal;
DROP TABLE tenant_partition;

DROP FUNCTION enforce_voiding_statement_roles();
DROP FUNCTION statement_comparison_version_for_xapi(text);
DROP FUNCTION statement_advisory_lock_key(text, text);
DROP FUNCTION authorized_tenant_key();

COMMIT;
