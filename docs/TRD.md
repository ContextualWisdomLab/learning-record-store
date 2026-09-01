# Technical requirements: statement ingestion and immutable evidence

Status: Active implementation slice
Last reconciled: 2026-09-01

## Runtime boundary

The executable Rust core owns the deterministic decision between `accepted`, `replayed`, and `conflict` for one tenant-scoped Statement identity. `statement_validation` remains responsible for parsing the received protocol surface and producing version-aware comparison bytes. The identity kernel must not substitute generic JSON canonicalization for the applicable xAPI Statement Comparison Requirements.

The in-process `StatementKernel` is the executable domain reference for these invariants. It is not the durable production repository. PostgreSQL must implement the same contract atomically and is the source of durable persistence truth.

## DDD model

**Core subdomain:** Learning Record Evidence.

**Supporting subdomains:** Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence.

**Generic capabilities:** PostgreSQL durability, object storage, telemetry, deployment, and backup/restore.

**Bounded context:** Learning Record Evidence owns `StatementCandidate`, canonical `StoredStatement`, `IngestionReceipt`, `StatementOccurrence`, and `VoidingRelation`. Compatibility adapters are an anti-corruption layer between xAPI 1.0.3/cmi5 inputs and canonical service APIs; transformed artifacts never replace received evidence.

**Aggregate/invariants:** the canonical Statement identity is `(tenant_key, statement_key)`. At most one accepted `statement_record` exists for that identity. Every ingest attempt has immutable request evidence and an occurrence outcome. Equivalent replay never rewrites the canonical Statement. Protocol-version or comparison mismatch records a conflict without creating a second canonical row. Voiding links two existing tenant-local Statements without deletion.

**Domain service:** `StatementKernel` expresses the pure identity/replay decision. A production `StatementEvidenceRepository` will own the PostgreSQL transaction, row locking/UPSERT, durable receipt and occurrence writes, and conversion between database records and domain values.

**Domain events:** later service layers may emit `StatementAccepted`, `StatementReplayed`, `StatementConflictObserved`, and `StatementVoided` only after the durable transaction commits. This slice does not introduce an event bus before an actual consumer exists.

## Persistence and transaction contract

`migrations/0001_statement_evidence.sql` establishes 3NF tables with descriptive multiword `snake_case` names and composite tenant references. Raw request/Statement evidence is stored as `bytea` so whitespace, member order, scalar lexemes, and batch source evidence are not destroyed by a JSON storage rewrite. SHA-256 digests are fixed-width 32-byte integrity/index candidates, not semantic equality authorities.

For a single Statement item, the production transaction must:

1. establish tenant context on a non-superuser, non-`BYPASSRLS` database role;
2. persist or reference the immutable `ingestion_receipt` for the received request;
3. acquire the `(tenant_key, statement_key)` canonical identity atomically using the primary key conflict path and/or row lock;
4. when no row exists, insert exactly one `statement_record` with received version, comparison algorithm version, digest, comparison bytes, and exact Statement bytes;
5. when a row exists, require the same received xAPI version, comparison algorithm version, digest, and comparison bytes before returning `replayed`;
6. otherwise insert a `statement_ingestion_item` with `conflict` and no resolved canonical key, preserving request evidence while leaving the canonical Statement unchanged;
7. insert `accepted`/`replayed` occurrences with a composite foreign key to the canonical Statement;
8. commit evidence and decision together. Application-level conflict responses must not be implemented by throwing an exception that rolls back the audit receipt.

For POST arrays, validation occurs for the complete batch before canonical writes. One `ingestion_receipt` owns the exact request entity and every item uses its zero-based `request_statement_index`. Duplicate Statement IDs in the same batch follow the version-specific standard plus the repository's documented stronger fail-closed policy; the repository does not partially accept a pre-validation-invalid batch.

## Concurrency and contention

The `(tenant_key, statement_key)` primary key is the minimum write-serialization boundary. The implementation must not serialize an entire tenant or use a global ingestion lock. Concurrency tests must race identical and conflicting submissions against a real PostgreSQL instance and prove one canonical row, preserved occurrence evidence, and deterministic outcomes. Lock-wait and hot-key metrics must be measured before introducing read/write splitting or partitioning; no heuristic sharding/weighting is added without evidence.

## Tenant security

Every tenant-owned relation includes `tenant_key` in its primary/foreign-key boundary. RLS is enabled and forced by the migration. An absent `app.tenant_key` produces no row match rather than a permissive default. Production connections must use a role without superuser or `BYPASSRLS`; migration/owner credentials are not application credentials. Cross-tenant negative tests must exercise direct select, insert, update, foreign-key reference, replay, and voiding paths.

## Version and compatibility boundary

xAPI 2.0 is canonical. xAPI 1.0.3 exists as an explicit compatibility surface for cmi5 Quartz. `StatementCandidate` carries the received version, and the kernel rejects a replay whose version changes even if its comparison bytes happen to match. Compatibility transformations belong to `compatibility_adapter` and retain source/target version, converter version, output digest, validation status, provenance reference, and immutable artifact bytes outside canonical Statement identity.

## Verification

The branch must run, on the exact PR head, formatting, compilation, Clippy with warnings denied, unit/integration tests, public rustdoc, and coverage for owned production surfaces. PostgreSQL acceptance additionally requires migration apply/reapply tests, real transaction races, RLS tests using an application-equivalent role, and recovery evidence. Standards conformance is a separate executable gate and must cite version-specific requirement identifiers in `docs/doctoring/STANDARD_TRACEABILITY.md` rather than infer conformance from unit tests.

No runtime, persistence, latency, conformance, security-certification, or release-readiness claim is valid while the relevant exact-head GitHub check is absent, queued, skipped, predecessor-head, or failing.
