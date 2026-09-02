# Technical requirements: statement ingestion and immutable evidence

Status: Active implementation slice
Last reconciled: 2026-09-02

## Runtime boundary

The executable Rust core owns the deterministic decision between `accepted`, `replayed`, `conflict`, and request-level `batch_rejected` evidence for tenant-scoped Statement identities. `statement_validation` remains responsible for parsing the received protocol surface and producing version-aware comparison bytes. The identity kernel must not substitute generic JSON canonicalization for the applicable xAPI Statement Comparison Requirements.

`StatementKernel` is the in-process domain reference. Its `ingest_batch` path retains one exact request receipt, validates tenant/version context and duplicate IDs before stored-evidence comparison, records every submitted index when the batch is rejected, and performs no canonical writes until the whole preflight succeeds. PostgreSQL implements the corresponding single-item durable decision through `persist_statement_occurrence` and, in migration 0004, the proposed validated POST-array transaction through `persist_statement_batch`. The latter writes one request receipt for the complete array and either persists all conflict-free canonical changes or none when a stored conflict exists. A Rust `StatementEvidenceRepository` and network/application adapter remain unfinished.

## DDD model

**Core subdomain:** Learning Record Evidence.

**Supporting subdomains:** Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence.

**Generic capabilities:** PostgreSQL durability, object storage, telemetry, deployment, and backup/restore.

**Bounded context:** Learning Record Evidence owns `StatementCandidate`, canonical `StoredStatement`, `IngestionReceipt`, `StatementOccurrence`, and `VoidingRelation`. Compatibility adapters are an anti-corruption layer between xAPI 1.0.3/cmi5 inputs and canonical service APIs; transformed artifacts never replace received evidence. Tenant Authorization owns the database-principal-to-tenant binding and prevents caller-selected data-plane context from becoming an authorization source.

**Aggregate/invariants:** canonical Statement identity is `(tenant_key, statement_key)`. At most one accepted `statement_record` exists for that identity. Every persistence attempt that enters the durable primitive is attributable to immutable request evidence. A rejected validated batch preserves one occurrence for every submitted index while creating no canonical Statement writes; siblings that were not themselves canonical conflicts use `batch_rejected`. Equivalent replay never rewrites the canonical Statement. Protocol-version or comparison mismatch records conflict evidence without creating a second canonical row. Voiding links two existing tenant-local Statements without deletion.

**Domain service and repositories:** `StatementKernel` expresses pure single-item and atomic-batch identity/replay decisions. `persist_statement_occurrence` is the controlled durable item primitive. Proposed `persist_statement_batch` is the controlled durable shared-receipt batch primitive; it is not a public application API. A Rust `StatementEvidenceRepository` will own typed invocation, pre-persistence failure receipts, transaction/error mapping, provisioning, cancellation and observability without duplicating the identity decision algorithm.

**Domain events:** later service layers may emit `StatementAccepted`, `StatementReplayed`, `StatementConflictObserved`, and `StatementVoided` only after durable commit. `batch_rejected` is persisted request evidence, not an event implying a canonical Statement change. This slice does not introduce an event bus before an actual consumer exists.

## Persistence and transaction contract

`migrations/0001_statement_evidence.sql` establishes 3NF tables with descriptive multiword `snake_case` names and composite tenant references. Raw request/Statement evidence is stored as `bytea` so whitespace, member order, scalar lexemes, and batch source evidence are not destroyed by a JSON storage rewrite. SHA-256 digests are fixed-width 32-byte integrity/index candidates, not semantic equality authorities.

Migration 0002 adds `tenant_database_principal`, replaces caller-selected `app.tenant_key` authorization with a mapping keyed by PostgreSQL `session_user`, and changes the ingestion primitive to a fixed-search-path `SECURITY DEFINER` function owned by `lrs_evidence_writer`. That owner is `NOLOGIN`, `NOSUPERUSER`, `NOBYPASSRLS`, is not an evidence-table owner, and receives only the read/insert/sequence privileges necessary for the controlled transaction. Forced RLS continues to apply and uses the original connection principal through `session_user`. Data-plane tenant principals are not granted direct immutable-evidence mutation privileges. ADR 0002 remains Proposed until exact-head integration evidence and ordinary protected-branch acceptance exist.

Migration 0003 extends `statement_ingestion_item.comparison_outcome` with `batch_rejected`. The resolution invariant requires `accepted` and `replayed` items to resolve to their submitted canonical key, while `conflict` and `batch_rejected` remain unresolved.

Migration 0004 proposes `persist_statement_batch`. It requires a fully materialized one-dimensional, one-based, equal-cardinality set of Statement keys, comparison-version labels, comparison bytes and raw Statement bytes. It rejects blank/empty fields and duplicate Statement identities before receipt creation, acquires distinct per-Statement transaction advisory locks in deterministic key order, inserts one immutable request receipt, re-reads canonical state under those locks, and then writes either all conflict-free canonical additions or no canonical additions if any item conflicts. Every item still receives an indexed durable occurrence on the shared receipt. ADR 0003 records the alternatives, failure scenes and verification obligations.

For a single Statement item, `persist_statement_occurrence` must:

1. resolve the authorized tenant from the administrator-controlled mapping for the authenticated PostgreSQL `session_user` and reject an unmapped or mismatched requested tenant;
2. validate durable field bounds before mutation;
3. acquire the same transaction-scoped per-Statement identity lock used by the batch primitive so overlapping controlled writers cannot invalidate each other's preflight;
4. derive `request_content_hash` from retained raw request bytes and `content_hash` from retained comparison bytes inside PostgreSQL so a caller cannot persist inconsistent immutable digests;
5. persist the immutable `ingestion_receipt` before resolving canonical identity;
6. insert exactly one `statement_record` when absent or compare the existing immutable version/comparator evidence when present;
7. return `replayed` only for the same received xAPI version, comparison algorithm version, derived digest and comparison bytes;
8. otherwise insert a `statement_ingestion_item` with `conflict` and no resolved canonical key, preserving request evidence while leaving the canonical Statement unchanged;
9. insert `accepted`/`replayed` occurrences with a composite foreign key to the canonical Statement;
10. return the receipt and outcome without raising a domain-conflict exception. The application commits this transaction first and only then maps `conflict` to the protocol error response so audit evidence is not rolled back.

For POST arrays, version-specific parsing and validation occur for the complete batch before canonical writes. One `ingestion_receipt` owns the exact request entity and every item uses its zero-based `request_statement_index`. Tenant/version mismatch, malformed request shape and duplicate Statement IDs are request-level failures evaluated before stored-evidence conflict comparison; duplicate identity therefore cannot be masked by an earlier canonical conflict. `StatementKernel::ingest_batch` records every submitted item for context, duplicate, or conflict rejection in memory. The current migration 0004 primitive covers a validated unique-identity batch and must never be replaced by independent calls to the single-item function. Immutable receipts for failures rejected before migration 0004 is entered remain a Rust repository/adapter requirement.

## Concurrency and contention

The minimum serialization scope is one `(tenant_key, statement_key)` identity, not a tenant, table, or global writer lock. Controlled item and batch functions use transaction-scoped PostgreSQL advisory locks derived from tenant and Statement identity; a batch obtains distinct identities in lexical order before canonical preflight. The primary key and immutable digest constraints remain the final relational invariants. Hash collisions may conservatively serialize unrelated identities but cannot admit a conflicting canonical row.

`tests/postgres_atomic_ingestion.sh` races identical submissions and competing content against a real PostgreSQL service and requires exactly one canonical row plus two preserved request occurrences, with `accepted`/`replayed` or `accepted`/`conflict` outcomes as appropriate. `tests/postgres_batch_transaction.sh` specifies one-receipt acceptance/replay, conflict-driven whole-batch rejection, canonical non-overwrite and duplicate fail-closed behavior. An overlapping item-vs-batch concurrency fixture and measured lock-wait/hot-key latency are still required before read/write splitting or partitioning; no heuristic sharding or weighting is added without evidence.

## Tenant security

Every tenant-owned relation includes `tenant_key` in its primary/foreign-key boundary, and RLS is enabled and forced. Authorization is not derived from a freely writable custom GUC. `authorized_tenant_key()` resolves only the administrator-controlled mapping for PostgreSQL `session_user`; an unmapped principal receives no tenant match. Controlled persistence functions are `SECURITY DEFINER` only to centralize immutable writes behind the constrained `lrs_evidence_writer` owner, and their fixed search paths prevent caller-controlled object resolution. They recheck the requested tenant against the authenticated principal mapping before persistence.

`tests/postgres_principal_boundary.sh` proves that setting `app.tenant_key` cannot retarget a tenant principal, direct evidence-table INSERT is unavailable, own-tenant function ingestion succeeds, cross-tenant ingestion fails, cross-tenant reads remain hidden, and the writer owner is non-superuser/non-`BYPASSRLS`. Migration and owner credentials are not application credentials. The initial high-assurance deployment contract maps one database login to one tenant; future pooled/multiplexed credentials require another unforgeable externally authenticated binding and must not regress to a caller-selected GUC.

This decision follows PostgreSQL's documented distinction between `session_user` and `current_user` under `SECURITY DEFINER`, PostgreSQL row-security semantics, and OWASP least-privilege/deny-by-default authorization guidance. ADR 0002 records the rationale and references.

## Version and compatibility boundary

xAPI 2.0 is canonical. xAPI 1.0.3 exists as an explicit compatibility surface for cmi5 Quartz. `StatementCandidate` carries the received version, and both the kernel and SQL transaction reject a replay whose version or comparison-algorithm version changes even if other evidence happens to match. Compatibility transformations belong to `compatibility_adapter` and retain source/target version, converter version, output digest, validation status, provenance reference, and immutable artifact bytes outside canonical Statement identity.

## Verification

The branch must run, on the exact PR head, formatting, compilation, Clippy with warnings denied, unit/integration tests, public rustdoc, and 100% line coverage for owned production surfaces. PostgreSQL acceptance additionally requires real transaction-race, authenticated database-principal authorization, batch-outcome and shared-receipt batch tests in exact-head CI. Migration rollback/reapply, backup/restore, crash/retry recovery, overlapping item-vs-batch concurrency, lock-wait measurement, typed repository integration, and version-specific standards conformance remain separate release gates. Standards conformance must cite requirement identifiers in `docs/doctoring/STANDARD_TRACEABILITY.md` rather than infer conformance from unit tests.

No runtime, persistence, latency, conformance, security-certification, or release-readiness claim is valid while the relevant exact-head GitHub check is absent, queued, skipped, predecessor-head, or failing.
