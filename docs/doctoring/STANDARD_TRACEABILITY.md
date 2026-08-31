# Standards traceability

This file is the bootstrap traceability ledger for the Learning Record Store. It records standards ownership and the evidence that must exist before this repository makes an implementation or conformance claim. Documentation alone is not conformance evidence.

Primary-source status was rechecked on 2026-09-01. IEEE 9274.1.1-2023 remains an active xAPI base standard, and ISO/IEC/IEEE 39274-1-1:2025 remains the published international adoption. cmi5 Quartz remains a separate xAPI 1.0.3 compatibility surface; it is not evidence that an xAPI 2.0 implementation conforms to cmi5.

## Normative surface map

| Surface | Normative authority | Repository ownership | Required executable evidence before `Implemented` | Current maturity |
| --- | --- | --- | --- | --- |
| xAPI statement and LRS REST behavior | IEEE 9274.1.1-2023; ISO/IEC/IEEE 39274-1-1:2025 | `xapi_protocol`, `statement_validation`, `statement_store` | Version negotiation, statement validation, same-content retry, conflicting-content rejection, voiding, query, attachment, authorization and tenant-isolation tests against the exact implemented version | Not implemented |
| State, Agent Profile and Activity Profile resources | IEEE 9274.1.1-2023 / ISO/IEC/IEEE 39274-1-1:2025 document-resource requirements | `document_store` | Create/update/read/delete, conditional-request, replay/revision, authorization and tenant-isolation tests that distinguish mutable current resource state from immutable audit evidence | Not implemented |
| cmi5 Quartz compatibility | *cmi5 Specification Profile for xAPI*, Quartz, 1st ed.; especially §§4, 6-14 | Compatibility adapter only; canonical storage remains version-aware xAPI evidence | Independent Quartz launch/session, Statement API, State API, statement data-model, State, Agent Profile, Activity Profile and package fixtures using received xAPI 1.0.3 semantics | Not implemented |
| xAPI 1.0.3 compatibility transformation | ADL xAPI 1.0.3 as referenced normatively by cmi5 Quartz §2 | Compatibility-transform artifact boundary | Source-version preservation, deterministic conversion, converter-version provenance, output digest, validation receipt, replay and conflict tests; source evidence must never be overwritten | Not implemented |
| Attachment integrity | Applicable xAPI attachment requirements in the selected xAPI version | `attachment_store` plus statement relation | Digest, media type, byte length, immutable object identity, duplicate-content handling, storage-locator integrity, authorization and malicious-content non-execution tests | Not implemented |

## Evidence rules

Every implementation PR that changes a normative surface must update this ledger with exact test paths and an exact-head CI receipt. A passing generic unit test, skipped required step, predecessor-head result, model-only review, or documentation assertion is not standards evidence. xAPI 2.0 and xAPI 1.0.3/cmi5 compatibility are tested independently; a conversion artifact records source version, target version, converter version, output hash, validation result and provenance identity.

Tenant-scoped persistence evidence must prove that every tenant-owned relation carries tenant identity through composite keys and that cross-tenant reads and references fail closed under the deployed database authorization model. Statement history and compatibility source evidence remain immutable; document-resource current-state semantics are implemented separately from their audit/revision evidence.

## APA 7 references

Aviation Industry CBT Committee. (2016). *cmi5 specification profile for xAPI: Quartz, 1st edition*. https://github.com/AICC/CMI-5_Spec_Current/blob/quartz/cmi5_spec.md

Institute of Electrical and Electronics Engineers. (2023). *IEEE standard for learning technology—JavaScript Object Notation (JSON) data model format and Representational State Transfer (RESTful) web service for learner experience data tracking and access (IEEE Std 9274.1.1-2023).* https://standards.ieee.org/ieee/9274.1.1/7321/

International Organization for Standardization, International Electrotechnical Commission, & Institute of Electrical and Electronics Engineers. (2025). *Learning technology—JavaScript Object Notation (JSON) data model format and Representational State Transfer (RESTful) web service for learner experience data tracking and access—Part 1-1: xAPI using JSON serialization and RESTful data transport (ISO/IEC/IEEE 39274-1-1:2025).* https://www.iso.org/standard/91131.html

Advanced Distributed Learning Initiative. (n.d.). *Experience API specification*. https://github.com/adlnet/xAPI-Spec
