# ADR 0004: Use the exact xAPI 2.0.0 protocol label

- **Status:** Proposed
- **Date:** 2026-09-12
- **Owners:** Learning Record Evidence and Protocol Compatibility
- **Decision scope:** request-version validation and immutable protocol provenance

## Problem

The product correctly names its canonical family “xAPI 2.0,” but the Rust kernel and PostgreSQL controlled writers used the shorthand `2.0` as the received and persisted value. The official IEEE xAPI 2.0 content examples use `X-Experience-API-Version: 2.0.0`. A conforming client sending that exact value was therefore rejected before receipt creation, while a non-normative shorthand was accepted.

## Constraints

- The buyer-facing product and bounded-context surface remain named xAPI 2.0.
- Received protocol provenance must retain the exact validated version label.
- xAPI 1.0.3 remains a separate cmi5 compatibility surface.
- Unknown or mismatched protocol/comparison-version pairs fail before durable mutation.
- This branch is pre-release and unmerged; no released datastore migration may be rewritten after adoption.
- This correction is bounded evidence, not a full parser, HTTP negotiation, or conformance claim.

## Alternatives

1. **Keep `2.0`.** Rejected because it conflicts with the authoritative wire value and rejects a correctly labelled request.
2. **Accept both and silently normalize to `2.0.0`.** Rejected because it hides non-normative input and changes immutable provenance.
3. **Accept and persist only `2.0.0` for the xAPI 2.0 family.** Selected because it is minimal, fail closed, and preserves exact protocol evidence.

## Decision

`XapiVersion::V2_0.as_str()` returns `2.0.0`. The PostgreSQL `statement_comparison_version_for_xapi` mapping recognizes only `2.0.0` for `xapi-2.0-statement-comparison/v1`. Test fixtures use the exact label. The comparison-algorithm identifier retains `xapi-2.0` because it names the specification family rather than a received wire value.

## Evidence

- IEEE 9274.1.1 xAPI Base Standard for Content, version-header example: https://opensource.ieee.org/xapi/xapi-base-standard-documentation/-/blob/24586e13b897697537fb73b9818d86ba403ab787/9274.1.1%20xAPI%20Base%20Standard%20for%20Content.md
- Test-only Rust RED run 34696139700: the public label returned `2.0` instead of `2.0.0`.
- Test-only PostgreSQL RED run 34696243001: the controlled writer rejected `2.0.0` as an incompatible protocol/comparison pair.
- Exact-head GREEN remains required before this Proposed decision can advance.

## Effects and risks

A standards-labelled xAPI 2.0 request can cross the proposed kernel and persistence boundary without losing its exact version provenance. The non-normative `2.0` shorthand now fails closed. Existing pre-release fixtures and branch-local rows must use `2.0.0`; after a release, any label change would require a forward migration rather than rewriting historical migrations.

The correction does not validate HTTP headers, JSON structure, Statement comparison rules, cmi5 behavior, or independent conformance. Treating it as broader evidence would be a false assurance.

## Operational and failure scenes

- A client sends `X-Experience-API-Version: 2.0.0`: the future adapter maps it to `V2_0`, and the immutable receipt and Statement retain `2.0.0`.
- A client sends `2.0`: the future adapter rejects it; the repository never silently upgrades the claimed source version.
- A stored `2.0.0` Statement is replayed with a 1.0.3 comparison label: the controlled writer rejects the incompatible pair before canonical mutation.
- An operator upgrades a released datastore that contains historical evidence: a reviewed forward migration is required; the original released migration and evidence are not rewritten.

## Follow-up

Implement lossless version-specific parsing, HTTP version negotiation, parser-to-`StatementCandidate` adaptation, xAPI 2.0 and xAPI 1.0.3 comparison rules, and independent xAPI/cmi5 conformance suites. Keep PR #6 Draft and this ADR Proposed until exact-head CI, qualifying review, ordinary protected-branch integration, and those remaining gates support a status change.
