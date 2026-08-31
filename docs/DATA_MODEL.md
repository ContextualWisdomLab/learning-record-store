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
- `compatibility_artifact`
- `compatibility_transform`
- `ingestion_receipt`

`attachment_blob` owns immutable attachment bytes and integrity metadata: `content_digest`, `media_type`, `size_bytes`, and an opaque `storage_locator`. `content_digest` is SHA-256 over the exact immutable attachment byte sequence after transport content-coding has been removed and before any MIME transcoding, text decoding, or content normalization; it is stored as 64 lowercase hexadecimal characters. `statement_attachment` is only the tenant-scoped relationship between a statement and an `attachment_blob`. Deduplication and integrity checks use that exact digest and the stored byte length, never a mutable statement projection.

`compatibility_artifact` owns the immutable transformed output bytes or payload, `output_hash`, `size_bytes`, `media_type`, and an opaque `storage_locator`. `output_hash` is SHA-256 over the exact bytes retrieved from that locator and is stored as 64 lowercase hexadecimal characters, so audit and replay can retrieve and verify the same artifact. `compatibility_transform` is the tenant-scoped provenance relation from an immutable source statement payload to one `compatibility_artifact`; it stores at least `source_xapi_version`, `target_xapi_version`, `converter_version`, `validation_status`, and `provenance_reference`. The transform and its artifact never replace canonical source learning evidence.

State, Agent Profile, and Activity Profile resources expose current protocol state through their `*_document` entity while each accepted update or deletion creates an immutable `*_revision` row. Deletion closes current state but does not erase revision evidence.

The original received JSON is immutable evidence. Searchable attributes are projected into normalized relations without making the projection a substitute for the source payload.

## Statement identity and idempotency

After the protocol supplies or the LRS assigns a statement ID, source statement identity is unique on:

```text
(tenant_id, statement_id)
```

Every accepted `statement_record` also stores `received_xapi_version` and `content_hash` for replay comparison. `content_hash` is SHA-256 over the exact immutable UTF-8 request entity bytes after HTTP content-coding has been removed and before JSON parsing or re-serialization; it is stored as 64 lowercase hexadecimal characters. No whitespace, object-key-order, numeric, or Unicode normalization is applied to those retained source bytes. This intentionally conservative byte identity keeps the content comparison reproducible from retained evidence.

Ingestion acquires the `(tenant_id, statement_id)` identity atomically before insertion. If no row exists, the source record is inserted once. If a row exists and both `received_xapi_version` and `content_hash` match, the operation returns the existing accepted result idempotently. Any version or content mismatch for the same tenant and statement ID is rejected atomically without inserting or overwriting a second source row. Compatibility transformations remain separate provenance-linked records and do not participate in source statement identity.
