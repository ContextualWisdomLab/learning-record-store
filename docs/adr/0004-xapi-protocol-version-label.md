# ADR 0004: Preserve xAPI 2.0 request labels and canonicalize processing

- **Status:** Proposed
- **Date:** 2026-09-12
- **Owners:** Learning Record Evidence and Protocol Compatibility
- **Decision scope:** request-version persistence and canonical Statement comparison

## Problem

The product correctly names its canonical family “xAPI 2.0.” An earlier revision repaired rejection of the exact `2.0.0` label but then rejected `2.0`. That conclusion relied on a content-standard example instead of the applicable LRS requirement. IEEE 9274.1.1 requires an LRS to accept a request version of `2.0` as if it were `2.0.0`.

The persistence boundary must therefore preserve two different facts: the exact validated request label for audit provenance and the canonical protocol surface used to compare one immutable Statement identity.

## Constraints

- Preserve the exact validated request label on every immutable receipt.
- Process both IEEE-defined `2.0` and `2.0.0` request labels under the same canonical `2.0.0` Statement surface.
- Do not misclassify an alias-only retry as a content conflict.
- Keep xAPI 1.0.3 as a separate cmi5 compatibility surface.
- Unknown or mismatched protocol/comparison-version pairs fail before durable mutation.
- This unmerged pre-release branch may amend its migrations; released migrations remain immutable.
- This correction is bounded persistence evidence, not a complete HTTP parser or conformance claim.

## Alternatives

1. **Accept only `2.0.0`.** Rejected because it contradicts the IEEE LRS requirement for `2.0`.
2. **Persist the raw label on both receipt and canonical Statement.** Rejected because equivalent `2.0` and `2.0.0` retries would occupy different comparison surfaces and could become false conflicts.
3. **Retain the raw label on the receipt and normalize only canonical Statement processing.** Selected because it preserves audit provenance while implementing the required alias equivalence.

## Decision

`statement_comparison_version_for_xapi` maps both `2.0` and `2.0.0` to `xapi-2.0-statement-comparison/v1`. `canonical_xapi_version_label` maps both inputs to `2.0.0`. The item and batch writers store the caller's validated input in `ingestion_receipt.received_xapi_version`, store the normalized label in `statement_record.received_xapi_version`, and compare replays against that normalized label.

`XapiVersion::V2_0.as_str()` remains `2.0.0` because the Rust kernel currently represents the normalized protocol surface. The future HTTP/repository adapter must retain the exact validated header separately when creating the durable receipt.

## Evidence

- IEEE 9274.1.1 xAPI Base Standard for LRSs, Versioning requirements: https://opensource.ieee.org/xapi/xapi-base-standard-documentation/-/blob/main/9274.1.1%20xAPI%20Base%20Standard%20for%20LRSs.md
- Test-only RED run 34699335410: the batch writer rejected required `2.0` input with SQLSTATE `22023`.
- Implementation run 34699741575: item and batch fixtures passed after preserving raw receipt labels, normalizing canonical Statements, and repairing rollback coverage for the new helper.
- Final documentation-head GREEN remains required before this Proposed decision can advance.

## Effects and risks

A request received as `2.0` remains auditable as `2.0` on its receipt. Its canonical Statement uses `2.0.0`, and an otherwise equivalent retry received as `2.0.0` resolves as replayed rather than conflicting. Unknown labels and xAPI/comparison-version mismatches remain fail closed.

The SQL functions trust an upstream adapter to supply a validated header value. Header presence, multi-value syntax, whitespace rules, response header selection, xAPI 1.0.x negotiation, JSON validation, Statement comparison, cmi5 behavior, and protocol error mapping remain unimplemented. Treating this slice as full xAPI conformance would be false assurance.

## Operational and failure scenes

- A client sends `X-Experience-API-Version: 2.0`: the receipt stores `2.0`, while the canonical Statement stores and compares as `2.0.0`.
- The client retries equivalent evidence with `2.0.0`: the writer records a new `2.0.0` receipt and returns `replayed` without rewriting the canonical Statement.
- A client sends an unknown version or a 1.0.3 label with the 2.0 comparison identifier: the writer rejects the pair before receipt or canonical mutation.
- An operator rolls back an empty pre-release schema: the rollback removes the normalization helper before ordered migration reapplication; retained evidence still blocks rollback atomically.

## Follow-up

Implement lossless version-specific HTTP parsing, response-version negotiation, parser-to-`StatementCandidate` adaptation, xAPI 2.0 and xAPI 1.0.3 comparison rules, and independent xAPI/cmi5 conformance suites. Keep PR #6 Draft and this ADR Proposed until exact-head CI, qualifying review, ordinary protected-branch integration, and the remaining gates support a status change.
