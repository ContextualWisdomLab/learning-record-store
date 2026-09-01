BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'lrs_evidence_writer'
    ) THEN
        CREATE ROLE lrs_evidence_writer
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOINHERIT
            NOBYPASSRLS;
    END IF;
END
$$;

ALTER ROLE lrs_evidence_writer
    NOLOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOINHERIT
    NOBYPASSRLS;

CREATE TABLE tenant_database_principal (
    database_principal_name text PRIMARY KEY,
    tenant_key text NOT NULL,
    bound_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tenant_database_principal_name_nonblank
        CHECK (btrim(database_principal_name) <> ''),
    CONSTRAINT tenant_database_principal_tenant_fk
        FOREIGN KEY (tenant_key)
        REFERENCES tenant_partition (tenant_key)
);

REVOKE ALL ON tenant_database_principal FROM PUBLIC;
GRANT SELECT ON tenant_database_principal TO lrs_evidence_writer;

CREATE FUNCTION authorized_tenant_key()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT binding.tenant_key
    FROM public.tenant_database_principal AS binding
    WHERE binding.database_principal_name = session_user
$$;

ALTER FUNCTION authorized_tenant_key() OWNER TO lrs_evidence_writer;
REVOKE ALL ON FUNCTION authorized_tenant_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION authorized_tenant_key() TO PUBLIC;

ALTER POLICY tenant_partition_scope_policy ON tenant_partition
    USING (tenant_key = authorized_tenant_key())
    WITH CHECK (tenant_key = authorized_tenant_key());

ALTER POLICY ingestion_receipt_scope_policy ON ingestion_receipt
    USING (tenant_key = authorized_tenant_key())
    WITH CHECK (tenant_key = authorized_tenant_key());

ALTER POLICY statement_record_scope_policy ON statement_record
    USING (tenant_key = authorized_tenant_key())
    WITH CHECK (tenant_key = authorized_tenant_key());

ALTER POLICY statement_ingestion_scope_policy ON statement_ingestion_item
    USING (tenant_key = authorized_tenant_key())
    WITH CHECK (tenant_key = authorized_tenant_key());

ALTER POLICY voiding_relation_scope_policy ON voiding_relation
    USING (tenant_key = authorized_tenant_key())
    WITH CHECK (tenant_key = authorized_tenant_key());

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation
FROM PUBLIC;

GRANT SELECT ON tenant_partition, ingestion_receipt, statement_record, statement_ingestion_item, voiding_relation
TO lrs_evidence_writer;
GRANT INSERT ON ingestion_receipt, statement_record, statement_ingestion_item
TO lrs_evidence_writer;
GRANT USAGE, SELECT ON SEQUENCE ingestion_receipt_receipt_number_seq
TO lrs_evidence_writer;

CREATE OR REPLACE FUNCTION persist_statement_occurrence(
    p_tenant_key text,
    p_received_xapi_version text,
    p_raw_request_bytes bytea,
    p_request_statement_index integer,
    p_statement_key text,
    p_statement_comparison_version text,
    p_comparison_bytes bytea,
    p_raw_statement_bytes bytea
)
RETURNS TABLE (
    persisted_receipt_number bigint,
    persistence_outcome text,
    persisted_statement_key text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_receipt_number bigint;
    v_inserted boolean;
    v_existing public.statement_record%ROWTYPE;
    v_request_content_hash bytea;
    v_content_hash bytea;
    v_outcome text;
    v_resolved_statement_key text;
    v_authorized_tenant_key text;
BEGIN
    v_authorized_tenant_key := public.authorized_tenant_key();
    IF v_authorized_tenant_key IS NULL
       OR p_tenant_key IS DISTINCT FROM v_authorized_tenant_key THEN
        RAISE EXCEPTION 'database principal is not authorized for requested tenant'
            USING ERRCODE = '42501';
    END IF;

    IF p_request_statement_index < 0 THEN
        RAISE EXCEPTION 'request statement index must be nonnegative'
            USING ERRCODE = '22023';
    END IF;
    IF btrim(p_received_xapi_version) = ''
       OR btrim(p_statement_key) = ''
       OR btrim(p_statement_comparison_version) = '' THEN
        RAISE EXCEPTION 'statement persistence identity/version fields must be nonblank'
            USING ERRCODE = '22023';
    END IF;
    IF octet_length(p_raw_request_bytes) = 0
       OR octet_length(p_comparison_bytes) = 0
       OR octet_length(p_raw_statement_bytes) = 0 THEN
        RAISE EXCEPTION 'statement persistence evidence bytes must be nonempty'
            USING ERRCODE = '22023';
    END IF;

    v_request_content_hash := pg_catalog.sha256(p_raw_request_bytes);
    v_content_hash := pg_catalog.sha256(p_comparison_bytes);

    INSERT INTO public.ingestion_receipt (
        tenant_key,
        received_xapi_version,
        raw_request_bytes,
        request_content_hash
    ) VALUES (
        p_tenant_key,
        p_received_xapi_version,
        p_raw_request_bytes,
        v_request_content_hash
    )
    RETURNING receipt_number INTO v_receipt_number;

    WITH inserted_statement AS (
        INSERT INTO public.statement_record (
            tenant_key,
            statement_key,
            received_xapi_version,
            statement_comparison_version,
            content_hash,
            comparison_bytes,
            raw_statement_bytes
        ) VALUES (
            p_tenant_key,
            p_statement_key,
            p_received_xapi_version,
            p_statement_comparison_version,
            v_content_hash,
            p_comparison_bytes,
            p_raw_statement_bytes
        )
        ON CONFLICT (tenant_key, statement_key) DO NOTHING
        RETURNING true AS inserted
    )
    SELECT EXISTS (SELECT 1 FROM inserted_statement) INTO v_inserted;

    IF v_inserted THEN
        v_outcome := 'accepted';
        v_resolved_statement_key := p_statement_key;
    ELSE
        SELECT statement_row.*
        INTO STRICT v_existing
        FROM public.statement_record AS statement_row
        WHERE statement_row.tenant_key = p_tenant_key
          AND statement_row.statement_key = p_statement_key;

        IF v_existing.received_xapi_version = p_received_xapi_version
           AND v_existing.statement_comparison_version = p_statement_comparison_version
           AND v_existing.content_hash = v_content_hash
           AND v_existing.comparison_bytes = p_comparison_bytes THEN
            v_outcome := 'replayed';
            v_resolved_statement_key := p_statement_key;
        ELSE
            v_outcome := 'conflict';
            v_resolved_statement_key := NULL;
        END IF;
    END IF;

    INSERT INTO public.statement_ingestion_item (
        tenant_key,
        receipt_number,
        request_statement_index,
        submitted_statement_key,
        comparison_outcome,
        resolved_statement_key
    ) VALUES (
        p_tenant_key,
        v_receipt_number,
        p_request_statement_index,
        p_statement_key,
        v_outcome,
        v_resolved_statement_key
    );

    RETURN QUERY
    SELECT v_receipt_number, v_outcome, v_resolved_statement_key;
END;
$$;

ALTER FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) OWNER TO lrs_evidence_writer;

REVOKE ALL ON FUNCTION persist_statement_occurrence(
    text, text, bytea, integer, text, text, bytea, bytea
) FROM PUBLIC;

COMMIT;
