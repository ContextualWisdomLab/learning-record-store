# Changelog

## Unreleased

### Added

- Initial LRS authority and module boundaries.
- Normalized xAPI persistence data-model baseline.
- xAPI 2.0 and cmi5 compatibility reference baseline.
- Standards traceability ledger that separates canonical xAPI 2.0 evidence from xAPI 1.0.3/cmi5 compatibility evidence.
- Repository development rules.
- Rust `StatementKernel` implementing tenant-scoped canonical identity, immutable request receipts, version-aware replay/conflict decisions, and non-destructive voiding.
- Regression and edge-case tests for first ingest, equivalent replay, conflict rejection, version mismatch, tenant isolation, exact raw evidence retention, invalid evidence, and voiding failures.
- PostgreSQL statement-evidence migration with composite tenant keys, 3NF relations, exact `bytea` evidence, and forced tenant row-level security.
- Product and technical requirements for the first executable commercialization slice.
- Exact-head Rust formatting, test, Clippy, rustdoc, and 100% line-coverage gates, including pull requests stacked on non-default branches.

### Changed

- Hardened exact-head bootstrap validation, statement identity, attachment digests, and compatibility-artifact provenance so conflicting evidence fails closed and transformed outputs remain auditable without becoming canonical learning evidence.
- Replaced raw request-body replay equality with version-aware xAPI Statement comparison while retaining immutable request receipts and per-Statement provenance for single and batch ingestion.
- Separated canonical Statement identity from per-request ingestion occurrences so idempotent retries retain every immutable receipt, and replaced phrase-only bootstrap checks with an exact machine-readable contract.
- Aligned persistence identity terminology on `tenant_key` / `statement_key` and raw 32-octet SHA-256 digests so code, migration, DATA_MODEL, PRD, TRD, and CI describe one contract.
