BEGIN;

CREATE FUNCTION persist_statement_batch(
    p_tenant_key text,
    p_received_xapi_version text,
    p_raw_request_bytes bytea,
    p_statement_keys text[],
    p_statement_comparison_versions text[],
    p_comparison_bytes bytea[],
    p_raw_statement_bytes bytea[]
)
RETURNS TABLE (
    persisted_receipt_number bigint,
    request_statement_index integer,
    persistence_outcome text,
    persisted_statement_key text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_authorized_tenant_key text;
    v_item_count integer;
    v_item_position integer;
    v_statement_key text;
    v_receipt_number bigint;
    v_request_content_hash bytea;
    v_content_hash bytea;
    v_existing public.statement_record%ROWTYPE;
    v_candidate_outcomes text[] := ARRAY[]::text[];
    v_candidate_resolutions text[] := ARRAY[]::text[];
    v_candidate_outcome text;
    v_candidate_resolution text;
    v_has_conflict boolean := false;
BEGIN
    v_authorized_tenant_key := public.authorized_tenant_key();
    IF v_authorized_tenant_key IS NULL
       OR p_tenant_key IS DISTINCT FROM v_authorized_tenant_key THEN
        RAISE EXCEPTION 'database principal is not authorized for requested tenant'
            USING ERRCODE = '42501';
    END IF;

    IF p_received_xapi_version IS NULL
       OR p_received_xapi_version ~ '^[[:space:]]*$'
       OR p_raw_request_bytes IS NULL
       OR octet_length(p_raw_request_bytes) = 0 THEN
        RAISE EXCEPTION 'batch request version and evidence bytes must be present'
            USING ERRCODE = '22023';
    END IF;

    IF p_statement_keys IS NULL
       OR p_statement_comparison_versions IS NULL
       OR p_comparison_bytes IS NULL
       OR p_raw_statement_bytes IS NULL
       OR array_ndims(p_statement_keys) IS DISTINCT FROM 1
       OR array_ndims(p_statement_comparison_versions) IS DISTINCT FROM 1
       OR array_ndims(p_comparison_bytes) IS DISTINCT FROM 1
       OR array_ndims(p_raw_statement_bytes) IS DISTINCT FROM 1
       OR array_lower(p_statement_keys, 1) IS DISTINCT FROM 1
       OR array_lower(p_statement_comparison_versions, 1) IS DISTINCT FROM 1
       OR array_lower(p_comparison_bytes, 1) IS DISTINCT FROM 1
       OR array_lower(p_raw_statement_bytes, 1) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'batch evidence arrays must be one-dimensional and one-based'
            USING ERRCODE = '22023';
    END IF;

    v_item_count := cardinality(p_statement_keys);
    IF v_item_count = 0
       OR cardinality(p_statement_comparison_versions) IS DISTINCT FROM v_item_count
       OR cardinality(p_comparison_bytes) IS DISTINCT FROM v_item_count
       OR cardinality(p_raw_statement_bytes) IS DISTINCT FROM v_item_count THEN
        RAISE EXCEPTION 'batch evidence arrays must be nonempty and have equal cardinality'
            USING ERRCODE = '22023';
    END IF;

    FOR v_item_position IN 1..v_item_count LOOP
        IF p_statement_keys[v_item_position] IS NULL
           OR p_statement_keys[v_item_position] ~ '^[[:space:]]*$'
           OR p_statement_comparison_versions[v_item_position] IS NULL
           OR p_statement_comparison_versions[v_item_position] ~ '^[[:space:]]*$'
           OR p_comparison_bytes[v_item_position] IS NULL
           OR octet_length(p_comparison_bytes[v_item_position]) = 0
           OR p_raw_statement_bytes[v_item_position] IS NULL
           OR octet_length(p_raw_statement_bytes[v_item_position]) = 0 THEN
            RAISE EXCEPTION 'batch statement identity, comparison version, and evidence bytes must be present'
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    IF (
        SELECT count(*)
        FROM unnest(p_statement_keys) AS submitted_statement(statement_key)
    ) IS DISTINCT FROM (
        SELECT count(DISTINCT statement_key)
        FROM unnest(p_statement_keys) AS submitted_statement(statement_key)
    ) THEN
        RAISE EXCEPTION 'duplicate statement identity in batch request'
            USING ERRCODE = '22023';
    END IF;

    FOR v_statement_key IN
        SELECT DISTINCT submitted_statement.statement_key
        FROM unnest(p_statement_keys) AS submitted_statement(statement_key)
        ORDER BY submitted_statement.statement_key
    LOOP
        PERFORM pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtext(p_tenant_key),
            pg_catalog.hashtext(v_statement_key)
        );
    END LOOP;

    v_request_content_hash := pg_catalog.sha256(p_raw_request_bytes);
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

    FOR v_item_position IN 1..v_item_count LOOP
        SELECT statement_row.*
        INTO v_existing
        FROM public.statement_record AS statement_row
        WHERE statement_row.tenant_key = p_tenant_key
          AND statement_row.statement_key = p_statement_keys[v_item_position];

        IF FOUND THEN
            v_content_hash := pg_catalog.sha256(p_comparison_bytes[v_item_position]);
            IF v_existing.received_xapi_version = p_received_xapi_version
               AND v_existing.statement_comparison_version = p_statement_comparison_versions[v_item_position]
               AND v_existing.content_hash = v_content_hash
               AND v_existing.comparison_bytes = p_comparison_bytes[v_item_position] THEN
                v_candidate_outcome := 'replayed';
                v_candidate_resolution := p_statement_keys[v_item_position];
            ELSE
                v_candidate_outcome := 'conflict';
                v_candidate_resolution := NULL;
                v_has_conflict := true;
            END IF;
        ELSE
            v_candidate_outcome := 'accepted';
            v_candidate_resolution := p_statement_keys[v_item_position];
        END IF;

        v_candidate_outcomes := array_append(v_candidate_outcomes, v_candidate_outcome);
        v_candidate_resolutions := array_append(v_candidate_resolutions, v_candidate_resolution);
    END LOOP;

    IF v_has_conflict THEN
        FOR v_item_position IN 1..v_item_count LOOP
            IF v_candidate_outcomes[v_item_position] <> 'conflict' THEN
                v_candidate_outcomes[v_item_position] := 'batch_rejected';
                v_candidate_resolutions[v_item_position] := NULL;
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
                v_item_position - 1,
                p_statement_keys[v_item_position],
                v_candidate_outcomes[v_item_position],
                v_candidate_resolutions[v_item_position]
            );

            RETURN QUERY SELECT
                v_receipt_number,
                v_item_position - 1,
                v_candidate_outcomes[v_item_position],
                v_candidate_resolutions[v_item_position];
        END LOOP;
        RETURN;
    END IF;

    FOR v_item_position IN 1..v_item_count LOOP
        IF v_candidate_outcomes[v_item_position] = 'accepted' THEN
            v_content_hash := pg_catalog.sha256(p_comparison_bytes[v_item_position]);
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
                p_statement_keys[v_item_position],
                p_received_xapi_version,
                p_statement_comparison_versions[v_item_position],
                v_content_hash,
                p_comparison_bytes[v_item_position],
                p_raw_statement_bytes[v_item_position]
            );
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
            v_item_position - 1,
            p_statement_keys[v_item_position],
            v_candidate_outcomes[v_item_position],
            v_candidate_resolutions[v_item_position]
        );

        RETURN QUERY SELECT
            v_receipt_number,
            v_item_position - 1,
            v_candidate_outcomes[v_item_position],
            v_candidate_resolutions[v_item_position];
    END LOOP;
END;
$$;

ALTER FUNCTION persist_statement_batch(
    text, text, bytea, text[], text[], bytea[], bytea[]
) OWNER TO lrs_evidence_writer;

REVOKE ALL ON FUNCTION persist_statement_batch(
    text, text, bytea, text[], text[], bytea[], bytea[]
) FROM PUBLIC;

COMMIT;
