//! Fail-closed public boundary for the Learning Record Store Statement kernel.
//!
//! The implementation in `lib.rs` owns statement identity/replay semantics. This root module
//! adds public cardinality guards whose limits must remain representable by the durable
//! PostgreSQL occurrence identity and prevents in-memory receipt identity reuse.

#[path = "lib.rs"]
mod kernel_impl;

pub use kernel_impl::{
    IngestionError, IngestionOutcome, IngestionReceipt, IngestionStatus, StatementCandidate,
    StatementOccurrence, StoredStatement, TenantKey, VoidingRelation, XapiVersion,
};

const MAX_DURABLE_BATCH_STATEMENT_COUNT: usize = i32::MAX as usize + 1;
const MAX_DURABLE_RECEIPT_NUMBER: u64 = i64::MAX as u64;
const MAX_DURABLE_REQUEST_STATEMENT_INDEX: u32 = i32::MAX as u32;

/// Executable identity/replay kernel with fail-closed durable-cardinality guards.
///
/// This public boundary delegates statement semantics to the internal kernel while ensuring that
/// every emitted receipt number fits PostgreSQL `bigint`, every zero-based occurrence index fits
/// PostgreSQL `integer`, and no in-memory identity can be accepted when durable storage could not
/// represent it.
#[derive(Debug, Default)]
pub struct StatementKernel {
    inner: kernel_impl::StatementKernel,
    next_receipt_number: u64,
}

impl StatementKernel {
    fn ensure_receipt_capacity(&self) -> Result<(), IngestionError> {
        if self.next_receipt_number >= MAX_DURABLE_RECEIPT_NUMBER {
            return Err(IngestionError::InvalidEvidence {
                field: "receipt_sequence",
            });
        }
        Ok(())
    }

    fn sync_receipt_sequence(&mut self) {
        if let Some(receipt) = self.inner.receipts().last() {
            self.next_receipt_number = receipt.receipt_number();
        }
    }

    /// Creates one immutable request receipt while rejecting durable sequence exhaustion.
    pub fn begin_request(
        &mut self,
        tenant_key: TenantKey,
        received_xapi_version: XapiVersion,
        raw_request_bytes: Vec<u8>,
    ) -> Result<u64, IngestionError> {
        if !raw_request_bytes.is_empty() {
            self.ensure_receipt_capacity()?;
        }
        let result = self.inner.begin_request(
            tenant_key,
            received_xapi_version,
            raw_request_bytes,
        );
        self.sync_receipt_sequence();
        result
    }

    /// Accepts one validated Statement, replays exact evidence, or retains a conflict receipt.
    pub fn ingest(
        &mut self,
        candidate: StatementCandidate,
    ) -> Result<IngestionOutcome, IngestionError> {
        self.ensure_receipt_capacity()?;
        let result = self.inner.ingest(candidate);
        self.sync_receipt_sequence();
        result
    }

    /// Applies one validated POST array under the durable occurrence-cardinality boundary.
    ///
    /// The candidate collection must expose an exact length because the kernel performs complete
    /// request preflight before canonical writes; streaming/filtering adapters must finish protocol
    /// validation and materialize their candidate collection before crossing this boundary. The
    /// exact length is checked before any item is materialized here or any receipt is issued, and
    /// is revalidated after collection so inconsistent iterators fail closed.
    pub fn ingest_batch<I>(
        &mut self,
        tenant_key: TenantKey,
        received_xapi_version: XapiVersion,
        raw_request_bytes: Vec<u8>,
        candidates: I,
    ) -> Result<Vec<IngestionOutcome>, IngestionError>
    where
        I: IntoIterator<Item = StatementCandidate>,
        I::IntoIter: ExactSizeIterator,
    {
        let candidate_iterator = candidates.into_iter();
        let declared_count = candidate_iterator.len();
        if declared_count > MAX_DURABLE_BATCH_STATEMENT_COUNT {
            return Err(IngestionError::InvalidEvidence {
                field: "statement_batch_cardinality",
            });
        }

        let materialized: Vec<_> = candidate_iterator.collect();
        if materialized.len() != declared_count {
            return Err(IngestionError::InvalidEvidence {
                field: "statement_batch_cardinality",
            });
        }
        if !materialized.is_empty() {
            self.ensure_receipt_capacity()?;
        }

        let result = self.inner.ingest_batch(
            tenant_key,
            received_xapi_version,
            raw_request_bytes,
            materialized,
        );
        self.sync_receipt_sequence();
        result
    }

    /// Applies one validated Statement item to an existing immutable request receipt.
    pub fn ingest_at_receipt(
        &mut self,
        receipt_number: u64,
        request_statement_index: u32,
        candidate: StatementCandidate,
    ) -> Result<IngestionOutcome, IngestionError> {
        if request_statement_index > MAX_DURABLE_REQUEST_STATEMENT_INDEX {
            return Err(IngestionError::InvalidEvidence {
                field: "request_statement_index",
            });
        }
        self.inner
            .ingest_at_receipt(receipt_number, request_statement_index, candidate)
    }

    /// Returns one Statement only within the supplied tenant scope.
    #[must_use]
    pub fn statement(
        &self,
        tenant_key: &TenantKey,
        statement_key: &str,
    ) -> Option<&StoredStatement> {
        self.inner.statement(tenant_key, statement_key)
    }

    /// Returns the number of accepted canonical Statement identities.
    #[must_use]
    pub fn statement_count(&self) -> usize {
        self.inner.statement_count()
    }

    /// Returns immutable request receipts, including rejected conflicts.
    #[must_use]
    pub fn receipts(&self) -> &[IngestionReceipt] {
        self.inner.receipts()
    }

    /// Returns every request-to-Statement occurrence in arrival order.
    #[must_use]
    pub fn occurrences(&self) -> &[StatementOccurrence] {
        self.inner.occurrences()
    }

    /// Records a tenant-local one-target voiding relation without deleting either Statement.
    pub fn record_voiding(
        &mut self,
        tenant_key: &TenantKey,
        voiding_statement_key: &str,
        voided_statement_key: &str,
    ) -> Result<(), IngestionError> {
        self.inner.record_voiding(
            tenant_key,
            voiding_statement_key,
            voided_statement_key,
        )
    }

    /// Returns all non-destructive voiding relations.
    #[must_use]
    pub fn voiding_relations(&self) -> Vec<&VoidingRelation> {
        self.inner.voiding_relations()
    }
}

#[cfg(test)]
mod cardinality_tests {
    use super::*;

    struct OversizedBatch;

    impl Iterator for OversizedBatch {
        type Item = StatementCandidate;

        fn next(&mut self) -> Option<Self::Item> {
            panic!("oversized batch must be rejected before item materialization");
        }

        fn size_hint(&self) -> (usize, Option<usize>) {
            let count = MAX_DURABLE_BATCH_STATEMENT_COUNT + 1;
            (count, Some(count))
        }
    }

    impl ExactSizeIterator for OversizedBatch {
        fn len(&self) -> usize {
            MAX_DURABLE_BATCH_STATEMENT_COUNT + 1
        }
    }

    fn tenant() -> TenantKey {
        TenantKey::new("tenant-cardinality").expect("fixture tenant must be valid")
    }

    fn candidate(statement_key: &str) -> StatementCandidate {
        StatementCandidate::new(
            tenant(),
            statement_key,
            XapiVersion::V2_0,
            br#"{"id":"statement-cardinality"}"#.to_vec(),
            br#"{"id":"statement-cardinality"}"#.to_vec(),
        )
        .expect("fixture candidate must be valid")
    }

    #[test]
    fn durable_bigint_receipt_sequence_exhaustion_fails_closed() {
        let mut kernel = StatementKernel {
            inner: kernel_impl::StatementKernel::default(),
            next_receipt_number: MAX_DURABLE_RECEIPT_NUMBER,
        };

        let error = kernel
            .begin_request(tenant(), XapiVersion::V2_0, br#"{}"#.to_vec())
            .expect_err("PostgreSQL bigint receipt numbers must never overflow");

        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "receipt_sequence"
            }
        );
        assert!(kernel.receipts().is_empty());
    }

    #[test]
    fn empty_request_validation_precedes_receipt_sequence_exhaustion() {
        let mut kernel = StatementKernel {
            inner: kernel_impl::StatementKernel::default(),
            next_receipt_number: MAX_DURABLE_RECEIPT_NUMBER,
        };

        let error = kernel
            .begin_request(tenant(), XapiVersion::V2_0, Vec::new())
            .expect_err("empty evidence remains the first failure");

        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "raw_request_bytes"
            }
        );
        assert!(kernel.receipts().is_empty());
    }

    #[test]
    fn oversized_batch_fails_closed_on_public_ingestion_path_before_materialization() {
        let mut kernel = StatementKernel::default();

        let error = kernel
            .ingest_batch(
                tenant(),
                XapiVersion::V2_0,
                br#"[]"#.to_vec(),
                OversizedBatch,
            )
            .expect_err("unpersistable occurrence indexes must fail closed");

        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "statement_batch_cardinality"
            }
        );
        assert!(kernel.receipts().is_empty());
        assert!(kernel.occurrences().is_empty());
    }

    #[test]
    fn direct_occurrence_index_above_postgresql_integer_range_fails_closed() {
        let mut kernel = StatementKernel::default();
        let receipt_number = kernel
            .begin_request(tenant(), XapiVersion::V2_0, br#"{}"#.to_vec())
            .expect("fixture receipt must be created");

        let error = kernel
            .ingest_at_receipt(
                receipt_number,
                MAX_DURABLE_REQUEST_STATEMENT_INDEX + 1,
                candidate("statement-cardinality"),
            )
            .expect_err("unpersistable direct occurrence index must fail closed");

        assert_eq!(
            error,
            IngestionError::InvalidEvidence {
                field: "request_statement_index"
            }
        );
        assert!(kernel.occurrences().is_empty());
        assert_eq!(kernel.statement_count(), 0);
    }
}
