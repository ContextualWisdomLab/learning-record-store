# Product and technical gap baseline

Last reconciled: 2026-09-01

This ledger records commercialization state from live product guidance, architecture/data-model decisions, implementation, issue/PR evidence, standards traceability, and exact-head GitHub verification. Mutable check/review state is never frozen as a success claim in this file; merge decisions must re-fetch the current PR head and live gates.

## Product responsibility

The Learning Record Store is the authoritative persistence boundary for xAPI statements, xAPI document resources, attachments, and their integrity/provenance evidence. It does not own enrollment, completion policy, authored content, psychometric responses, billing state, or downstream product workflow truth.

## Feature specification

The first executable feature is immutable tenant-scoped Statement ingestion. `statement_validation` supplies received-version-aware comparison bytes; `StatementKernel` proves the pure domain decision for first acceptance, exact replay, or conflict at `(tenant_key, statement_key)`; `persist_statement_occurrence` now implements the corresponding first durable PostgreSQL transaction primitive. Every attempt retains exact request evidence, compatibility-version changes cannot silently mutate canonical evidence, and voiding is relational rather than destructive. `migrations/0001_statement_evidence.sql` establishes the 3NF persistence schema, forced tenant RLS, a security-invoker item-level transaction function, and explicit EXECUTE governance. A Rust repository/network adapter and validated-batch shared-receipt transaction remain unfinished.

## Current implementation and exact-head status

The active implementation is stacked on bootstrap PR #1 in branch `agent/xapi-ingestion-kernel`. Its exact head must always be read from the live branch/PR immediately before verification or mutation; this ledger intentionally does not embed a self-referential branch SHA. Current-head GitHub Checks and reviews remain external live gates and are not treated as successful merely because the implementation and test contracts are present in the branch.

| Area | Evidence | Current state | Remaining commercialization gap | Next verification |
| --- | --- | --- | --- | --- |
| Authority/PRD/TRD | README, ADR 0001, ARCHITECTURE, PRD, TRD | Product and runtime boundary defined | No released API/service contract yet | Review stacked PR against bootstrap and downstream consumer boundary |
| Rust identity/replay kernel | `src/lib.rs`, Rust integration tests | Implemented on stack | Exact-head hosted Rust checks must prove compile/lint/docs/coverage | Require current-head quality run; repair any concrete failure |
| Durable Statement identity | `persist_statement_occurrence`, `(tenant_key, statement_key)` PK, `tests/postgres_atomic_ingestion.sh` | Item-level SQL transaction implemented; tests specify accepted/replayed/conflict behavior | Rust `StatementEvidenceRepository` adapter and API transaction mapping absent | Exact-head PostgreSQL test, then adapter must commit before mapping conflict to protocol error |
| Concurrent UPSERT semantics | real PostgreSQL identical and competing-content race fixtures | Tests require one canonical row plus `accepted/replayed` or `accepted/conflict` occurrence evidence | Hosted exact-head execution and hot-key wait measurement not yet evidence | Run exact-head quality; later benchmark lock wait/contention before partitioning |
| Request provenance | exact `ingestion_receipt` bytes plus `statement_ingestion_item` | Conflict/replay receipts are part of one durable transaction contract | Batch parser/span retention and one-receipt multi-item repository transaction absent | Implement validated POST-array repository path without per-item receipt duplication |
| Tenant isolation | composite tenant keys/FKs, forced RLS, `SECURITY INVOKER`, explicit session-tenant check, app-role negative tests | Application-equivalent non-superuser path implemented in PostgreSQL tests | Full service authn/z and all future resource paths unproven | Exact-head DB tests, then authenticated service integration tests |
| Persistence naming/3NF | multiword snake_case tables/columns; normalized receipt, statement, occurrence, void relation | Implemented baseline | Migration rollback/reapply, backup/restore, crash/retry recovery still absent | Add lifecycle/recovery fixtures before release-readiness claim |
| Canonical protocol | xAPI 2.0 canonical; 1.0.3/cmi5 explicit compatibility surface | Boundary implemented, parser absent | No executable version-specific parser/comparator or conformance suite | Implement lossless validation/comparison before HTTP endpoint |
| Document resources | planned current-state + immutable revision model | Defined only | CRUD, conditional requests, concurrency semantics absent | Separate document-resource implementation slice |
| Attachments | planned content-addressed immutable storage | Defined only | No blob storage, malicious-content non-execution, integrity or authorization proof | Dedicated attachment implementation/tests |
| Compatibility provenance | compatibility adapter/artifact boundary | Defined only | No transformation or reproducibility evidence | Implement only after canonical parser is proven |
| CI quality | exact-head checkout, stacked-PR trigger, Postgres service, Rust fmt/test/clippy/rustdoc, 100% line gate, transactional DB race test | Workflow contract implemented | Hosted runner/current-head results are external/live | Require current-head check completion; predecessor-head success is invalid evidence |
| Security/operability | forced RLS, immutable evidence, security-invoker transaction, public EXECUTE revoked | Partial | No HTTP authn/z, backup/restore, compose deployment, telemetry, recovery or load evidence | Add service/deployment/recovery slice before release-readiness claim |

## DDD/context map

**Core subdomain:** Learning Record Evidence. **Supporting:** Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence. **Generic:** PostgreSQL durability, object storage, telemetry, deployment, and recovery.

The Learning Record Evidence bounded context uses `StatementCandidate`, `StoredStatement`, `IngestionReceipt`, `StatementOccurrence`, and `VoidingRelation`. `StatementKernel` is the pure domain service. `persist_statement_occurrence` is the current durable transaction primitive; a Rust `StatementEvidenceRepository` will be the application-facing repository boundary and must delegate rather than duplicate the accepted/replayed/conflict algorithm. Canonical Statement plus its immutable ingest/voiding facts form the minimum consistency boundary; no tenant-wide lock is permitted. Potential domain events (`StatementAccepted`, `StatementReplayed`, `StatementConflictObserved`, `StatementVoided`) are emitted only after durable commit when a real consumer exists.

Learning Management Platform consumes released learning evidence for progression/completion policy. `learning-interoperability-contracts` owns reusable cross-product interoperability definitions. Compatibility adapters are an anti-corruption layer and never become a shared kernel of canonical learning truth. Cross-repository database reads are forbidden.

## Persistence and transaction invariants

Relational authoritative facts remain in 3NF. Named persistence objects use at least two semantic words and `snake_case`. Every tenant-owned reference carries `tenant_key`. Raw evidence is stored as bytes, not normalized JSON. The item-level UPSERT contract is executable: establish the tenant session; persist request evidence; serialize only the target `(tenant_key, statement_key)` identity through the primary-key conflict path; insert once or compare received version/comparison algorithm/digest/comparison bytes; persist `accepted`, `replayed`, or `conflict`; and return the outcome without throwing a domain-conflict exception that would roll back its receipt. Canonical Statement rows are immutable and ordinary application access does not need an UPDATE grant for replay resolution.

`persist_statement_occurrence` is deliberately item-level. A validated POST-array adapter must create one request receipt and associate multiple zero-based `statement_ingestion_item` rows to it; calling the single-item primitive independently for every array member would violate request provenance. Hot-key lock waits and contention must be measured before partitioning or read/write separation. No heuristic sharding or weighting is introduced without measured evidence.

## Active gap order

1. Obtain and repair exact-head PostgreSQL/Rust/review results for the stacked ingestion PR without weakening gates.
2. Merge bootstrap PR #1 only after its own live current-head required workflows and independent approval pass; then retarget/revalidate the ingestion PR against `develop`.
3. Implement the Rust `StatementEvidenceRepository` and validated-batch shared-receipt transaction around the durable SQL primitive; prove commit-before-protocol-conflict mapping.
4. Add migration rollback/reapply, backup/restore, crash/retry and lock-wait evidence.
5. Implement version-specific lossless xAPI parsing/comparison and executable xAPI 2.0 plus 1.0.3/cmi5 conformance traceability.
6. Add document resources, compatibility provenance, then attachments as separate bounded slices.
7. Add authenticated asynchronous service/deployment/recovery/load evidence before any production-readiness or standards-certification claim.
