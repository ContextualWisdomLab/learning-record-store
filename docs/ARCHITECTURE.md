# Architecture

The Learning Record Store is the authoritative persistence service for xAPI learning records and xAPI document resources. It does not own enrollment, course completion policy, authored content, psychometric response data, or downstream product workflow truth.

## Initial modules

- `xapi_protocol`: request and response contracts.
- `statement_validation`: version-aware validation and profile checks.
- `compatibility_adapter`: explicit xAPI 1.0.3/cmi5 compatibility transformations and the associated `compatibility_transform` / `compatibility_artifact` provenance records. This module may derive compatibility views but never becomes canonical learning-evidence authority or overwrites the received source surface.
- `ingestion_evidence`: immutable request receipts and per-Statement request-occurrence provenance, including idempotent retries, canonical conflicts, and request-level `batch_rejected` evidence.
- `statement_store`: one canonical immutable Statement identity per tenant, voiding relations, query indexes, and controlled durable transaction primitives. `persist_statement_occurrence` handles one item; proposed `persist_statement_batch` handles one validated POST array with a shared receipt and all-or-none canonical mutation. The future Rust `StatementEvidenceRepository` is the application-facing adapter and must delegate persistence decisions rather than duplicate them.
- `document_store`: State, Agent Profile, and Activity Profile resources.
- `attachment_store`: content-addressed attachment persistence.
- `tenant_authorization`: authenticated principal-to-tenant authorization boundary. Database authorization derives from administrator-controlled `tenant_database_principal` mappings keyed by PostgreSQL `session_user`; caller-selected GUCs are not authorization inputs.
- `conformance_runner`: executable standards-conformance evidence.

## Version boundary

xAPI 2.0 is the canonical target. xAPI 1.0.3 support exists only as an explicit compatibility surface required by cmi5 Quartz. Historical statements are retained in their received version and are never silently rewritten. Replay comparison follows the Statement Comparison Requirements of the received surface rather than raw request-body equality. Compatibility transformations are owned by `compatibility_adapter`; their outputs remain provenance artifacts linked to received evidence and are not promoted into a second canonical Statement identity.

## Storage boundary

Relational indexes are normalized and tenant-scoped. Original statement JSON, request receipts, per-Statement ingestion occurrences, and attachments remain immutable evidence. A canonical `statement_record` is not rewritten when an idempotent retry arrives; the new request occurrence resolves to that existing canonical identity through a separate tenant-scoped association.

Controlled single-item and batch writers share the same transaction-scoped per-Statement serialization protocol. A single-item write locks its `(tenant_key, statement_key)` identity before comparison/mutation. A validated batch locks its distinct identities in deterministic order, creates one `ingestion_receipt`, re-reads canonical state, and either applies every conflict-free canonical insertion or none when any stored conflict exists. The primary key, forced RLS, immutable digest constraints and occurrence consistency constraints remain the final relational invariants. Tenant-wide/table-wide locks are not part of the architecture; advisory-lock hash collisions may conservatively serialize unrelated identities and therefore require lock-wait telemetry before release-readiness claims.

Forced RLS is bound to the authenticated database principal rather than a caller-writable tenant setting. `authorized_tenant_key()` maps the original connection `session_user` to a tenant. The controlled `SECURITY DEFINER` write primitives are owned by `lrs_evidence_writer`, a `NOLOGIN`, non-superuser, non-`BYPASSRLS` role that is not an evidence-table owner; forced RLS therefore still applies to writes while direct evidence-table mutation is excluded from the ordinary data-plane privilege set. ADR 0002 remains Proposed while this implementation is unmerged.

A validated POST-array path reuses one request receipt across all item occurrences. Request-level stored conflict preserves every submitted index while creating no canonical Statement rows; `conflict` identifies items that disagree with stored canonical evidence and `batch_rejected` identifies non-conflicting siblings rejected only because the request is atomic. Malformed shape, duplicate identity and request-context failures still need the Rust repository/adapter to retain request-level evidence before the SQL batch primitive is entered. Object storage may hold large immutable payloads while PostgreSQL holds identities, indexes, relationships, provenance, and integrity metadata.

## Context map

Learning Record Evidence is the core bounded context. Protocol Compatibility, Document Resources, Attachment Evidence, Tenant Authorization, and Conformance Evidence are supporting contexts. PostgreSQL durability, object storage, telemetry, deployment, and recovery are generic capabilities. `StatementKernel` is the pure domain service; `persist_statement_occurrence` and proposed `persist_statement_batch` are internal persistence primitives behind the future Rust `StatementEvidenceRepository`. One Statement identity plus request receipt/occurrence facts form the minimum consistency boundary.

Tenant Authorization is an anti-corruption boundary between externally authenticated identity and tenant-scoped persistence. Its `tenant_database_principal` mapping is control-plane state, not customer-authored learning evidence. Shared or multiplexed database credentials are outside the current high-assurance boundary until an equally unforgeable authenticated binding is implemented.

Learning Management Platform consumes released LRS evidence and owns progression/completion policy. `learning-interoperability-contracts` owns reusable interoperability definitions. Integrations use released contracts rather than cross-service application-table reads.

## Decision status and next architecture slice

ADR 0001 is Accepted with recorded repository-owner approval and defines the product authority boundary. ADR 0002 and ADR 0003 are Proposed because their database-principal and atomic-batch implementations are still on the open writer stack; source presence is not acceptance evidence. The next application boundary is the Rust `StatementEvidenceRepository`: it must hide SQL-array/internal function shapes, preserve duplicate/context/pre-persistence request failures, commit durable conflicts before protocol error mapping, and expose no cross-service SQL surface. Migration lifecycle, backup/restore, crash/retry, overlapping item-vs-batch concurrency and lock-wait evidence remain required before an immutable release contract can be claimed.
