# Agent development rules

- Keep the LRS authoritative only for xAPI statements, xAPI document resources, attachments, and their integrity metadata.
- Preserve received learning records immutably; corrections use standards-defined mechanisms rather than row mutation.
- Treat xAPI 2.0 as canonical and xAPI 1.0.3/cmi5 Quartz as an explicit compatibility surface. Never silently reinterpret one surface as the other.
- Use two-or-more-word `snake_case` database object names and third normal form for authoritative relational facts.
- Cross-tenant references must fail closed. Database authorization must derive from an administrator-controlled authenticated principal binding; caller-selected GUCs such as `app.tenant_key` are never authorization identities.
- Ordinary data-plane principals must not receive direct INSERT/UPDATE/DELETE privileges on immutable evidence tables; controlled write functions must use fixed search paths, constrained non-superuser/non-`BYPASSRLS` owners, and forced RLS.
- Production statement and branch coverage must be 100%, with complete public API documentation.
- Conformance evidence must independently exercise the xAPI 2.0 canonical path and the xAPI 1.0.3/cmi5 Quartz compatibility path.
- Each conformance path must cover input acceptance, compatibility transformation where applicable, provenance, conflicting replay, tenant isolation, statements, voiding, attachments, State documents, Agent Profile documents, and Activity Profile documents.
- Statement replay equality must follow the Statement Comparison Requirements of the received xAPI surface; immutable raw request bytes are audit evidence, not the equality comparator for a parsed Statement.
- Preserve every request occurrence through a tenant-scoped receipt-to-Statement association. Idempotent retries may resolve to an existing canonical `statement_record` but must never overwrite or repoint an earlier receipt association.
- A rejected POST array must preserve an occurrence for every submitted Statement index while creating no canonical Statement rows. Non-conflicting siblings in a rejected batch use the explicit `batch_rejected` evidence state; duplicate identities are detected before canonical conflict comparison.
- Compatibility evidence must prove that the original payload, source protocol version (`source_xapi_version`), target protocol version (`target_xapi_version`), converter version, transformed output hash, validation result, and `provenance_reference` remain traceable and reproducible.
