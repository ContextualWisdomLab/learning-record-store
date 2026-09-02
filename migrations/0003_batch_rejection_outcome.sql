BEGIN;

ALTER TABLE statement_ingestion_item
    DROP CONSTRAINT statement_ingestion_outcome_allowed,
    DROP CONSTRAINT statement_ingestion_resolution_consistent;

ALTER TABLE statement_ingestion_item
    ADD CONSTRAINT statement_ingestion_outcome_allowed
        CHECK (comparison_outcome IN ('accepted', 'replayed', 'conflict', 'batch_rejected')),
    ADD CONSTRAINT statement_ingestion_resolution_consistent CHECK (
        (comparison_outcome IN ('accepted', 'replayed')
            AND resolved_statement_key IS NOT NULL
            AND resolved_statement_key = submitted_statement_key)
        OR (comparison_outcome IN ('conflict', 'batch_rejected')
            AND resolved_statement_key IS NULL)
    );

COMMIT;
