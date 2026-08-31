# Data model baseline

Database objects use two-or-more-word `snake_case` names and are normalized to third normal form for authoritative relational facts.

Every tenant-scoped entity owns an explicit `tenant_id`. References between tenant-scoped entities use composite foreign keys that include `tenant_id`; a same-object identifier from another tenant is never sufficient. PostgreSQL RLS or an equivalent enforced partition constraint must fail closed when a cross-tenant reference is attempted.

Initial entities:

- `tenant_partition`
- `ingestion_receipt`
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

`ingestion_receipt` owns immutable request evidence: the xAPI application entity bytes presented after HTTP content-coding removal, their SHA-256 `request_content_hash`, media type, `received_xapi_version`, and request/provenance identifiers. For a single-Statement request, `request_statement_index` is `0`; for a POST array, each accepted `statement_record` references the same receipt and its zero-based `request_statement_index`. A lossless parser also preserves or locates the exact source byte span for each Statement, so audit evidence remains recoverable without treating the complete POST-array body as one Statement's identity.

`attachment_blob` owns immutable attachment bytes and integrity metadata: `content_digest`, `media_type`, `size_bytes`, and an opaque `storage_locator`. `content_digest` is SHA-256 over the exact immutable attachment byte sequence after transport content-coding has been removed and before any MIME transcoding, text decoding, or content normalization; it is stored as 64 lowercase hexadecimal characters. `statement_attachment` is only the tenant-scoped relationship between a statement and an `attachment_blob`. Deduplication and integrity checks use that exact digest and the stored byte length, never a mutable statement projection.

`compatibility_artifact` owns the immutable transformed output bytes or payload, `output_hash`, `size_bytes`, `media_type`, and an opaque `storage_locator`. `output_hash` is SHA-256 over the exact bytes retrieved from that locator and is stored as 64 lowercase hexadecimal characters, so audit and replay can retrieve and verify the same artifact. `compatibility_transform` is the tenant-scoped provenance relation from an immutable source statement payload to one `compatibility_artifact`; it stores at least `source_xapi_version`, `target_xapi_version`, `converter_version`, `validation_status`, and `provenance_reference`. The transform and its artifact never replace canonical source learning evidence.

State, Agent Profile, and Activity Profile resources expose current protocol state through their `*_document` entity while each accepted update or deletion creates an immutable `*_revision` row. Deletion closes current state but does not erase revision evidence.

The original received JSON is immutable evidence. Searchable attributes are projected into normalized relations without making the projection a substitute for the source payload.

## Statement identity and idempotency

After the protocol supplies or the LRS assigns a statement ID, source statement identity is unique on:

```text
(tenant_id, statement_id)
```

Every accepted `statement_record` stores `received_xapi_version`, `statement_comparison_version`, and `content_hash` for replay comparison, plus its immutable request receipt and per-request Statement index. Raw request bytes and `request_content_hash` are evidence only; they are not the equality comparator for an individual Statement.

The comparison representation is constructed independently for each parsed Statement according to the **Statement Comparison Requirements of the received xAPI surface**. The parser is lossless for scalar lexemes and rejects duplicate object properties. Object-member occurrence order and insignificant JSON whitespace do not distinguish Statements. Scalar and property serializations remain distinct unless the applicable xAPI Statement immutability/comparison rules explicitly permit the difference. Arrays retain order unless the applicable standard defines that collection as unordered; only those explicitly unordered collections are canonicalized for comparison. LRS-assigned or mutable presentation fields are ignored or normalized only where that received xAPI version permits it. This prevents a generic JSON canonicalizer from silently making two xAPI Statements equivalent when the protocol does not.

`statement_comparison_version` identifies the exact internal, version-aware comparison algorithm. `content_hash` is SHA-256, encoded as 64 lowercase hexadecimal characters, over a deterministic UTF-8 encoding of that comparison representation. The hash is an indexed equality candidate, not the sole authority: equality is confirmed with the same versioned comparator against the retained comparison representation/source evidence.

Ingestion validates a complete POST batch before persistence and rejects duplicate Statement IDs in the same batch according to the applicable xAPI surface. It then acquires the `(tenant_id, statement_id)` identity atomically before inserting each Statement. If no row exists, the source record is inserted once. If a row exists, an exact retry requires the same received xAPI version and the version-aware Statement comparator to report a match; a matching `content_hash` may short-circuit that comparison only when `statement_comparison_version` is identical. A version mismatch or comparator mismatch is handled fail-closed without inserting or overwriting a second source row. Compatibility transformations remain separate provenance-linked records and do not participate in source statement identity.
