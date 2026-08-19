# Architecture

The Learning Record Store is the authoritative persistence service for xAPI learning records and xAPI document resources. It does not own enrollment, course completion policy, authored content, or psychometric response data.

## Initial modules

- `xapi_protocol`: request and response contracts.
- `statement_validation`: version-aware validation and profile checks.
- `statement_store`: immutable statement persistence, voiding relations, and query indexes.
- `document_store`: State, Agent Profile, and Activity Profile resources.
- `attachment_store`: content-addressed attachment persistence.
- `tenant_authorization`: tenant and actor authorization boundary.
- `conformance_runner`: executable standards-conformance evidence.

## Version boundary

xAPI 2.0 is the canonical target. xAPI 1.0.3 support exists only as an explicit compatibility surface required by cmi5 Quartz. Historical statements are retained in their received version and are never silently rewritten.

## Storage boundary

Relational indexes are normalized and tenant-scoped. Original statement JSON and attachments remain immutable evidence. Object storage may hold large immutable payloads while PostgreSQL holds identities, indexes, relationships, and integrity metadata.
