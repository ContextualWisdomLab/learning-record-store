# Changelog

## Unreleased

### Added

- Initial LRS authority and module boundaries.
- Normalized xAPI persistence data-model baseline.
- xAPI 2.0 and cmi5 compatibility reference baseline.
- Standards traceability ledger that separates canonical xAPI 2.0 evidence from xAPI 1.0.3/cmi5 compatibility evidence.
- Repository development rules.

### Changed

- Hardened exact-head bootstrap validation, statement identity, attachment digests, and compatibility-artifact provenance so conflicting evidence fails closed and transformed outputs remain auditable without becoming canonical learning evidence.
- Replaced raw request-body replay equality with version-aware xAPI Statement comparison while retaining immutable request receipts and per-Statement provenance for single and batch ingestion.
- Separated canonical Statement identity from per-request ingestion occurrences so idempotent retries retain every immutable receipt, and replaced phrase-only bootstrap checks with an exact machine-readable contract.
