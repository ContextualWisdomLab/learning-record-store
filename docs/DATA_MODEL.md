# Data model baseline

Database objects use two-or-more-word `snake_case` names and are normalized to third normal form for authoritative relational facts.

Initial entities:

- `statement_record`
- `statement_actor`
- `statement_object`
- `statement_context`
- `statement_result`
- `statement_attachment`
- `voiding_relation`
- `activity_state_document`
- `agent_profile_document`
- `activity_profile_document`
- `tenant_partition`
- `ingestion_receipt`

The original received JSON is immutable evidence. Searchable attributes are projected into normalized relations without making the projection a substitute for the source payload. Duplicate statement identifiers are idempotent only when their content identity is valid under the applicable xAPI contract; conflicting duplicates fail closed.
