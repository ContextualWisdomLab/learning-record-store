# Technical requirements: statement ingestion and immutable evidence

Status: Active implementation slice
Last reconciled: 2026-09-01

## Runtime boundary

The executable Rust core owns the deterministic decision between `accepted`, `replayed`, and `conflict` for one tenant-scoped Statement identity. `statement_validation` remains responsible for parsing the received protocol surface and producing version-aware comparison bytes. The identity kernel must not substitute generic JSON canonicalization for the applicable xAPI Statement Comparison Requirements.

The in-process `StatementKernel` is the executable domain reference for these invariants. PostgreSQL now implements the same first-write/replay/conflict decision through the security-invoker `persist_statement_occurrence` transaction function; the network/application adapter remains unfinished and must commit the returned audit decision before mapping a conflict to an API error.

## DDD model

**Core subdomain:** Learning Record Evidence.

**Supporting subdomains:** Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence.

**Generic capabilities:** PostgreSQL durability, object storage, telemetry, deployment, and backup/restore.

**Bounded context:** Learning Record Evidence owns `StatementCandidate`, canonical `StoredStatement`, `IngestionReceipt`, `StatementOccurrence`, and `VoidingRelation`. Compatibility adapters are an anti-corruption layer between xAPI 1.0.3/cmi5 inputs and canonical service APIs; transformed artifacts never replace received evidence.

**Aggregate/invariants:** the canonical Statement identity is `(tenant_key, statement_key)`. At most one accepted `statement_record` exists for that identity. Every ingest attempt has immutable request evidence and an occurrence outcome. Equivalent replay never rewrites the canonical Statement. Protocol-version or comparison mismatch records a conflict without creating a second canonical row. Voiding links two existing tenant-local Statements without deletion.

**Domain service:** `StatementKernel` expresses the pure identity/replay decision. `persist_statement_occurrence` is the first durable repository transaction primitive: it records the receipt, wins or observes the canonical primary-key conflict, compares immutable version/comparator evidence, and records the occurrence in one transaction. A Rust `StatementEvidenceRepository` adapter will call this primitive and convert committed database outcomes into domain/API values without duplicating the decision algorithm.

**Domain events:** later service layers may emit `StatementAccepted`, `StatementReplayed`, `StatementConflictObserved`, and `StatementVoided` only after the durable transaction commits. This slice does not introduce an event bus before an actual consumer exists.

## Persistence and transaction contract

`migrations/0001_statement_evidence.sql` establishes 3NF tables with descriptive multiword `snake_case` names and composite tenant references. Raw request/Statement evidence is stored as `bytea` so whitespace, member order, scalar lexemes, and batch source evidence are not destroyed by a JSON storage rewrite. SHA-256 digests are fixed-width 32-byte integrity/index candidates, not semantic equality authorities.

For a single Statement item, `persist_statement_occurrence` must:

1. require the supplied tenant to equal the session `app.tenant_key`; production uses a non-superuser, non-`BYPASSRLS` role;
2. persist the immutable `ingestion_receipt` for the received request before resolving canonical identity;
3. serialize only `(tenant_key, statement_key)` through `INSERT ... ON CONFLICT DO NOTHING` on the primary key; immutable canonical rows need no UPDATE grant or tenant-wide lock;
4. when no row exists, insert exactly one `statement_record` with received version, comparison algorithm version, digest, comparison bytes, and exact Statement bytes;
5. when a row exists, require the same received xAPI version, comparison algorithm version, digest, and comparison bytes before returning `replayed`;
6. otherwise insert a `statement_ingestion_item` with `conflict` and no resolved canonical key, preserving request evidence while leaving the canonical Statement unchanged;
7. insert `accepted`/`replayed` occurrences with a composite foreign key to the canonical Statement;
8. return the receipt and outcome without raising a domain-conflict exception. The application commits this transaction first and only then maps `conflict` to the protocol error response, so audit evidence is not rolled back.

For POST arrays, validation occurs for the complete batch before canonical writes. One `ingestion_receipt` owns the exact request entity and every item uses its zero-based `request_statement_index`. Duplicate Statement IDs in the same batch follow the version-specific standard plus the repository's documented stronger fail-closed policy; the repository does not partially accept a pre-validation-invalid batch. The current SQL primitive is intentionally item-level; the future Rust repository must reuse one request receipt for a validated batch rather than calling the single-item primitive once per array element.

## Concurrency and contention

The `(tenant_key, statement_key)` primary key is the minimum write-serialization boundary. PostgreSQL's unique-index conflict path makes concurrent first writers wait only on that identity; canonical Statement rows are immutable and the application role has no UPDATE grant, so replay comparison does not require `SELECT ... FOR UPDATE`. `tests/postgres_atomic_ingestion.sh` races identical submissions and competing content against a real PostgreSQL service and requires exactly one canonical row plus two preserved request occurrences, with `accepted`/`replayed` or `accepted`/`conflict` outcomes as appropriate. Lock-wait and hot-key latency still need measured release evidence before introducing read/write splitting or partitioning; no heuristic sharding/weighting is added without evidence.

## Tenant security

Every tenant-owned relation includes `tenant_key` in its primary/foreign-key boundary. RLS is enabled and forced by the migration. An absent `app.tenant_key` produces no row match rather than a permissive default. `persist_statement_occurrence` is `SECURITY INVOKER`, explicitly checks tenant context, and has public EXECUTE revoked; deployment must grant EXECUTE only to the application role. Production connections must use a role without superuser or `BYPASSRLS`; migration/owner credentials are not application credentials. Cross-tenant negative tests exercise direct writes and the transactional ingest primitive; further query/document/attachment paths must preserve the same invariant.

## Version and compatibility boundary

xAPI 2.0 is canonical. xAPI 1.0.3 exists as an explicit compatibility surface for cmi5 Quartz. `StatementCandidate` carries the received version, and both the kernel and SQL transaction reject a replay whose version or comparison-algorithm version changes even if other evidence happens to match. Compatibility transformations belong to `compatibility_adapter` and retain source/target version, converter version, output digest, validation status, provenance reference, and immutable artifact bytes outside canonical Statement identity.

## Verification

The branch must run, on the exact PR head, formatting, compilation, Clippy with warnings denied, unit/integration tests, public rustdoc, and coverage for owned production surfaces. PostgreSQL acceptance additionally requires the real transaction-race and application-role RLS tests in exact-head CI. Migration rollback/reapply, backup/restore, crash/retry recovery, lock-wait measurement, and version-specific standards conformance remain separate release gates. Standards conformance must cite requirement identifiers in `docs/doctoring/STANDARD_TRACEABILITY.md` rather than infer conformance from unit tests.

No runtime, persistence, latency, conformance, security-certification, or release-readiness claim is valid while the relevant exact-head GitHub check is absent, queued, skipped, predecessor-head, or failing.
