BEGIN;

CREATE TABLE tenant_partition (
    tenant_key text PRIMARY KEY,
    created_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT tenant_partition_key_nonblank CHECK (btrim(tenant_key) <> '')
);

CREATE TABLE ingestion_receipt (
    tenant_key text NOT NULL,
    receipt_number bigint GENERATED ALWAYS AS IDENTITY,
    received_xapi_version text NOT NULL,
    raw_request_bytes bytea NOT NULL,
    request_content_hash bytea NOT NULL,
    received_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_key, receipt_number),
    CONSTRAINT ingestion_receipt_tenant_fk
        FOREIGN KEY (tenant_key)
        REFERENCES tenant_partition (tenant_key),
    CONSTRAINT ingestion_receipt_version_nonblank
        CHECK (btrim(received_xapi_version) <> ''),
    CONSTRAINT ingestion_receipt_request_nonempty
        CHECK (octet_length(raw_request_bytes) > 0),
    CONSTRAINT ingestion_receipt_hash_length
        CHECK (octet_length(request_content_hash) = 32)
);

CREATE TABLE statement_record (
    tenant_key text NOT NULL,
    statement_key text NOT NULL,
    received_xapi_version text NOT NULL,
    statement_comparison_version text NOT NULL,
    content_hash bytea NOT NULL,
    comparison_bytes bytea NOT NULL,
    raw_statement_bytes bytea NOT NULL,
    accepted_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_key, statement_key),
    CONSTRAINT statement_record_tenant_fk
        FOREIGN KEY (tenant_key)
        REFERENCES tenant_partition (tenant_key),
    CONSTRAINT statement_record_key_nonblank
        CHECK (btrim(statement_key) <> ''),
    CONSTRAINT statement_record_version_nonblank
        CHECK (btrim(received_xapi_version) <> ''),
    CONSTRAINT statement_record_comparison_version_nonblank
        CHECK (btrim(statement_comparison_version) <> ''),
    CONSTRAINT statement_record_hash_length
        CHECK (octet_length(content_hash) = 32),
    CONSTRAINT statement_record_comparison_nonempty
        CHECK (octet_length(comparison_bytes) > 0),
    CONSTRAINT statement_record_source_nonempty
        CHECK (octet_length(raw_statement_bytes) > 0)
);

CREATE TABLE statement_ingestion_item (
    tenant_key text NOT NULL,
    receipt_number bigint NOT NULL,
    request_statement_index integer NOT NULL,
    submitted_statement_key text NOT NULL,
    comparison_outcome text NOT NULL,
    resolved_statement_key text,
    PRIMARY KEY (tenant_key, receipt_number, request_statement_index),
    CONSTRAINT statement_ingestion_receipt_fk
        FOREIGN KEY (tenant_key, receipt_number)
        REFERENCES ingestion_receipt (tenant_key, receipt_number),
    CONSTRAINT statement_ingestion_resolved_fk
        FOREIGN KEY (tenant_key, resolved_statement_key)
        REFERENCES statement_record (tenant_key, statement_key),
    CONSTRAINT statement_ingestion_index_nonnegative
        CHECK (request_statement_index >= 0),
    CONSTRAINT statement_ingestion_submitted_nonblank
        CHECK (btrim(submitted_statement_key) <> ''),
    CONSTRAINT statement_ingestion_outcome_allowed
        CHECK (comparison_outcome IN ('accepted', 'replayed', 'conflict')),
    CONSTRAINT statement_ingestion_resolution_consistent CHECK (
        (comparison_outcome IN ('accepted', 'replayed')
            AND resolved_statement_key = submitted_statement_key)
        OR (comparison_outcome = 'conflict' AND resolved_statement_key IS NULL)
    )
);

CREATE TABLE voiding_relation (
    tenant_key text NOT NULL,
    voiding_statement_key text NOT NULL,
    voided_statement_key text NOT NULL,
    recorded_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_key, voiding_statement_key),
    CONSTRAINT voiding_relation_voiding_fk
        FOREIGN KEY (tenant_key, voiding_statement_key)
        REFERENCES statement_record (tenant_key, statement_key),
    CONSTRAINT voiding_relation_voided_fk
        FOREIGN KEY (tenant_key, voided_statement_key)
        REFERENCES statement_record (tenant_key, statement_key),
    CONSTRAINT voiding_relation_distinct_statement
        CHECK (voiding_statement_key <> voided_statement_key)
);

ALTER TABLE tenant_partition ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_partition FORCE ROW LEVEL SECURITY;
ALTER TABLE ingestion_receipt ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingestion_receipt FORCE ROW LEVEL SECURITY;
ALTER TABLE statement_record ENABLE ROW LEVEL SECURITY;
ALTER TABLE statement_record FORCE ROW LEVEL SECURITY;
ALTER TABLE statement_ingestion_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE statement_ingestion_item FORCE ROW LEVEL SECURITY;
ALTER TABLE voiding_relation ENABLE ROW LEVEL SECURITY;
ALTER TABLE voiding_relation FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_partition_scope_policy ON tenant_partition
    USING (tenant_key = current_setting('app.tenant_key', true))
    WITH CHECK (tenant_key = current_setting('app.tenant_key', true));

CREATE POLICY ingestion_receipt_scope_policy ON ingestion_receipt
    USING (tenant_key = current_setting('app.tenant_key', true))
    WITH CHECK (tenant_key = current_setting('app.tenant_key', true));

CREATE POLICY statement_record_scope_policy ON statement_record
    USING (tenant_key = current_setting('app.tenant_key', true))
    WITH CHECK (tenant_key = current_setting('app.tenant_key', true));

CREATE POLICY statement_ingestion_scope_policy ON statement_ingestion_item
    USING (tenant_key = current_setting('app.tenant_key', true))
    WITH CHECK (tenant_key = current_setting('app.tenant_key', true));

CREATE POLICY voiding_relation_scope_policy ON voiding_relation
    USING (tenant_key = current_setting('app.tenant_key', true))
    WITH CHECK (tenant_key = current_setting('app.tenant_key', true));

CREATE FUNCTION persist_statement_occurrence(
    p_tenant_key text,
    p_received_xapi_version text,
    p_raw_request_bytes bytea,
    p_request_content_hash bytea,
    p_request_statement_index integer,
    p_statement_key text,
    p_statement_comparison_version text,
    p_content_hash bytea,
    p_comparison_bytes bytea,
    p_raw_statement_bytes bytea
)
RETURNS TABLE (
    persisted_receipt_number bigint,
    persistence_outcome text,
    persisted_statement_key text
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_receipt_number bigint;
    v_inserted boolean;
    v_existing statement_record%ROWTYPE;
    v_outcome text;
    v_resolved_statement_key text;
BEGIN
    IF p_tenant_key IS DISTINCT FROM current_setting('app.tenant_key', true) THEN
        RAISE EXCEPTION 'tenant context mismatch for statement persistence'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO ingestion_receipt (
        tenant_key,
        received_xapi_version,
        raw_request_bytes,
        request_content_hash
    ) VALUES (
        p_tenant_key,
        p_received_xapi_version,
        p_raw_request_bytes,
        p_request_content_hash
    )
    RETURNING receipt_number INTO v_receipt_number;

    WITH inserted_statement AS (
        INSERT INTO statement_record (
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
            p_content_hash,
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
        FROM statement_record AS statement_row
        WHERE statement_row.tenant_key = p_tenant_key
          AND statement_row.statement_key = p_statement_key;

        IF v_existing.received_xapi_version = p_received_xapi_version
           AND v_existing.statement_comparison_version = p_statement_comparison_version
           AND v_existing.content_hash = p_content_hash
           AND v_existing.comparison_bytes = p_comparison_bytes THEN
            v_outcome := 'replayed';
            v_resolved_statement_key := p_statement_key;
        ELSE
            v_outcome := 'conflict';
            v_resolved_statement_key := NULL;
        END IF;
    END IF;

    INSERT INTO statement_ingestion_item (
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

REVOKE ALL ON FUNCTION persist_statement_occurrence(
    text, text, bytea, bytea, integer, text, text, bytea, bytea, bytea
) FROM PUBLIC;

COMMIT;
