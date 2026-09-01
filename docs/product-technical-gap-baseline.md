# Product and technical gap baseline

Last reconciled: 2026-09-01

This ledger records the current commercialization gap for the ContextualWisdomLab Learning Record Store from repository guidance, architecture/data-model decisions, standards traceability, review findings, and exact-head GitHub evidence. It does not claim runtime implementation or standards conformance that does not yet exist.

## Product responsibility

The Learning Record Store is the authoritative persistence boundary for xAPI statements, xAPI document resources, attachments, and their integrity/provenance metadata. It does not own enrollment, completion policy, authored content, psychometric responses, or billing state.

## Current exact-head baseline

| Area | Evidence | Status | Commercialization gap | Next verification |
| --- | --- | --- | --- | --- |
| Authority boundary | ADR 0001, README, ARCHITECTURE | Defined | Runtime modules do not yet exist | Merge bootstrap, then implement protocol/persistence slices behind the documented boundary |
| Canonical protocol | xAPI 2.0 canonical; cmi5 Quartz/xAPI 1.0.3 explicit compatibility surface | Defined | No executable protocol negotiation or conformance suite | Implement independent canonical and compatibility conformance paths |
| Statement identity | `(tenant_id, statement_id)` canonical identity; version-aware comparison; immutable request receipts | Defined | No transactional persistence implementation yet | Prove atomic exact-retry reuse and conflicting-replay rejection under concurrency |
| Request provenance | `ingestion_receipt` + `statement_ingestion_item` | Defined | No storage migration or replay implementation | Preserve every request occurrence, including idempotent retries and rejected conflict evidence |
| Tenant isolation | Composite tenant references and fail-closed RLS/equivalent policy | Defined | No deployed DB constraints or adversarial tenant tests | Implement schema/migrations and cross-tenant negative tests at the database boundary |
| Document resources | `document_store` with current state plus immutable revision evidence | Defined | State/Agent Profile/Activity Profile CRUD and conditional semantics absent | Implement version-specific document-resource tests separately from Statement immutability |
| Attachments | `attachment_blob` content-addressed storage + `statement_attachment` relation | Defined | No blob persistence, integrity, malicious-content non-execution, or dedup evidence | Implement immutable bytes/digest/media type/length/locator checks and authorization tests |
| Compatibility provenance | `compatibility_adapter`, `compatibility_transform`, `compatibility_artifact` | Defined | Transformation implementation and reproducibility evidence absent | Prove deterministic conversion, source preservation, target version, converter version, output digest, validation and provenance reference |
| Standards traceability | IEEE 9274.1.1-2023, ISO/IEC/IEEE 39274-1-1:2025, ADL xAPI 1.0.3, cmi5 Quartz | Documented | No exact-head executable conformance evidence yet | Attach requirement-level test paths and exact-head receipts as implementation lands |
| CI/security | Exact-head bootstrap validation, Security Scan, SAST | Partial | Current-head runs are queued and therefore not merge evidence | Require all protected exact-head checks before merge |
| Test/documentation quality | Bootstrap validation guards machine-readable architecture contract | Partial | Runtime statement/branch/docstring/edge-case coverage does not exist because runtime is not implemented | Require 100% coverage for each production slice introduced |

## DDD/context map

The core bounded context is **Learning Record Evidence**. Ubiquitous language includes `statement_record`, `ingestion_receipt`, `statement_ingestion_item`, `document_revision`, `attachment_blob`, `voiding_relation`, and `compatibility_artifact`.

- `statement_record` is the canonical immutable Statement entity scoped to a tenant.
- `ingestion_receipt` is immutable request evidence.
- `statement_ingestion_item` associates each request occurrence and zero-based request index with the resolved canonical Statement identity or rejection result.
- document resources are mutable current-state aggregates with immutable audit revisions; they must not inherit Statement immutability semantics accidentally.
- compatibility artifacts are provenance records, never a second source of canonical learning evidence.

Learning Management Platform is an upstream/downstream consumer for progression and completion policy; `learning-interoperability-contracts` is the generic contract authority. Cross-repository database access is forbidden; integration occurs through released contracts/APIs/events.

## Persistence invariants

Relational authoritative facts remain in third normal form. Database object names use at least two semantic words and snake_case by default. Every tenant-owned relation includes tenant identity in its key/reference boundary. Item-level ingestion and UPSERT behavior must be explicit: an exact retry resolves to the existing canonical Statement while creating new immutable request-occurrence evidence; a conflicting replay fails closed without overwriting or inserting a second canonical identity.

Hot-partition and lock behavior must be measured when persistence exists. Concurrency tests must establish that duplicate-ID races cannot create two accepted canonical Statements. Read/write separation is a future operational option only when measured lock/load evidence justifies it.

## Active gap order

1. Merge bootstrap PR #1 only after current-head quality/security/SAST checks complete successfully.
2. Implement the minimal Rust-first persistence/protocol core needed to enforce statement identity, tenant isolation, request provenance and version-aware replay comparison.
3. Add executable xAPI 2.0 Statement and document-resource conformance evidence.
4. Add the explicit xAPI 1.0.3/cmi5 compatibility adapter with deterministic provenance artifacts and separate conformance fixtures.
5. Add content-addressed attachment storage/integrity evidence and hostile-content tests.
6. Add concurrency/load/operability evidence, including realistic PostgreSQL contention and service-level latency before any production-readiness claim.
