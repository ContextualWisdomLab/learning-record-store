//! Fail-closed public boundary for the Learning Record Store Statement kernel.
//!
//! The existing implementation remains isolated in `lib.rs`; this root module owns public
//! cardinality guards whose limits must match the durable PostgreSQL occurrence identity.

#[path = "lib.rs"]
mod kernel_impl;

pub use kernel_impl::{
    IngestionError, IngestionOutcome, IngestionReceipt, IngestionStatus, StatementCandidate,
    StatementKernel, StatementOccurrence, StoredStatement, TenantKey, VoidingRelation, XapiVersion,
};

#[cfg(test)]
mod cardinality_tests {
    use super::*;

    #[test]
    fn receipt_sequence_exhaustion_fails_closed_before_reuse() {
        let error = next_receipt_number(u64::MAX).expect_err("receipt numbers must never repeat");
        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "receipt_sequence"
            }
        );
    }

    #[test]
    fn batch_cardinality_matches_postgresql_integer_occurrence_index() {
        assert!(validate_batch_statement_count(MAX_DURABLE_BATCH_STATEMENT_COUNT).is_ok());
        let error = validate_batch_statement_count(MAX_DURABLE_BATCH_STATEMENT_COUNT + 1)
            .expect_err("unpersistable zero-based occurrence indexes must fail closed");
        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "statement_batch_cardinality"
            }
        );
    }
}
