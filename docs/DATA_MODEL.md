# Data model baseline

Database objects use two-or-more-word `snake_case` names and are normalized to third normal form for authoritative relational facts.

Every tenant-scoped entity owns an explicit `tenant_id`. References between tenant-scoped entities use composite foreign keys that include `tenant_id`; a same-object identifier from another tenant is never sufficient. PostgreSQL RLS or an equivalent enforced partition constraint must fail closed when a cross-tenant reference is attempted.

Initial entities:

- `tenant_partition`
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
- `compatibility_transform`
- `ingestion_receipt`

`attachment_blob` owns immutable attachment bytes and integrity metadata: `content_digest`, `media_type`, `size_bytes`, and an opaque `storage_locator`. `statement_attachment` is only the tenant-scoped relationship between a statement and an `attachment_blob`. Deduplication is content-digest based and integrity checks are performed against `attachment_blob`, never against a mutable statement projection.

`compatibility_transform` records a protocol conversion without replacing the source evidence. It links the immutable source payload to a transformed artifact and stores at least `source_xapi_version`, `target_xapi_version`, `converter_version`, `output_hash`, `validation_status`, and `provenance_reference`.

State, Agent Profile, and Activity Profile resources expose current protocol state through their `*_document` entity while each accepted update or deletion creates an immutable `*_revision` row. Deletion closes current state but does not erase revision evidence.

The original received JSON is immutable evidence. Searchable attributes are projected into normalized relations without making the projection a substitute for the source payload.

## Statement identity and idempotency

Statement ingestion computes a deterministic `content_hash` from the exact received representation after the protocol-specific canonicalization rules required by the applicable xAPI surface; the received xAPI version is recorded separately. The operational uniqueness key is:

```text
(tenant_id, statement_id, received_xapi_version, content_hash)
```

A retry with the same tenant, statement ID, received xAPI version, and content hash is handled atomically and idempotently. The same tenant and statement ID with conflicting content fails closed atomically and never overwrites the first accepted statement. Compatibility transformations do not change this source identity; they are separate provenance-linked artifacts.
