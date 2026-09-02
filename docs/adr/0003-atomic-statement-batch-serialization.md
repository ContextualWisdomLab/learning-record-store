# ADR 0003: Serialize atomic statement batches by Statement identity

- Status: Proposed
- Date: 2026-09-02
- Scope: durable POST-array Statement ingestion

## Problem

The in-memory `StatementKernel` can reject an entire validated POST array while preserving per-item outcomes, but the first PostgreSQL primitive persists one request receipt per item. Calling that primitive once per array member breaks the request provenance contract and cannot guarantee that a sibling remains non-canonical when another item conflicts with stored evidence. A batch transaction must preserve one immutable request receipt, one occurrence per submitted index, and all-or-none canonical mutation.

The batch path must also remain correct when another controlled writer targets the same `(tenant_key, statement_key)` concurrently. A preflight read by itself is insufficient because an absent row can become present before the later insert.

## Constraints

- canonical Statement identity remains `(tenant_key, statement_key)`;
- no tenant-wide or table-wide write lock is permitted;
- conflicts must commit receipt and occurrence evidence rather than being converted into a transaction error that erases provenance;
- duplicate Statement identities are rejected before durable batch mutation because duplicate/request-context validation belongs to the validated adapter boundary;
- all controlled single-item and batch writes must use the same serialization protocol;
- ordinary tenant principals continue to lack direct immutable-evidence DML privileges;
- exact-head PostgreSQL tests, review, and ordinary merge gates remain required before this proposal becomes accepted implementation evidence.

## Alternatives considered

### Tenant-wide or table-wide locks

Rejected. They are easy to reason about but turn unrelated Statement identities into one contention domain, violate the minimal-aggregate boundary, and would make hot tenants block unrelated evidence.

### Preflight reads plus primary-key `ON CONFLICT`

Rejected for the atomic batch path. It preserves single-item uniqueness but cannot prevent a concurrent writer from changing an initially absent identity between batch preflight and canonical insertion, which can make a partially evaluated batch inconsistent with its stored occurrence outcomes.

### SERIALIZABLE isolation as the only contract

Rejected as the sole mechanism. The function cannot safely assume every caller established the required transaction isolation, and retry behavior would still need an application-level contract before protocol errors can be returned.

### Per-Statement transaction advisory locks

Selected for the current bounded persistence primitive. Controlled writers take transaction-scoped advisory locks derived from the tenant and Statement identity. Batch functions acquire distinct identities in lexical order before preflight; the single-item function takes the same identity lock. Hash collisions can cause conservative extra serialization but cannot admit a conflicting canonical write. The primary key and immutable digest constraints remain the final relational invariants rather than relying on the lock as stored truth.

## Decision

Migration 0004 introduces `persist_statement_batch`, a fixed-search-path `SECURITY DEFINER` function owned by `lrs_evidence_writer`. The function accepts a fully materialized, validated, one-dimensional batch. It verifies tenant authorization and evidence shape, rejects duplicate Statement identities before receipt creation, acquires per-identity transaction advisory locks in deterministic order, creates exactly one `ingestion_receipt`, and re-reads canonical Statement state under those locks.

If any item conflicts, no candidate becomes canonical. Conflicting items persist as `conflict`; all non-conflicting siblings persist as `batch_rejected`; every occurrence shares the same receipt. If no item conflicts, missing Statements are inserted and replay-equivalent Statements remain canonical; all occurrences share the same receipt. Migration 0002's single-item `persist_statement_occurrence` takes the same identity lock so the two controlled paths cannot race around one another.

This function is a persistence primitive, not the HTTP adapter. The future Rust `StatementEvidenceRepository` owns type-safe invocation, transaction/error mapping, cancellation, provisioning and observability. Network/streaming adapters must finish bounded request validation before calling the batch primitive.

## User, operator, and failure scenes

A learner device submits two valid Statements in one POST array. The LRS records one request receipt and two indexed occurrences; both become canonical only if the complete batch is conflict-free.

A retry contains one previously accepted Statement with different comparison bytes and one new sibling. The LRS retains one rejected request receipt, records the conflicting item as `conflict` and the sibling as `batch_rejected`, and leaves the sibling absent from canonical Statement truth.

Two workers concurrently target an overlapping Statement identity. They serialize only on that identity, not the tenant as a whole; after the lock is acquired, the later worker observes the committed canonical state and derives replay/conflict behavior from that state.

If a caller supplies duplicate Statement identities, malformed arrays, blank identities, empty evidence bytes, or an unauthorized tenant, the function fails closed before canonical mutation. Duplicate/request-shape evidence retention remains the adapter's responsibility until the repository API persists validated request receipts for those pre-persistence failures.

## Risks and follow-up

- Advisory-lock hash collisions may serialize unrelated identities; lock-wait telemetry and a realistic hot-key benchmark are required before release readiness.
- The current SQL array interface is an internal persistence contract, not a public HTTP/API schema; the Rust repository must hide it behind typed domain objects.
- Crash/retry, migration rollback/reapply, backup/restore and process-cancellation evidence remain open.
- PostgreSQL exact-head execution must confirm the function, forced RLS behavior, constraints and race tests before this ADR can move from Proposed.
