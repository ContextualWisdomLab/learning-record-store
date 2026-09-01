# Data model baseline

Database objects use two-or-more-word `snake_case` names and are normalized to third normal form for authoritative relational facts.

Every tenant-scoped entity owns an explicit `tenant_key`. References between tenant-scoped entities use composite foreign keys that include `tenant_key`; a same-object identifier from another tenant is never sufficient. PostgreSQL RLS or an equivalent enforced partition constraint must fail closed when a cross-tenant reference is attempted.

The following block is the machine-readable bootstrap contract consumed by exact-head quality validation. Prose in this document explains the contract but does not override it.

<!-- lrs-bootstrap-contract:start -->
```json
{
  "batch_duplicate_statement_id": "reject_before_persistence",
  "canonical_xapi_surface": "2.0",
  "comparison_hash_algorithm": "SHA-256",
  "compatibility_artifact_authority": "provenance_only",
  "compatibility_surfaces": ["1.0.3", "cmi5 Quartz"],
  "database_normal_form": "3NF",
  "raw_request_bytes_are_statement_comparator": false,
  "request_evidence_entity": "ingestion_receipt",
  "request_occurrence_entity": "statement_ingestion_item",
  "request_statement_index": "zero_based",
  "statement_comparison": "received_surface_statement_comparison_requirements",
  "statement_identity_key": ["tenant_key", "statement_key"],
  "tenant_reference_policy": "composite_tenant_foreign_keys_fail_closed"
}
```
<!-- lrs-bootstrap-contract:end -->

Initial entities:

- `tenant_partition`
- `ingestion_receipt`
- `statement_ingestion_item`
- `statement_record`
- `statement_actor`
- `statement_object`
- `statement_context`
- `statement_result`
- `attachment_blob`
- `statement_attachment`
- `voiding_relation`
- `activity_state_document`
- `activity_state_revision`
- `agent_profile_document`
- `agent_profile_revision`
- `activity_profile_document`
- `activity_profile_revision`
- `compatibility_artifact`
- `compatibility_transform`

The first executable migration implements `tenant_partition`, `ingestion_receipt`, `statement_ingestion_item`, `statement_record`, and `voiding_relation`. The remaining entities are planned protocol surfaces and must not be represented as implemented until migrations and tests exist.

`ingestion_receipt` owns immutable request evidence: the xAPI application entity bytes presented after HTTP content-coding removal, their 32-octet SHA-256 `request_content_hash`, `received_xapi_version`, and receipt timing/provenance. It represents one received request and is never repointed to another request or overwritten by an idempotent retry.

`statement_ingestion_item` is the tenant-scoped request-to-Statement occurrence relation. Its identity is `(tenant_key, receipt_number, request_statement_index)`, where `request_statement_index` is `0` for a single-Statement request and the zero-based array position for a POST batch. Each item records the submitted `statement_key`, comparison outcome, and—when the occurrence resolves successfully—the composite foreign key to the canonical `(tenant_key, statement_key)` in `statement_record`. An idempotent retry therefore creates a new immutable receipt and occurrence row pointing to the existing canonical Statement; it never changes the receipt provenance stored for an earlier occurrence. Rejected conflicts retain their immutable request receipt and occurrence outcome without creating or replacing a canonical Statement. A lossless parser preserves or locates the exact source byte span for each occurrence so the original batch remains auditable.

`attachment_blob` owns immutable attachment bytes and integrity metadata: `content_digest`, `media_type`, `size_bytes`, and an opaque `storage_locator`. `content_digest` is SHA-256 over the exact immutable attachment byte sequence after transport content-coding has been removed and before any MIME transcoding, text decoding, or content normalization. `statement_attachment` is only the tenant-scoped relationship between a statement and an `attachment_blob`. Deduplication and integrity checks use that exact digest and the stored byte length, never a mutable statement projection.

`compatibility_artifact` owns the immutable transformed output bytes or payload, `output_hash`, `size_bytes`, `media_type`, and an opaque `storage_locator`. `output_hash` is SHA-256 over the exact bytes retrieved from that locator, so audit and replay can retrieve and verify the same artifact. `compatibility_transform` is the tenant-scoped provenance relation from an immutable source statement payload to one `compatibility_artifact`; it stores at least `source_xapi_version`, `target_xapi_version`, `converter_version`, `validation_status`, and `provenance_reference`. The transform and its artifact never replace canonical source learning evidence.

State, Agent Profile, and Activity Profile resources expose current protocol state through their `*_document` entity while each accepted update or deletion creates an immutable `*_revision` row. Deletion closes current state but does not erase revision evidence.

The original received JSON is immutable evidence. Searchable attributes are projected into normalized relations without making the projection a substitute for the source payload.

## Statement identity and idempotency

After the protocol supplies or the LRS assigns a statement identifier, source statement identity is unique on:

```text
(tenant_key, statement_key)
```

Every accepted `statement_record` stores `received_xapi_version`, `statement_comparison_version`, and `content_hash` for replay comparison. Request provenance is not stored as a single mutable pointer on `statement_record`; every request occurrence is linked through `statement_ingestion_item`. Raw request bytes and `request_content_hash` are evidence only; they are not the equality comparator for an individual Statement.

The comparison representation is constructed independently for each parsed Statement according to the **Statement Comparison Requirements of the received xAPI surface**. The parser is lossless for scalar lexemes and rejects duplicate object properties. Object-member occurrence order and insignificant JSON whitespace do not distinguish Statements. Scalar and property serializations remain distinct unless the applicable xAPI Statement immutability/comparison rules explicitly permit the difference. Arrays retain order unless the applicable standard defines that collection as unordered; only those explicitly unordered collections are canonicalized for comparison. LRS-assigned or mutable presentation fields are ignored or normalized only where that received xAPI version permits it. This prevents a generic JSON canonicalizer from silently making two xAPI Statements equivalent when the protocol does not.

`statement_comparison_version` identifies the exact internal, version-aware comparison algorithm. `content_hash` is the raw 32-octet SHA-256 digest over the deterministic comparison representation used by the executable kernel and PostgreSQL schema. The hash is an indexed equality candidate, not the sole authority: equality is confirmed by identical comparison-algorithm version and retained comparison bytes, preventing a digest collision from becoming semantic authority.

Ingestion validates a complete POST batch before canonical persistence and applies the applicable xAPI surface plus the repository's explicitly documented fail-closed duplicate policy. It persists immutable request/occurrence provenance separately, then acquires the `(tenant_key, statement_key)` identity atomically before inserting or resolving each canonical Statement. If no row exists and validation succeeds, the source record is inserted once and the occurrence points to it. If a row exists, an exact retry requires the same received xAPI version, the same comparison-algorithm version, the same digest, and matching retained comparison bytes; the new occurrence points to that existing row. A version or comparator mismatch is handled fail closed without inserting or overwriting a second canonical row, while rejected request evidence remains immutable. Compatibility transformations remain separate provenance-linked records and do not participate in source statement identity.
