# Standards traceability

This file is the bootstrap traceability ledger for the Learning Record Store. It records standards ownership and the evidence that must exist before this repository makes an implementation or conformance claim. Documentation alone is not conformance evidence.

Primary-source status was rechecked on 2026-09-02. IEEE 9274.1.1-2023 remains an active xAPI base standard, and ISO/IEC/IEEE 39274-1-1:2025 remains the published international adoption. cmi5 Quartz remains a separate xAPI 1.0.3 compatibility surface; it is not evidence that an xAPI 2.0 implementation conforms to cmi5.

## Normative surface map

| Surface | Normative authority | Repository ownership | Required executable evidence before `Implemented` | Current maturity |
| --- | --- | --- | --- | --- |
| xAPI statement and LRS REST behavior | IEEE 9274.1.1-2023; ISO/IEC/IEEE 39274-1-1:2025 | `xapi_protocol`, `statement_validation`, `ingestion_evidence`, `statement_store` | Version negotiation, statement validation, version-aware Statement comparison, same-content retry with independent receipt provenance, conflicting-content rejection, duplicate-ID batch handling, voiding, query, attachment, authorization and tenant-isolation tests against the exact implemented version | Not implemented |
| State, Agent Profile and Activity Profile resources | IEEE 9274.1.1-2023 / ISO/IEC/IEEE 39274-1-1:2025 document-resource requirements | `document_store` | Create/update/read/delete, conditional-request, replay/revision, authorization and tenant-isolation tests that distinguish mutable current resource state from immutable audit evidence | Not implemented |
| cmi5 Quartz compatibility | *cmi5 Specification Profile for xAPI*, Quartz, 1st ed.; especially §§4, 6-14 | `compatibility_adapter`; canonical storage remains version-aware xAPI evidence | Independent Quartz launch/session, Statement API, State API, statement data-model, State, Agent Profile, Activity Profile and package fixtures using received xAPI 1.0.3 semantics | Not implemented |
| xAPI 1.0.3 compatibility transformation | ADL xAPI 1.0.3 as referenced normatively by cmi5 Quartz §2 | `compatibility_adapter` owns transformation/provenance artifacts; they are non-canonical | Source-version preservation, deterministic conversion, converter-version provenance, output digest, validation receipt, replay and conflict tests; source evidence must never be overwritten | Not implemented |
| Attachment integrity | Applicable xAPI attachment requirements in the selected xAPI version | `attachment_store` plus statement relation | Digest, media type, byte length, immutable object identity, duplicate-content handling, storage-locator integrity, authorization and malicious-content non-execution tests | Not implemented |

## Evidence rules

Every implementation PR that changes a normative surface must update this ledger with exact test paths and an exact-head CI receipt. A passing generic unit test, skipped required step, predecessor-head result, model-only review, or documentation assertion is not standards evidence. xAPI 2.0 and xAPI 1.0.3/cmi5 compatibility are tested independently; a conversion artifact records source version, target version, converter version, output hash, validation result and provenance identity.

Statement replay equality follows the Statement Comparison Requirements of the received xAPI surface rather than raw HTTP-body byte equality. The xAPI 1.0.3 specification permits Statement object properties in any order, requires differences caused by Statement-immutability exceptions to be ignored during comparison, and requires other serialization differences to remain significant (Advanced Distributed Learning Initiative, n.d.). A POST can contain one Statement or an array. For xAPI 1.0.3, rejecting an entire batch that contains duplicate Statement IDs is a specification SHOULD-level recommendation rather than a universal mandate about the persistence phase. This repository's policy is deliberately stricter for all accepted surfaces: a request containing duplicate Statement IDs is rejected fail-closed before canonical persistence. Request-level context and duplicate checks precede stored-evidence conflict comparison so failure precedence is deterministic.

`ingestion_receipt` preserves each immutable request entity and `request_content_hash`, while `statement_ingestion_item` records every per-request Statement occurrence and zero-based request index. Accepted/replayed occurrences resolve to canonical evidence; conflicting items remain unresolved; non-conflicting siblings of an atomically rejected batch use the explicit `batch_rejected` outcome. Tests must cover every submitted index on context, duplicate-ID, and stored-conflict batch failures while proving no partial canonical acceptance. An idempotent retry must produce a new receipt and occurrence association that points to the existing canonical `statement_record`; neither the original receipt association nor the canonical Statement is overwritten.

Tenant-scoped persistence evidence must prove that every tenant-owned relation carries tenant identity through composite keys and that cross-tenant reads and writes fail closed under the deployed database authorization model. A caller-selected custom setting is not authentication evidence. The initial database boundary maps the connection-establishing PostgreSQL `session_user` through administrator-controlled `tenant_database_principal`; forced RLS evaluates that binding even when the controlled write primitive executes as its constrained `SECURITY DEFINER` owner. Ordinary tenant principals must not need direct immutable-evidence mutation privileges. PostgreSQL documents the distinction between `session_user` and `current_user` and the application of row-security policies to row visibility and writes; OWASP authorization guidance supports least privilege, deny-by-default behavior, authorization at every request boundary, and dedicated authorization tests (OWASP Foundation, 2026; PostgreSQL Global Development Group, 2026a, 2026b).

## Repository-policy implementation evidence

The current persistence slice is repository-policy and security-design evidence, not xAPI conformance evidence. `migrations/0001_statement_evidence.sql` establishes the normalized immutable evidence schema and item-level accepted/replayed/conflict primitive. `migrations/0002_database_principal_boundary.sql` replaces caller-selected `app.tenant_key` authorization with the authenticated `session_user` mapping, forced RLS, and constrained `lrs_evidence_writer` write boundary. `migrations/0003_batch_rejection_outcome.sql` adds the explicit unresolved `batch_rejected` evidence state for atomically rejected request items.

Executable evidence is split by invariant. `tests/postgres_atomic_ingestion.sh` specifies real-PostgreSQL identical-writer and competing-content races, canonical non-overwrite, and conflict audit retention. `tests/postgres_principal_boundary.sh` proves GUC spoof resistance, direct immutable-table write denial, own-tenant controlled ingest, cross-tenant ingest denial, cross-tenant read isolation, and constrained function ownership. `tests/batch_rejection_evidence.rs` proves the domain kernel records every submitted item on rejected batches and detects duplicate identities before stored conflicts. `tests/postgres_batch_outcomes.sh` proves the durable schema can represent unresolved `batch_rejected` occurrences and rejects invalid canonical resolution.

These paths may be cited as implementation evidence only after the exact PR head passes the corresponding hosted quality workflow. They do not change the `Not implemented` conformance maturity above because the version-specific parser, REST behavior, durable one-receipt/many-item PostgreSQL transaction, attachments, document resources, and independent xAPI/cmi5 conformance suites are still absent. ADR 0002 records the authorization decision; `docs/product-technical-gap-baseline.md` records the remaining commercialization verification order.

## APA 7 references

Advanced Distributed Learning Initiative. (n.d.). *Experience API specification* (Part 2, §§2.2-2.3.1; Part 3, Statement Resource). https://github.com/adlnet/xAPI-Spec

Aviation Industry CBT Committee. (2016). *cmi5 specification profile for xAPI: Quartz, 1st edition*. https://github.com/AICC/CMI-5_Spec_Current/blob/quartz/cmi5_spec.md

Institute of Electrical and Electronics Engineers. (2023). *IEEE standard for learning technology—JavaScript Object Notation (JSON) data model format and Representational State Transfer (RESTful) web service for learner experience data tracking and access (IEEE Std 9274.1.1-2023).* https://standards.ieee.org/ieee/9274.1.1/7321/

International Organization for Standardization, International Electrotechnical Commission, & Institute of Electrical and Electronics Engineers. (2025). *Learning technology—JavaScript Object Notation (JSON) data model format and Representational State Transfer (RESTful) web service for learner experience data tracking and access—Part 1-1: xAPI using JSON serialization and RESTful data transport (ISO/IEC/IEEE 39274-1-1:2025).* https://www.iso.org/standard/91131.html

OWASP Foundation. (2026). *Authorization cheat sheet*. OWASP Cheat Sheet Series. https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html

PostgreSQL Global Development Group. (2026a). *PostgreSQL 17 documentation: Row security policies*. https://www.postgresql.org/docs/17/ddl-rowsecurity.html

PostgreSQL Global Development Group. (2026b). *PostgreSQL 18 documentation: System information functions and operators*. https://www.postgresql.org/docs/current/functions-info.html
