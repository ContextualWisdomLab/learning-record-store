# Product requirements: immutable xAPI evidence kernel

Status: Active implementation slice
Last reconciled: 2026-09-01

## Product responsibility

ContextualWisdomLab Learning Record Store is the authoritative persistence boundary for received xAPI statements, xAPI document resources, attachments, and their integrity/provenance evidence. Learning Management Platform and other products consume this evidence through released APIs or contracts. They do not obtain authority by reading LRS database tables directly.

The LRS does not own enrollment, completion policy, authored course content, psychometric response/scoring truth, payment state, or customer workflow state.

## Customer problem

A learning platform cannot make reliable downstream progression, audit, or compliance decisions when activity evidence can be overwritten, silently reinterpreted across xAPI versions, duplicated on retry, or read across tenant boundaries. The first commercial product slice must therefore make the core evidence semantics executable before higher-level reporting or CEFR-specific profile work depends on them.

## First executable workflow

1. An authorized tenant sends a statement under an explicit xAPI version.
2. `statement_validation` validates the received surface and produces a version-specific Statement comparison representation without mutating the source evidence.
3. `ingestion_evidence` records the exact received request evidence and its digest.
4. `statement_store` resolves `(tenant_key, statement_key)` atomically.
5. A previously unseen identity is accepted once. An equivalent retry resolves to the existing canonical Statement. A version or comparison mismatch is recorded as a rejected conflict and never overwrites canonical evidence.
6. Voiding creates a tenant-local relationship between immutable Statements; it never deletes the original Statement.
7. Consumers query only tenant-authorized evidence and cannot use compatibility artifacts as a second source of canonical truth.

## Commercial acceptance for this slice

The slice is reviewable when executable Rust tests prove first acceptance, exact-retry reuse, conflict rejection, source-byte retention for accepted/replayed/rejected request occurrences, protocol-version separation, tenant-scoped identity, and non-destructive voiding. The persistence schema must use descriptive multiword `snake_case` objects, preserve a single canonical `(tenant_key, statement_key)` identity, use composite tenant foreign keys, and fail closed through PostgreSQL row-level security when tenant context is absent or mismatched.

The slice is not production-ready until the same decision contract is proven against real PostgreSQL transactions under duplicate-ID concurrency, a non-superuser/non-BYPASSRLS role, rollback/reapply and backup/restore, and version-specific xAPI conformance fixtures. Public Rust surfaces must remain fully documented and touched production paths must reach the repository coverage target without warning suppression.

## Non-goals for this slice

- No generic JSON canonicalizer is declared equivalent to xAPI Statement Comparison Requirements.
- No xAPI 1.0.3 input is silently upgraded to xAPI 2.0.
- No compatibility artifact becomes canonical learning evidence.
- No raw psychometric response, provider output, task content, or production synthetic demo record is introduced.
- No CEFR profile definition is copied into this repository; shared profile/SDK contracts remain owned by the interoperability supplier.
- No buyer-facing claim of ADL, IEEE, ISO, cmi5, CSAP, or SOC 2 certification is made from repository tests alone.

## Product measures

For this foundational slice, commercialization progress is evidence-based rather than traffic-based: zero canonical duplicates under tested races, zero accepted conflicting replays, zero cross-tenant reads or references under the production database role, deterministic preservation of every request occurrence, and reproducible exact-head CI/conformance receipts. Latency and load objectives become release gates when the network service is introduced; they are not claimed by the in-process kernel.

## Dependency and reuse boundaries

`learning-interoperability-contracts` owns reusable cross-product profile/contracts. Learning Management Platform is a downstream policy consumer. CEFR-specific activity evidence remains downstream of a released shared profile. Reusable identity, authorization, orchestration, psychometric, or lineage defects must be fixed in their owning ContextualWisdomLab repositories rather than copied into this service.
