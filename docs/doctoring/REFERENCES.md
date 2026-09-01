# References

Initial standards baseline for implementation and conformance work:

- Institute of Electrical and Electronics Engineers. (2023). *IEEE standard for learning technology—JavaScript Object Notation (JSON) data model format and Representational State Transfer (RESTful) web service for learner experience data tracking and access (IEEE Std 9274.1.1-2023).* https://standards.ieee.org/ieee/9274.1.1/7321/
- International Organization for Standardization, International Electrotechnical Commission, & Institute of Electrical and Electronics Engineers. (2025). *Learning technology—JavaScript Object Notation data model format and RESTful web service for learner experience data tracking and access—Part 1-1: xAPI using JSON serialization and RESTful data transport (ISO/IEC/IEEE 39274-1-1:2025).* https://standards.ieee.org/ieee/39274-1-1/12268/
- Advanced Distributed Learning Initiative. (n.d.). *Experience API specification, version 2.0.* https://github.com/adlnet/xAPI-Spec
- Aviation Industry CBT Committee. (2016). *cmi5 specification profile for xAPI: Quartz, 1st edition.* https://github.com/AICC/CMI-5_Spec_Current/tree/quartz — compatibility surface based on xAPI 1.0.3.

## Operational security references

- OWASP Foundation. (2026). *Authorization cheat sheet*. OWASP Cheat Sheet Series. https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html — supports least privilege, deny-by-default authorization, checks at the correct boundary, and dedicated authorization tests.
- PostgreSQL Global Development Group. (2026). *PostgreSQL 18 documentation: System information functions and operators*. https://www.postgresql.org/docs/current/functions-info.html — distinguishes connection-establishing `session_user` from permission-checking `current_user`, including the latter's change under `SECURITY DEFINER`.
- PostgreSQL Global Development Group. (2026). *PostgreSQL 17 documentation: Row security policies*. https://www.postgresql.org/docs/17/ddl-rowsecurity.html — documents row-security policy application to visible and newly written rows and default-deny behavior when no policy permits access.

ADR 0002 applies these operational sources to the database-principal tenant boundary. They are security-design evidence, not xAPI conformance evidence.

## Normative-surface evidence registry

| Surface | Normative location | Required executable evidence | Current evidence |
|---|---|---|---|
| xAPI 2.0 statements and LRS processing | IEEE 9274.1.1-2023 / ISO/IEC/IEEE 39274-1-1:2025 and xAPI 2.0 specification Parts 2–3 | Statement validation, duplicate/conflict behavior, voiding, attachments, version negotiation, tenant isolation | Not evidenced |
| xAPI 2.0 document resources | xAPI 2.0 State, Agent Profile, and Activity Profile requirements | State/Profile create-update-read-delete, conditional requests, revision evidence, tenant isolation | Not evidenced |
| cmi5 Quartz compatibility | cmi5 Quartz Sections 6–14, including Statement, State, Profile, launch, session, and course-package requirements | Quartz launch/session ordering, registration, statements, State/Profile operations, provenance-preserving conversion | Not evidenced |
| xAPI 1.0.3 compatibility | cmi5 Quartz normative xAPI 1.0.3 reference plus xAPI 1.0.3 protocol surface | Version-specific validation and explicit conversion artifact tests | Not evidenced |

Implementation PRs must replace `Not evidenced` with links to exact test files and CI receipts only after the corresponding normative behavior is executable. Certification or conformance claims may not be inferred from documentation alone.
