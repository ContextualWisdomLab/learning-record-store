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
        (comparison_outcome IN ('accepted', 'replayed') AND resolved_statement_key IS NOT NULL)
        OR (comparison_outcome = 'conflict' AND resolved_statement_key IS NULL)
    )
);

CREATE TABLE voiding_relation (
    tenant_key text NOT NULL,
    voiding_statement_key text NOT NULL,
    voided_statement_key text NOT NULL,
    recorded_timestamp timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant_key, voiding_statement_key, voided_statement_key),
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

COMMIT;
