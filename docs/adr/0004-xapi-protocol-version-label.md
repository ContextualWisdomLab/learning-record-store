# ADR 0004: Preserve xAPI request labels and canonicalize protocol processing

- **Status:** Proposed
- **Date:** 2026-09-12
- **Owners:** Learning Record Evidence and Protocol Compatibility
- **Decision scope:** request-version persistence and canonical Statement comparison

## Problem

The product correctly names its canonical family “xAPI 2.0.” An earlier revision repaired rejection of the exact `2.0.0` label but then rejected `2.0`. That conclusion relied on a content-standard example instead of the applicable LRS requirement. IEEE 9274.1.1 requires an LRS to accept a request version of `2.0` as if it were `2.0.0`.

The persistence boundary must therefore preserve two different facts: the exact validated request label for audit provenance and the canonical protocol surface used to compare one immutable Statement identity. The xAPI 1.0.3 compatibility boundary has the same distinction: ADL requires an LRS to accept `1.0` as `1.0.0` and otherwise-valid `1.0.x` request headers, while the Statement data model remains version `1.0.0` throughout the xAPI 1.0 family.

## Constraints

- Preserve the exact validated request label on every immutable receipt.
- Process both IEEE-defined `2.0` and `2.0.0` request labels under the same canonical `2.0.0` Statement surface.
- Do not misclassify an alias-only retry as a content conflict.
- Keep xAPI 1.0.3 as a separate cmi5 compatibility surface while accepting its required `1.0` and valid `1.0.x` request labels.
- Reject malformed leading-zero patch labels instead of broad prefix matching.
- Unknown or mismatched protocol/comparison-version pairs fail before durable mutation.
- This unmerged pre-release branch may amend its migrations; released migrations remain immutable.
- This correction is bounded persistence evidence, not a complete HTTP parser or conformance claim.

## Alternatives

1. **Accept only `2.0.0`.** Rejected because it contradicts the IEEE LRS requirement for `2.0`.
2. **Persist the raw label on both receipt and canonical Statement.** Rejected because equivalent `2.0` and `2.0.0` retries would occupy different comparison surfaces and could become false conflicts.
3. **Retain the raw label on the receipt and normalize only canonical Statement processing.** Selected because it preserves audit provenance while implementing the required alias equivalence for both protocol families.

## Decision

`ReceivedXapiVersion::from_header_values` is the Rust anti-corruption boundary for HTTP extraction. It requires exactly one UTF-8 request-version value, then delegates syntax and surface selection to `ReceivedXapiVersion::parse`; missing, repeated, non-UTF-8, whitespace-altered, combined, malformed, and unsupported inputs fail closed. The value object retains the exact accepted value and selects the normalized `XapiVersion`, canonical Statement label, and comparison implementation. `statement_comparison_version_for_xapi` maps both `2.0` and `2.0.0` to `xapi-2.0-statement-comparison/v1`. It maps `1.0` and syntactically valid `1.0.x` request labels to the existing `xapi-1.0.3-statement-comparison/v1` compatibility implementation. `canonical_xapi_version_label` maps xAPI 2.0 inputs to `2.0.0` and accepted xAPI 1.0 inputs to the stable data-model label `1.0.0`. The item and batch writers store the exact validated input in `ingestion_receipt.received_xapi_version`, store the normalized label in `statement_record.received_xapi_version`, and compare replays against that normalized label. The future repository adapter must pass these two facts through without parsing the label again.

The Rust kernel represents normalized Statement protocol surfaces: `XapiVersion::V2_0.as_str()` returns `2.0.0`, and `XapiVersion::V1_0_3.as_str()` returns the stable xAPI 1.0 data-model label `1.0.0`. `ReceivedXapiVersion::response_header_value()` separately returns the latest supported response value: `2.0.0` for the canonical surface and `1.0.3` for the compatibility surface, independent of the exact accepted request label. The `V1_0_3` variant and `xapi-1.0.3-statement-comparison/v1` identifier continue to name the compatibility and comparison implementation; they are not persisted Statement labels. `ReceivedXapiVersion` keeps the exact request value adjacent to that normalized selection until the repository adapter creates the durable receipt.

## Evidence

- IEEE 9274.1.1 xAPI Base Standard for LRSs, Versioning requirements: https://opensource.ieee.org/xapi/xapi-base-standard-documentation/-/blob/main/9274.1.1%20xAPI%20Base%20Standard%20for%20LRSs.md
- Test-only RED run 34699335410: the batch writer rejected required `2.0` input with SQLSTATE `22023`.
- Implementation run 34699741575: item and batch fixtures passed after preserving raw receipt labels, normalizing canonical Statements, and repairing rollback coverage for the new helper.
- ADL xAPI 1.0.3, Part 3, §3.3 Versioning: https://github.com/adlnet/xAPI-Spec/blob/master/xAPI-Communication.md
- Test-only RED run 34702148283: the batch writer rejected required `1.0` input at the shared persistence mapping boundary.
- Implementation run 34702333379: item and batch fixtures accepted `1.0`/valid `1.0.x`, retained exact receipt labels, canonicalized Statements to `1.0.0`, proved alias replay, and rejected a malformed leading-zero patch.
- Test-only RED run 34703770760: the Rust public label still returned `1.0.3` while PostgreSQL and this decision required canonical Statement label `1.0.0`; seven kernel tests passed and the label contract failed with the exact mismatch.
- Implementation run 34703937618: all six PostgreSQL suites and 35 Rust tests passed after aligning the Rust canonical label, with formatting, Clippy, warning-free rustdoc, and zero uncovered owned source lines.
- Test-only predecessor `ab06c2620346265470093c1f34777d8b14ba7ef3` adds the public lossless request-version contract before `ReceivedXapiVersion` exists. Its hosted run 35432045410 remained queued, so it is retained as compile-negative source evidence rather than reported as an executed RED result.
- Test-only predecessor `275542a333436f922468aeea3cea4f40a78df319` adds the missing/single/repeated/non-UTF-8 HTTP extraction contract before the API exists. Run 35437289368 was superseded and cancelled without executing, so it is not reported as RED evidence.
- Test-only predecessor `bc045f18702c065d1cdf353e6c24d5e622af5320` requires surface-specific response values before the public method exists. It remains source evidence unless a hosted run actually executes and fails.
- Final review-contract head remains subject to exact-head GREEN and qualifying review before this Proposed decision can advance.

## Effects and risks

A request received as `2.0` remains auditable as `2.0` on its receipt. Its canonical Statement uses `2.0.0`, and an otherwise equivalent retry received as `2.0.0` resolves as replayed rather than conflicting. Likewise, exact `1.0` or `1.0.x` input remains on its receipt while its canonical Statement uses `1.0.0`; equivalent valid patch labels replay on the reviewed xAPI 1.0.3 comparison implementation. Unknown labels, malformed leading-zero patches, and xAPI/comparison-version mismatches remain fail closed.

The SQL functions trust an upstream adapter to supply a validated header value. The Rust value object now enforces header presence/cardinality, UTF-8 encoding, supported exact labels, and surface-specific response value selection, but HTTP response emission, version negotiation outside these bounded mappings, durable receipt adaptation, JSON validation, full Statement comparison, cmi5 behavior, and protocol error mapping remain unimplemented. Treating this slice as full xAPI conformance would be false assurance.

## Operational and failure scenes

- A client sends `X-Experience-API-Version: 2.0`: the receipt stores `2.0`, while the canonical Statement stores and compares as `2.0.0`.
- The client retries equivalent evidence with `2.0.0`: the writer records a new `2.0.0` receipt and returns `replayed` without rewriting the canonical Statement.
- A compatibility client sends `1.0` and retries equivalent evidence with `1.0.12`: each receipt keeps its exact label, the canonical Statement remains `1.0.0`, and the retry returns `replayed`.
- A client omits the header, repeats it, sends non-UTF-8 bytes, malformed `1.0.03`, whitespace-padded `2.0`, or a combined `2.0, 1.0.3` value: the Rust boundary rejects it without normalizing or selecting a value, before receipt or canonical mutation.
- A client sends an unknown version or a 1.0.3 label with the 2.0 comparison identifier: the writer rejects the pair before receipt or canonical mutation.
- An operator rolls back an empty pre-release schema: the rollback removes the normalization helper before ordered migration reapplication; retained evidence still blocks rollback atomically.

## Follow-up

Connect the selected response value to every HTTP response, then implement durable receipt and parser-to-`StatementCandidate` adaptation, xAPI 2.0 and xAPI 1.0.3 comparison rules, and independent xAPI/cmi5 conformance suites. Keep PR #6 Draft and this ADR Proposed until exact-head CI, qualifying review, ordinary protected-branch integration, and the remaining gates support a status change.
