# Changelog

## Unreleased

### Added

- Initial LRS authority and module boundaries.
- Normalized xAPI persistence data-model baseline.
- xAPI 2.0 and cmi5 compatibility reference baseline.
- Standards traceability ledger that separates canonical xAPI 2.0 evidence from xAPI 1.0.3/cmi5 compatibility evidence.
- Repository development rules.
- Rust `StatementKernel` implementing tenant-scoped canonical identity, immutable request receipts, version-aware replay/conflict decisions, non-destructive voiding, and atomic batch-rejection evidence.
- Regression and edge-case tests for first ingest, equivalent replay, conflict rejection, version mismatch, tenant isolation, exact raw evidence retention, invalid evidence, voiding failures, duplicate-batch precedence, context mismatch, every-item rejected-batch provenance, multiple stored conflicts in one rejected batch, and PostgreSQL whitespace-only identity/version rejection.
- PostgreSQL statement-evidence migration with composite tenant keys, 3NF relations, exact `bytea` evidence, forced tenant row-level security, and database-enforced SHA-256 consistency between immutable evidence bytes and their stored digests.
- `persist_statement_occurrence`, the controlled item-level PostgreSQL transaction primitive that retains request/occurrence evidence while resolving accepted, replayed, and conflicting Statement identities atomically.
- Real PostgreSQL race fixtures for identical first writers and competing content, requiring a single canonical row and preserved accepted/replayed or accepted/conflict occurrence evidence.
- Authenticated database-principal tenant binding through `tenant_database_principal`, `authorized_tenant_key()`, constrained `lrs_evidence_writer`, and negative tests proving a caller-selected tenant GUC cannot retarget authorization or bypass immutable-evidence controls.
- Explicit durable `batch_rejected` outcome and PostgreSQL constraint tests for rejected POST-array item evidence, including successful-outcome fixtures that require a non-null canonical Statement link.
- `persist_statement_batch`, a controlled PostgreSQL primitive for one-receipt/many-item validated POST-array persistence with deterministic per-Statement identity serialization, atomic canonical mutation, and durable `conflict`/`batch_rejected` occurrence evidence.
- Real PostgreSQL shared-receipt batch transaction fixtures covering two-item acceptance, replay, conflict rejection without sibling leakage, canonical non-overwrite, and duplicate-identity fail-closed behavior.
- ADR 0002 documenting the authenticated database-principal authorization boundary and its PostgreSQL/OWASP rationale.
- Proposed ADR 0003 documenting per-Statement transaction serialization for atomic durable batches and explicitly rejecting tenant-wide/table-wide locks.
- Product and technical requirements for the first executable commercialization slice.
- Exact-head Rust formatting, test, Clippy, rustdoc, 100% line-coverage, PostgreSQL invariant, transactional race, database-principal, batch-outcome, and shared-receipt batch gates, including pull requests stacked on non-default branches.
- Product-first README, Apache-2.0 repository license, public documentation landing source, and clarified document-resource revision/idempotency semantics carried forward from the foundation branch without rewriting stack history.

### Changed

- Hardened exact-head bootstrap validation, statement identity, attachment digests, and compatibility-artifact provenance so conflicting evidence fails closed and transformed outputs remain auditable without becoming canonical learning evidence.
- Replaced raw request-body replay equality with version-aware xAPI Statement comparison while retaining immutable request receipts and per-Statement provenance for single and batch ingestion.
- Separated canonical Statement identity from per-request ingestion occurrences so idempotent retries retain every immutable receipt, and replaced phrase-only bootstrap checks with an exact machine-readable contract whose comparison preserves JSON type distinctions.
- Aligned persistence identity terminology on `tenant_key` / `statement_key` and raw 32-octet SHA-256 digests so code, migrations, DATA_MODEL, PRD, TRD, architecture, and CI describe one contract.
- Kept canonical replay resolution read-only: PostgreSQL unique-index conflict serialization protects the minimum Statement identity while immutable rows do not require UPDATE privileges or an extra row lock.
- Replaced the bootstrap `SECURITY INVOKER` plus caller-selected `app.tenant_key` authorization model with principal-bound forced RLS and a constrained `SECURITY DEFINER` write boundary; ordinary tenant principals no longer require direct immutable-table mutation privileges.
- Ordered POST-array preflight so tenant/version context and duplicate identities are resolved before canonical conflict comparison; the full batch is now scanned before rejection so every stored conflict index is classified as `Conflict` and only non-conflicting siblings become `BatchRejected`, without partial canonical acceptance.
- Replaced PostgreSQL space-only `btrim` identity/version checks with whitespace-class validation at schema and controlled-writer boundaries so tabs/newlines cannot persist where the Rust kernel rejects blank identities; the regression suite now isolates statement-key and comparison-version failures so one constraint cannot mask the other.
- Tightened PostgreSQL occurrence consistency so `accepted` and `replayed` rows cannot pass a CHECK constraint with a null canonical link under SQL three-valued logic, and privileged/manual inserts cannot store digests inconsistent with immutable request/comparison bytes.
- Bound the public Rust kernel to PostgreSQL persistence widths: receipt issuance fails closed before signed `bigint` exhaustion, both batch and direct occurrence indexes stay within signed `integer`, and validated POST arrays must cross the kernel boundary as exact-size collections so complete preflight remains mandatory.
- Unified controlled single-item and batch writes on the same transaction-scoped per-Statement advisory-lock protocol, acquired in deterministic order for batches, so an overlapping controlled writer cannot invalidate batch preflight without serializing unrelated tenant evidence.
- Downgraded ADR 0002 from Accepted to Proposed while its authorization implementation remains only on the unmerged writer stack; acceptance now requires current exact-head evidence and ordinary protected-branch integration.
