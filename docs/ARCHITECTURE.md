# Architecture

<!-- lrs-document-contract:start -->
```json
{
  "canonical_xapi_surface": "2.0",
  "compatibility_surfaces": ["1.0.3", "cmi5 Quartz"],
  "learning_evidence_authority": "learning_record_store",
  "production_maturity": "pre_release",
  "published_service": false,
  "standards_certification": false
}
```
<!-- lrs-document-contract:end -->

The Learning Record Store is the authoritative persistence service for xAPI learning records and xAPI document resources. It does not own enrollment, course completion policy, authored content, or psychometric response data.

## Initial modules

- `xapi_protocol`: request and response contracts.
- `statement_validation`: version-aware validation and profile checks.
- `compatibility_adapter`: explicit xAPI 1.0.3/cmi5 compatibility transformations and the associated `compatibility_transform` / `compatibility_artifact` provenance records. This module may derive compatibility views but never becomes canonical learning-evidence authority or overwrites the received source surface.
- `ingestion_evidence`: immutable request receipts and per-Statement request-occurrence provenance, including idempotent retries and rejected conflicts.
- `statement_store`: one canonical immutable statement identity per tenant, voiding relations, and query indexes.
- `document_store`: State, Agent Profile, and Activity Profile resources.
- `attachment_store`: content-addressed attachment persistence.
- `tenant_authorization`: tenant and actor authorization boundary.
- `conformance_runner`: executable standards-conformance evidence.

## Version boundary

xAPI 2.0 is the canonical target. xAPI 1.0.3 support exists only as an explicit compatibility surface required by cmi5 Quartz. Historical statements are retained in their received version and are never silently rewritten. Replay comparison follows the Statement Comparison Requirements of the received surface rather than raw request-body equality. Compatibility transformations are owned by `compatibility_adapter`; their outputs remain provenance artifacts linked to received evidence and are not promoted into a second canonical Statement identity.

## Storage boundary

Relational indexes are normalized and tenant-scoped. Original statement JSON, request receipts, per-Statement ingestion occurrences, and attachments remain immutable evidence. A canonical `statement_record` is not rewritten when an idempotent retry arrives; the new request occurrence resolves to that existing canonical identity through a separate tenant-scoped association. Object storage may hold large immutable payloads while PostgreSQL holds identities, indexes, relationships, provenance, and integrity metadata.
