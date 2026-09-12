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
        CHECK (database_principal_name !~ '^[[:space:]]*$'),
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

CREATE FUNCTION statement_advisory_lock_key(
    p_tenant_key text,
    p_statement_key text
)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT
        (get_byte(lock_digest, 0)::bigint << 56)
        | (get_byte(lock_digest, 1)::bigint << 48)
        | (get_byte(lock_digest, 2)::bigint << 40)
        | (get_byte(lock_digest, 3)::bigint << 32)
        | (get_byte(lock_digest, 4)::bigint << 24)
        | (get_byte(lock_digest, 5)::bigint << 16)
        | (get_byte(lock_digest, 6)::bigint << 8)
        | get_byte(lock_digest, 7)::bigint
    FROM (
        SELECT pg_catalog.sha256(
            pg_catalog.int8send(
                octet_length(pg_catalog.convert_to(p_tenant_key, 'UTF8'))::bigint
            )
            || pg_catalog.convert_to(p_tenant_key, 'UTF8')
            || pg_catalog.convert_to(p_statement_key, 'UTF8')
        ) AS lock_digest
    ) AS derived_lock;
$$;

ALTER FUNCTION statement_advisory_lock_key(text, text) OWNER TO lrs_evidence_writer;
REVOKE ALL ON FUNCTION statement_advisory_lock_key(text, text) FROM PUBLIC;

CREATE FUNCTION statement_comparison_version_for_xapi(
    p_received_xapi_version text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT CASE
        WHEN p_received_xapi_version IN ('2.0', '2.0.0')
            THEN 'xapi-2.0-statement-comparison/v1'
        WHEN p_received_xapi_version = '1.0'
          OR p_received_xapi_version ~ '^1\.0\.(0|[1-9][0-9]*)$'
            THEN 'xapi-1.0.3-statement-comparison/v1'
        ELSE NULL
    END;
$$;

ALTER FUNCTION statement_comparison_version_for_xapi(text) OWNER TO lrs_evidence_writer;
REVOKE ALL ON FUNCTION statement_comparison_version_for_xapi(text) FROM PUBLIC;

CREATE FUNCTION canonical_xapi_version_label(
    p_received_xapi_version text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT CASE
        WHEN p_received_xapi_version IN ('2.0', '2.0.0') THEN '2.0.0'
        WHEN p_received_xapi_version = '1.0'
          OR p_received_xapi_version ~ '^1\.0\.(0|[1-9][0-9]*)$'
            THEN '1.0.0'
        ELSE NULL
    END;
$$;

ALTER FUNCTION canonical_xapi_version_label(text) OWNER TO lrs_evidence_writer;
REVOKE ALL ON FUNCTION canonical_xapi_version_label(text) FROM PUBLIC;

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
    v_canonical_xapi_version text;
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
    IF p_received_xapi_version IS NULL
       OR p_received_xapi_version ~ '^[[:space:]]*$'
       OR p_statement_key IS NULL
       OR p_statement_key ~ '^[[:space:]]*$'
       OR p_statement_comparison_version IS NULL
       OR p_statement_comparison_version ~ '^[[:space:]]*$' THEN
        RAISE EXCEPTION 'statement persistence identity/version fields must be nonblank'
            USING ERRCODE = '22023';
    END IF;
    IF public.statement_comparison_version_for_xapi(p_received_xapi_version)
       IS DISTINCT FROM p_statement_comparison_version THEN
        RAISE EXCEPTION 'xAPI version and Statement comparison version are incompatible'
            USING ERRCODE = '22023';
    END IF;
    v_canonical_xapi_version := public.canonical_xapi_version_label(p_received_xapi_version);
    IF octet_length(p_raw_request_bytes) = 0
       OR octet_length(p_comparison_bytes) = 0
       OR octet_length(p_raw_statement_bytes) = 0 THEN
        RAISE EXCEPTION 'statement persistence evidence bytes must be nonempty'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
        public.statement_advisory_lock_key(p_tenant_key, p_statement_key)
    );

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
            v_canonical_xapi_version,
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

        IF v_existing.received_xapi_version = v_canonical_xapi_version
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

CREATE FUNCTION enforce_voiding_statement_roles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_first_statement_key text;
    v_second_statement_key text;
BEGIN
    v_first_statement_key := LEAST(NEW.voiding_statement_key, NEW.voided_statement_key);
    v_second_statement_key := GREATEST(NEW.voiding_statement_key, NEW.voided_statement_key);

    PERFORM pg_catalog.pg_advisory_xact_lock(
        public.statement_advisory_lock_key(NEW.tenant_key, v_first_statement_key)
    );
    IF v_second_statement_key IS DISTINCT FROM v_first_statement_key THEN
        PERFORM pg_catalog.pg_advisory_xact_lock(
            public.statement_advisory_lock_key(NEW.tenant_key, v_second_statement_key)
        );
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.voiding_relation AS existing_relation
        WHERE existing_relation.tenant_key = NEW.tenant_key
          AND (
              existing_relation.voiding_statement_key = NEW.voided_statement_key
              OR existing_relation.voided_statement_key = NEW.voiding_statement_key
          )
    ) THEN
        RAISE EXCEPTION 'a voiding Statement cannot itself be voided'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION enforce_voiding_statement_roles() OWNER TO lrs_evidence_writer;
REVOKE ALL ON FUNCTION enforce_voiding_statement_roles() FROM PUBLIC;

CREATE TRIGGER voiding_statement_roles_guard
BEFORE INSERT ON voiding_relation
FOR EACH ROW
EXECUTE FUNCTION enforce_voiding_statement_roles();

COMMIT;
