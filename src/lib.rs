//! Deterministic xAPI statement-ingestion semantics for the Learning Record Store.
//!
//! This crate owns the immutable identity/replay kernel only. Version-aware xAPI
//! parsing and comparison must produce `comparison_bytes` before constructing a
//! [`StatementCandidate`]. Durable PostgreSQL persistence applies the same decisions
//! transactionally under the `(tenant_key, statement_key)` identity boundary.

use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt::{Display, Formatter};

/// Canonical protocol surfaces accepted by the ingestion kernel.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum XapiVersion {
    /// IEEE xAPI 2.0 canonical surface.
    V2_0,
    /// Legacy xAPI 1.0.3 compatibility surface used by cmi5 Quartz.
    V1_0_3,
}

impl XapiVersion {
    /// Returns the stable persisted protocol label.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::V2_0 => "2.0",
            Self::V1_0_3 => "1.0.3",
        }
    }
}

/// Validated tenant-scoped persistence key.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct TenantKey(String);

impl TenantKey {
    /// Creates a tenant key, rejecting blank identifiers.
    pub fn new(value: impl Into<String>) -> Result<Self, IngestionError> {
        let value = value.into();
        if value.trim().is_empty() {
            return Err(IngestionError::InvalidIdentity {
                field: "tenant_key",
            });
        }
        Ok(Self(value))
    }

    /// Returns the underlying tenant identifier.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// A statement that has already passed the version-specific protocol validator.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StatementCandidate {
    tenant_key: TenantKey,
    statement_key: String,
    received_xapi_version: XapiVersion,
    raw_statement_bytes: Vec<u8>,
    comparison_bytes: Vec<u8>,
}

impl StatementCandidate {
    /// Builds an ingest candidate from exact source bytes and validator-produced comparison bytes.
    ///
    /// `comparison_bytes` must encode the Statement Comparison Requirements for the received
    /// xAPI surface. The kernel never treats HTTP entity bytes as the semantic comparator.
    pub fn new(
        tenant_key: TenantKey,
        statement_key: impl Into<String>,
        received_xapi_version: XapiVersion,
        raw_statement_bytes: Vec<u8>,
        comparison_bytes: Vec<u8>,
    ) -> Result<Self, IngestionError> {
        let statement_key = statement_key.into();
        if statement_key.trim().is_empty() {
            return Err(IngestionError::InvalidIdentity {
                field: "statement_key",
            });
        }
        if raw_statement_bytes.is_empty() {
            return Err(IngestionError::InvalidEvidence {
                field: "raw_statement_bytes",
            });
        }
        if comparison_bytes.is_empty() {
            return Err(IngestionError::InvalidEvidence {
                field: "comparison_bytes",
            });
        }
        Ok(Self {
            tenant_key,
            statement_key,
            received_xapi_version,
            raw_statement_bytes,
            comparison_bytes,
        })
    }
}

/// One immutable accepted Statement identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StoredStatement {
    tenant_key: TenantKey,
    statement_key: String,
    received_xapi_version: XapiVersion,
    statement_comparison_version: &'static str,
    content_hash: [u8; 32],
    comparison_bytes: Vec<u8>,
    raw_statement_bytes: Vec<u8>,
}

impl StoredStatement {
    /// Returns the tenant key that owns this Statement.
    #[must_use]
    pub fn tenant_key(&self) -> &TenantKey {
        &self.tenant_key
    }

    /// Returns the canonical Statement identifier within the tenant.
    #[must_use]
    pub fn statement_key(&self) -> &str {
        &self.statement_key
    }

    /// Returns the exact protocol surface received for this canonical evidence.
    #[must_use]
    pub const fn received_xapi_version(&self) -> XapiVersion {
        self.received_xapi_version
    }

    /// Returns the version of the internal comparison representation.
    #[must_use]
    pub const fn statement_comparison_version(&self) -> &'static str {
        self.statement_comparison_version
    }

    /// Returns the SHA-256 digest of the version-aware comparison representation.
    #[must_use]
    pub const fn content_hash(&self) -> &[u8; 32] {
        &self.content_hash
    }

    /// Returns the exact received Statement bytes retained as immutable evidence.
    #[must_use]
    pub fn raw_statement_bytes(&self) -> &[u8] {
        &self.raw_statement_bytes
    }
}

/// Immutable evidence that one ingestion request occurrence was received.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IngestionReceipt {
    receipt_number: u64,
    tenant_key: TenantKey,
    raw_request_bytes: Vec<u8>,
    request_content_hash: [u8; 32],
    received_xapi_version: XapiVersion,
}

impl IngestionReceipt {
    /// Returns the monotonic receipt number of this executable kernel instance.
    #[must_use]
    pub const fn receipt_number(&self) -> u64 {
        self.receipt_number
    }

    /// Returns the tenant that owns the request evidence.
    #[must_use]
    pub fn tenant_key(&self) -> &TenantKey {
        &self.tenant_key
    }

    /// Returns the exact received bytes retained for this request occurrence.
    #[must_use]
    pub fn raw_request_bytes(&self) -> &[u8] {
        &self.raw_request_bytes
    }

    /// Returns SHA-256 over the exact received request bytes for this occurrence.
    #[must_use]
    pub const fn request_content_hash(&self) -> &[u8; 32] {
        &self.request_content_hash
    }

    /// Returns the protocol version received for the request occurrence.
    #[must_use]
    pub const fn received_xapi_version(&self) -> XapiVersion {
        self.received_xapi_version
    }
}

/// Persisted outcome of one request-to-Statement occurrence.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum IngestionStatus {
    /// A new canonical Statement identity was created.
    Accepted,
    /// The occurrence matched an existing canonical Statement exactly.
    Replayed,
    /// The occurrence reused an identity with incompatible version or content.
    Conflict,
}

/// Immutable per-request association to a canonical Statement identity or rejection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StatementOccurrence {
    receipt_number: u64,
    tenant_key: TenantKey,
    statement_key: String,
    request_statement_index: u32,
    status: IngestionStatus,
}

impl StatementOccurrence {
    /// Returns the request receipt that owns this occurrence.
    #[must_use]
    pub const fn receipt_number(&self) -> u64 {
        self.receipt_number
    }

    /// Returns the request's zero-based Statement index.
    #[must_use]
    pub const fn request_statement_index(&self) -> u32 {
        self.request_statement_index
    }

    /// Returns the persisted ingest decision.
    #[must_use]
    pub const fn status(&self) -> IngestionStatus {
        self.status
    }

    /// Returns the tenant key for this occurrence.
    #[must_use]
    pub fn tenant_key(&self) -> &TenantKey {
        &self.tenant_key
    }

    /// Returns the submitted Statement identifier.
    #[must_use]
    pub fn statement_key(&self) -> &str {
        &self.statement_key
    }
}

/// A non-destructive relation from a voiding Statement to its target Statement.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct VoidingRelation {
    tenant_key: TenantKey,
    voiding_statement_key: String,
    voided_statement_key: String,
}

impl VoidingRelation {
    /// Returns the owning tenant.
    #[must_use]
    pub fn tenant_key(&self) -> &TenantKey {
        &self.tenant_key
    }

    /// Returns the Statement that performs the voiding action.
    #[must_use]
    pub fn voiding_statement_key(&self) -> &str {
        &self.voiding_statement_key
    }

    /// Returns the immutable Statement that is voided but not deleted.
    #[must_use]
    pub fn voided_statement_key(&self) -> &str {
        &self.voided_statement_key
    }
}

/// Successful result of one ingestion attempt.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IngestionOutcome {
    status: IngestionStatus,
    receipt_number: u64,
    statement: StoredStatement,
}

impl IngestionOutcome {
    /// Returns whether this occurrence created or replayed canonical evidence.
    #[must_use]
    pub const fn status(&self) -> IngestionStatus {
        self.status
    }

    /// Returns the immutable request receipt number.
    #[must_use]
    pub const fn receipt_number(&self) -> u64 {
        self.receipt_number
    }

    /// Returns the canonical Statement resolved by this occurrence.
    #[must_use]
    pub fn statement(&self) -> &StoredStatement {
        &self.statement
    }
}

/// Fail-closed errors produced by identity and replay enforcement.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IngestionError {
    /// A required persistence identity was blank.
    InvalidIdentity {
        /// Name of the invalid field.
        field: &'static str,
    },
    /// Required immutable evidence was empty.
    InvalidEvidence {
        /// Name of the invalid evidence field.
        field: &'static str,
    },
    /// An existing `(tenant, statement)` identity does not match the new occurrence.
    StatementConflict {
        /// Request receipt retained for the rejected occurrence.
        receipt_number: u64,
        /// Statement identifier that conflicted.
        statement_key: String,
    },
    /// A requested Statement does not exist within the tenant boundary.
    StatementNotFound {
        /// Missing Statement identifier.
        statement_key: String,
    },
    /// A request receipt number was not issued by this kernel instance.
    ReceiptNotFound {
        /// Unknown receipt number.
        receipt_number: u64,
    },
    /// A Statement item does not belong to the receipt's tenant and protocol context.
    ReceiptContextMismatch {
        /// Receipt whose immutable context did not match the submitted item.
        receipt_number: u64,
    },
    /// An immutable `(receipt, request index)` occurrence already exists.
    OccurrenceAlreadyRecorded {
        /// Receipt that already owns the index.
        receipt_number: u64,
        /// Zero-based request index already recorded.
        request_statement_index: u32,
    },
    /// A POST array reused one Statement identifier inside the same request.
    DuplicateStatementInRequest {
        /// Immutable request receipt retained for the rejected batch.
        receipt_number: u64,
        /// Duplicate Statement identifier.
        statement_key: String,
    },
    /// A voiding Statement attempted an impossible self-relation.
    InvalidVoidingRelation {
        /// Statement that attempted to act as the voiding source.
        voiding_statement_key: String,
        /// Target Statement, equal to the source for this error.
        voided_statement_key: String,
    },
    /// An immutable voiding Statement attempted to acquire a second target.
    VoidingTargetConflict {
        /// Statement that already owns a target relation.
        voiding_statement_key: String,
        /// Existing immutable target.
        existing_voided_statement_key: String,
        /// Conflicting target requested by the caller.
        attempted_voided_statement_key: String,
    },
}

impl Display for IngestionError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidIdentity { field } => write!(formatter, "invalid identity: {field}"),
            Self::InvalidEvidence { field } => write!(formatter, "invalid evidence: {field}"),
            Self::StatementConflict {
                receipt_number,
                statement_key,
            } => write!(
                formatter,
                "statement conflict for {statement_key}; receipt {receipt_number} retained"
            ),
            Self::StatementNotFound { statement_key } => {
                write!(formatter, "statement not found: {statement_key}")
            }
            Self::ReceiptNotFound { receipt_number } => {
                write!(formatter, "request receipt not found: {receipt_number}")
            }
            Self::ReceiptContextMismatch { receipt_number } => {
                write!(formatter, "request receipt context mismatch: {receipt_number}")
            }
            Self::OccurrenceAlreadyRecorded {
                receipt_number,
                request_statement_index,
            } => write!(
                formatter,
                "request occurrence already recorded: receipt {receipt_number}, index {request_statement_index}"
            ),
            Self::DuplicateStatementInRequest {
                receipt_number,
                statement_key,
            } => write!(
                formatter,
                "duplicate statement {statement_key} in request receipt {receipt_number}"
            ),
            Self::InvalidVoidingRelation {
                voiding_statement_key,
                voided_statement_key,
            } => write!(
                formatter,
                "invalid voiding relation: {voiding_statement_key} cannot void {voided_statement_key}"
            ),
            Self::VoidingTargetConflict {
                voiding_statement_key,
                existing_voided_statement_key,
                attempted_voided_statement_key,
            } => write!(
                formatter,
                "voiding target conflict for {voiding_statement_key}: existing target {existing_voided_statement_key}, attempted target {attempted_voided_statement_key}"
            ),
        }
    }
}

impl Error for IngestionError {}

/// Executable identity/replay kernel used to prove immutable ingestion semantics.
///
/// This in-memory kernel is not the production durability layer. It deliberately mirrors the
/// transaction decision that the PostgreSQL repository must execute while holding the unique
/// `(tenant_key, statement_key)` identity. No synthetic records are created by production code.
#[derive(Debug, Default)]
pub struct StatementKernel {
    statements: BTreeMap<(TenantKey, String), StoredStatement>,
    receipts: Vec<IngestionReceipt>,
    occurrences: Vec<StatementOccurrence>,
    voiding_relations: BTreeSet<VoidingRelation>,
    next_receipt_number: u64,
}

impl StatementKernel {
    /// Creates one immutable receipt for the exact bytes of an ingestion request.
    ///
    /// A single receipt may own multiple zero-based Statement occurrences for a POST array. Batch
    /// callers should use [`StatementKernel::ingest_batch`] so conflict or duplicate detection
    /// happens before canonical Statement state changes.
    pub fn begin_request(
        &mut self,
        tenant_key: TenantKey,
        received_xapi_version: XapiVersion,
        raw_request_bytes: Vec<u8>,
    ) -> Result<u64, IngestionError> {
        if raw_request_bytes.is_empty() {
            return Err(IngestionError::InvalidEvidence {
                field: "raw_request_bytes",
            });
        }
        self.next_receipt_number = self.next_receipt_number.saturating_add(1);
        let receipt_number = self.next_receipt_number;
        let request_content_hash = sha256(&raw_request_bytes);
        self.receipts.push(IngestionReceipt {
            receipt_number,
            tenant_key,
            raw_request_bytes,
            request_content_hash,
            received_xapi_version,
        });
        Ok(receipt_number)
    }

    /// Accepts a single-Statement request, reuses an exact replay, or rejects a conflict.
    ///
    /// This convenience path records the Statement bytes as the complete request body at index
    /// zero. POST arrays use [`StatementKernel::ingest_batch`] instead of committing items one at a
    /// time.
    pub fn ingest(
        &mut self,
        candidate: StatementCandidate,
    ) -> Result<IngestionOutcome, IngestionError> {
        let receipt_number = self.begin_request(
            candidate.tenant_key.clone(),
            candidate.received_xapi_version,
            candidate.raw_statement_bytes.clone(),
        )?;
        self.ingest_at_receipt(receipt_number, 0, candidate)
    }

    /// Applies a validated POST array without partially accepting canonical Statement identities.
    ///
    /// The exact request receipt is retained first. Tenant/version mismatch, a duplicate Statement
    /// identifier inside the request, or a conflict with canonical evidence is then discovered by
    /// a read-only preflight before any new `StoredStatement` is inserted. A conflicting item keeps
    /// its occurrence evidence while the rest of the batch makes no canonical changes. Once the
    /// preflight succeeds, applying every item is infallible in this single-threaded reference
    /// kernel and all outcomes share the same request receipt.
    pub fn ingest_batch(
        &mut self,
        tenant_key: TenantKey,
        received_xapi_version: XapiVersion,
        raw_request_bytes: Vec<u8>,
        candidates: Vec<StatementCandidate>,
    ) -> Result<Vec<IngestionOutcome>, IngestionError> {
        if candidates.is_empty() {
            return Err(IngestionError::InvalidEvidence {
                field: "statement_batch",
            });
        }
        let receipt_number = self.begin_request(
            tenant_key.clone(),
            received_xapi_version,
            raw_request_bytes,
        )?;
        let mut statement_keys = BTreeSet::new();

        for (request_statement_index, candidate) in candidates.iter().enumerate() {
            if candidate.tenant_key != tenant_key
                || candidate.received_xapi_version != received_xapi_version
            {
                return Err(IngestionError::ReceiptContextMismatch { receipt_number });
            }
            if !statement_keys.insert(candidate.statement_key.clone()) {
                return Err(IngestionError::DuplicateStatementInRequest {
                    receipt_number,
                    statement_key: candidate.statement_key.clone(),
                });
            }

            let key = (
                candidate.tenant_key.clone(),
                candidate.statement_key.clone(),
            );
            let content_hash = sha256(&candidate.comparison_bytes);
            if let Some(existing) = self.statements.get(&key) {
                let exact_replay = existing.received_xapi_version
                    == candidate.received_xapi_version
                    && existing.statement_comparison_version
                        == comparison_version(candidate.received_xapi_version)
                    && existing.content_hash == content_hash
                    && existing.comparison_bytes == candidate.comparison_bytes;
                if !exact_replay {
                    self.occurrences.push(StatementOccurrence {
                        receipt_number,
                        tenant_key: candidate.tenant_key.clone(),
                        statement_key: candidate.statement_key.clone(),
                        request_statement_index: request_statement_index as u32,
                        status: IngestionStatus::Conflict,
                    });
                    return Err(IngestionError::StatementConflict {
                        receipt_number,
                        statement_key: candidate.statement_key.clone(),
                    });
                }
            }
        }

        let mut outcomes = Vec::with_capacity(candidates.len());
        for (request_statement_index, candidate) in candidates.into_iter().enumerate() {
            let key = (
                candidate.tenant_key.clone(),
                candidate.statement_key.clone(),
            );
            let content_hash = sha256(&candidate.comparison_bytes);
            let (status, statement) = if let Some(existing) = self.statements.get(&key).cloned() {
                (IngestionStatus::Replayed, existing)
            } else {
                let statement = StoredStatement {
                    tenant_key: candidate.tenant_key.clone(),
                    statement_key: candidate.statement_key.clone(),
                    received_xapi_version: candidate.received_xapi_version,
                    statement_comparison_version: comparison_version(
                        candidate.received_xapi_version,
                    ),
                    content_hash,
                    comparison_bytes: candidate.comparison_bytes,
                    raw_statement_bytes: candidate.raw_statement_bytes,
                };
                self.statements.insert(key, statement.clone());
                (IngestionStatus::Accepted, statement)
            };
            self.occurrences.push(StatementOccurrence {
                receipt_number,
                tenant_key: candidate.tenant_key,
                statement_key: candidate.statement_key,
                request_statement_index: request_statement_index as u32,
                status,
            });
            outcomes.push(IngestionOutcome {
                status,
                receipt_number,
                statement,
            });
        }
        Ok(outcomes)
    }

    /// Applies one validated Statement item to an existing immutable request receipt.
    ///
    /// This is the low-level single-item primitive used by `ingest`. Receipt tenant/version context
    /// and the `(receipt_number, request_statement_index)` identity are checked before canonical
    /// Statement state changes. Callers must not build a POST-array transaction by invoking this
    /// method repeatedly; use [`StatementKernel::ingest_batch`] for atomic batch behavior.
    pub fn ingest_at_receipt(
        &mut self,
        receipt_number: u64,
        request_statement_index: u32,
        candidate: StatementCandidate,
    ) -> Result<IngestionOutcome, IngestionError> {
        let receipt = self
            .receipts
            .iter()
            .find(|receipt| receipt.receipt_number == receipt_number)
            .ok_or(IngestionError::ReceiptNotFound { receipt_number })?;
        if receipt.tenant_key != candidate.tenant_key
            || receipt.received_xapi_version != candidate.received_xapi_version
        {
            return Err(IngestionError::ReceiptContextMismatch { receipt_number });
        }
        if self.occurrences.iter().any(|occurrence| {
            occurrence.receipt_number == receipt_number
                && occurrence.request_statement_index == request_statement_index
        }) {
            return Err(IngestionError::OccurrenceAlreadyRecorded {
                receipt_number,
                request_statement_index,
            });
        }

        let key = (
            candidate.tenant_key.clone(),
            candidate.statement_key.clone(),
        );
        let content_hash = sha256(&candidate.comparison_bytes);
        if let Some(existing) = self.statements.get(&key).cloned() {
            let exact_replay = existing.received_xapi_version == candidate.received_xapi_version
                && existing.statement_comparison_version
                    == comparison_version(candidate.received_xapi_version)
                && existing.content_hash == content_hash
                && existing.comparison_bytes == candidate.comparison_bytes;
            let status = if exact_replay {
                IngestionStatus::Replayed
            } else {
                IngestionStatus::Conflict
            };
            self.occurrences.push(StatementOccurrence {
                receipt_number,
                tenant_key: candidate.tenant_key,
                statement_key: candidate.statement_key.clone(),
                request_statement_index,
                status,
            });
            if exact_replay {
                return Ok(IngestionOutcome {
                    status,
                    receipt_number,
                    statement: existing,
                });
            }
            return Err(IngestionError::StatementConflict {
                receipt_number,
                statement_key: candidate.statement_key,
            });
        }

        let statement = StoredStatement {
            tenant_key: candidate.tenant_key.clone(),
            statement_key: candidate.statement_key.clone(),
            received_xapi_version: candidate.received_xapi_version,
            statement_comparison_version: comparison_version(candidate.received_xapi_version),
            content_hash,
            comparison_bytes: candidate.comparison_bytes,
            raw_statement_bytes: candidate.raw_statement_bytes,
        };
        self.statements.insert(key, statement.clone());
        self.occurrences.push(StatementOccurrence {
            receipt_number,
            tenant_key: candidate.tenant_key,
            statement_key: candidate.statement_key,
            request_statement_index,
            status: IngestionStatus::Accepted,
        });
        Ok(IngestionOutcome {
            status: IngestionStatus::Accepted,
            receipt_number,
            statement,
        })
    }

    /// Returns one Statement only within the supplied tenant scope.
    #[must_use]
    pub fn statement(
        &self,
        tenant_key: &TenantKey,
        statement_key: &str,
    ) -> Option<&StoredStatement> {
        self.statements
            .get(&(tenant_key.clone(), statement_key.to_owned()))
    }

    /// Returns the number of accepted canonical Statement identities.
    #[must_use]
    pub fn statement_count(&self) -> usize {
        self.statements.len()
    }

    /// Returns immutable request receipts, including rejected conflicts.
    #[must_use]
    pub fn receipts(&self) -> &[IngestionReceipt] {
        &self.receipts
    }

    /// Returns every request-to-Statement occurrence in arrival order.
    #[must_use]
    pub fn occurrences(&self) -> &[StatementOccurrence] {
        &self.occurrences
    }

    /// Records a tenant-local one-target voiding relation without deleting either Statement.
    ///
    /// Re-registering the same relation is idempotent. A self-relation or a different target for
    /// an already-recorded voiding Statement fails closed so the domain reference matches the
    /// persistence uniqueness contract.
    pub fn record_voiding(
        &mut self,
        tenant_key: &TenantKey,
        voiding_statement_key: &str,
        voided_statement_key: &str,
    ) -> Result<(), IngestionError> {
        for statement_key in [voiding_statement_key, voided_statement_key] {
            if self.statement(tenant_key, statement_key).is_none() {
                return Err(IngestionError::StatementNotFound {
                    statement_key: statement_key.to_owned(),
                });
            }
        }
        if voiding_statement_key == voided_statement_key {
            return Err(IngestionError::InvalidVoidingRelation {
                voiding_statement_key: voiding_statement_key.to_owned(),
                voided_statement_key: voided_statement_key.to_owned(),
            });
        }
        if let Some(existing) = self.voiding_relations.iter().find(|relation| {
            relation.tenant_key == *tenant_key
                && relation.voiding_statement_key == voiding_statement_key
        }) {
            if existing.voided_statement_key == voided_statement_key {
                return Ok(());
            }
            return Err(IngestionError::VoidingTargetConflict {
                voiding_statement_key: voiding_statement_key.to_owned(),
                existing_voided_statement_key: existing.voided_statement_key.clone(),
                attempted_voided_statement_key: voided_statement_key.to_owned(),
            });
        }
        self.voiding_relations.insert(VoidingRelation {
            tenant_key: tenant_key.clone(),
            voiding_statement_key: voiding_statement_key.to_owned(),
            voided_statement_key: voided_statement_key.to_owned(),
        });
        Ok(())
    }

    /// Returns all non-destructive voiding relations.
    #[must_use]
    pub fn voiding_relations(&self) -> Vec<&VoidingRelation> {
        self.voiding_relations.iter().collect()
    }
}

const fn comparison_version(version: XapiVersion) -> &'static str {
    match version {
        XapiVersion::V2_0 => "xapi-2.0-statement-comparison/v1",
        XapiVersion::V1_0_3 => "xapi-1.0.3-statement-comparison/v1",
    }
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
