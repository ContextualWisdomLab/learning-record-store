# Product and technical gap baseline

Last reconciled: 2026-09-01

This ledger records commercialization state from live product guidance, architecture/data-model decisions, implementation, issue/PR evidence, standards traceability, and exact-head GitHub verification. Mutable check/review state is never frozen as a success claim in this file; merge decisions must re-fetch the current PR head and live gates.

## Product responsibility

The Learning Record Store is the authoritative persistence boundary for xAPI statements, xAPI document resources, attachments, and their integrity/provenance evidence. It does not own enrollment, completion policy, authored content, psychometric responses, billing state, or downstream product workflow truth.

## Feature specification

The first executable feature is immutable tenant-scoped Statement ingestion. `statement_validation` supplies received-version-aware comparison bytes; `StatementKernel` decides first acceptance, exact replay, or conflict for `(tenant_key, statement_key)`; every attempt retains exact request evidence; compatibility-version changes cannot silently mutate canonical evidence; and voiding is relational rather than destructive. `migrations/0001_statement_evidence.sql` establishes the first 3NF persistence schema and forced tenant RLS, while the production PostgreSQL transaction adapter remains a separate unfinished layer.

## Current implementation and exact-head status

The active implementation is stacked on bootstrap PR #1 in branch `agent/xapi-ingestion-kernel`. The most recent runtime behavior commit is `8b7a5c8cc19447bc4eea5bb56de3c318e8c491d6`; subsequent commits add schema, requirements, quality gates, data-model reconciliation, and changelog evidence. The branch head changes when this ledger is committed, so its merge status must be resolved from the pull request's live `head.sha`, not a self-referential SHA stored here.

| Area | Evidence | Current state | Remaining commercialization gap | Next verification |
| --- | --- | --- | --- | --- |
| Authority/PRD/TRD | README, ADR 0001, ARCHITECTURE, PRD, TRD | Product and runtime boundary defined | No released API/service contract yet | Review stacked PR against bootstrap and downstream consumer boundary |
| Rust identity/replay kernel | `src/lib.rs`, `tests/ingestion_kernel.rs` | Implemented on stack | Exact-head hosted Rust checks have not yet proven compile/lint/docs/coverage | Require current-head quality run, then repair any concrete failure |
| Statement identity | `(tenant_key, statement_key)`, version/comparator equality, SHA-256 + comparison-byte confirmation | Executable deterministic core | No real PostgreSQL race proof | Add durable repository and concurrent identical/conflicting UPSERT tests |
| Request provenance | exact raw bytes in `IngestionReceipt`; `ingestion_receipt` + `statement_ingestion_item` schema | Core + schema implemented | Batch parser/span retention and durable conflict-commit behavior unproven | PostgreSQL integration test must prove conflict audit survives application error response |
| Tenant isolation | composite tenant keys/FKs; forced RLS using `app.tenant_key` | Schema baseline implemented | No application-equivalent DB role test; migration owner could bypass ordinary assumptions | Run RLS adversarial tests with non-superuser/non-`BYPASSRLS` role |
| Persistence naming/3NF | multiword snake_case tables/columns; normalized receipt, statement, occurrence, void relation | Implemented baseline | Schema apply/reapply/rollback and lock behavior not tested | Real PostgreSQL migration and contention fixture |
| Canonical protocol | xAPI 2.0 canonical; 1.0.3/cmi5 explicit compatibility surface | Boundary implemented, parser absent | No executable version-specific parser/comparator or conformance suite | Implement lossless validation/comparison before HTTP endpoint |
| Document resources | planned current-state + immutable revision model | Defined only | CRUD, conditional requests, concurrency semantics absent | Separate document-resource implementation slice |
| Attachments | planned content-addressed immutable storage | Defined only | No blob storage, malicious-content non-execution, integrity or authorization proof | Dedicated attachment implementation/tests |
| Compatibility provenance | compatibility adapter/artifact boundary | Defined only | No transformation or reproducibility evidence | Implement only after canonical parser is proven |
| CI quality | stacked-PR trigger, pinned Rust toolchain action, fmt/test/clippy/rustdoc, pinned cargo-llvm-cov 100% line gate | Workflow implemented | Hosted runner allocation and exact-head result are external/live | Require current-head check completion; predecessor-head success is invalid evidence |
| Security/operability | forced RLS schema and immutable evidence model | Partial | No service authn/z, backup/restore, compose deployment, telemetry, recovery or load evidence | Add durable service slice before release-readiness claim |

## DDD/context map

**Core subdomain:** Learning Record Evidence. **Supporting:** Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence. **Generic:** PostgreSQL durability, object storage, telemetry, deployment, and recovery.

The Learning Record Evidence bounded context uses `StatementCandidate`, `StoredStatement`, `IngestionReceipt`, `StatementOccurrence`, and `VoidingRelation`. `StatementKernel` is the domain service for the deterministic identity/replay decision. A future `StatementEvidenceRepository` owns the durable transaction. Canonical Statement plus its immutable ingest/voiding facts form the minimum consistency boundary; no tenant-wide lock is permitted. Potential domain events (`StatementAccepted`, `StatementReplayed`, `StatementConflictObserved`, `StatementVoided`) are emitted only after durable commit when a real consumer exists.

Learning Management Platform consumes released learning evidence for progression/completion policy. `learning-interoperability-contracts` owns reusable cross-product interoperability definitions. Compatibility adapters are an anti-corruption layer and never become a shared kernel of canonical learning truth. Cross-repository database reads are forbidden.

## Persistence and transaction invariants

Relational authoritative facts remain in 3NF. Named persistence objects use at least two semantic words and `snake_case`. Every tenant-owned reference carries `tenant_key`. Raw evidence is stored as bytes, not normalized JSON. The item-level UPSERT contract is explicit: validate first; persist request evidence; serialize only the target `(tenant_key, statement_key)` identity; insert once or compare received version/comparison algorithm/digest/comparison bytes; persist `accepted`, `replayed`, or `conflict`; and commit audit evidence even when the HTTP/API result is a conflict. A conflict must never be implemented by rolling back its receipt.

Hot-key lock waits and contention must be measured before partitioning or read/write separation. No heuristic sharding or weighting is introduced without measured evidence.

## Active gap order

1. Open and validate the stacked ingestion PR; repair current-head Rust/coverage/review findings without weakening gates.
2. Merge bootstrap PR #1 only after its own live current-head reviews and required checks pass, then retarget/revalidate the ingestion PR against `develop`.
3. Implement the PostgreSQL `StatementEvidenceRepository` and prove atomic identical/conflicting races, RLS isolation, migration lifecycle, and durable conflict receipts.
4. Implement version-specific lossless xAPI parsing/comparison and executable xAPI 2.0 conformance traceability.
5. Add document resources, compatibility provenance, then attachments as separate bounded slices.
6. Add authenticated asynchronous service/deployment/recovery/load evidence before any production-readiness or standards-certification claim.
