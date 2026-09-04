# Learning Record Store

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/ContextualWisdomLab/learning-record-store)

**Durable, tenant-scoped learning evidence for the ContextualWisdomLab learning ecosystem.**

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

The structured block above is the CI-checked repository-facing product contract for authority, protocol surface, maturity, publication and certification claims. The prose below explains that contract and must not contradict it.

Learning Record Store is the authoritative persistence boundary for xAPI learning records and xAPI document resources. It is designed so learning products can ingest, preserve, query, and verify durable learning evidence without making the LMS, content studio, psychometrics engine, or billing system duplicate that truth.

## What it owns

Learning Record Store owns:

- canonical immutable xAPI statement identity and query indexes;
- immutable request/ingestion evidence and replay/conflict records;
- State, Agent Profile, and Activity Profile document resources;
- content-addressed attachments and voiding relationships;
- explicit compatibility transformations with retained provenance;
- tenant/actor authorization boundaries; and
- executable standards-conformance evidence.

It does **not** own enrollment, learner-completion policy, authored learning content, psychometric response data, or commercial billing state.

## Evidence model

```text
learning producer
      │ received xAPI evidence
      ▼
Learning Record Store
  validate → preserve → index → query
      │
      ├─ canonical immutable statement/document identity
      ├─ request/replay/conflict provenance
      └─ explicit compatibility artifacts
      ▼
LMS / analytics / downstream learning products
```

Received history is never silently rewritten. An idempotent retry resolves to the existing canonical identity while retaining its own request occurrence evidence. Compatibility output remains a provenance-linked projection rather than becoming a second canonical learning record.

## Standards boundary

**xAPI 2.0 is the canonical target.** xAPI 1.0.3 compatibility exists only through the explicit boundary needed for cmi5 Quartz. Historical payloads remain associated with the version and evidence surface on which they were received.

Standards references are design and conformance inputs, not certification claims. See [standards traceability](docs/doctoring/STANDARD_TRACEABILITY.md) and [references](docs/doctoring/REFERENCES.md).

## Current maturity

This repository is currently a **pre-release architecture and data-contract foundation**. It does not yet advertise a production endpoint, installable package, hosted service, released artifact, customer deployment, or xAPI/cmi5 certification. The first protected implementation must prove protocol validation, tenant isolation, normalized persistence, replay semantics, authorization, conformance, recovery, and release evidence before those states are claimed.

Because no executable product is released yet, this README deliberately does not invent an install or API quickstart. The right starting point for an integrator today is the product boundary and data contract below.

## Architecture

The initial design separates protocol handling, version-aware validation, compatibility projection, ingestion evidence, canonical statement persistence, document resources, attachments, authorization, and conformance evidence into explicit responsibilities. PostgreSQL is the intended authority for normalized identities, indexes, relationships, provenance, and integrity metadata; large immutable payloads may use object storage without moving canonical identity out of the LRS boundary.

Read:

- [Architecture](docs/ARCHITECTURE.md)
- [Data model](docs/DATA_MODEL.md)
- [LRS authority ADR](docs/adr/0001-lrs-authority-boundary.md)
- [Product and technical gap baseline](docs/product-technical-gap-baseline.md)

## Integration boundary

Adjacent products integrate through reviewed contracts rather than cross-repository application-table reads. Learning Management Platform owns enrollment and completion decisions. Learning Content Studio owns authored content and immutable content releases. Shared interoperability schemas belong in `learning-interoperability-contracts`. Learning Record Store remains the durable evidence authority for the learning records it accepts.

## Security and operability

Production readiness requires tenant isolation, authenticated and authorized access, immutable evidence preservation, bounded attachments/documents, reproducible standards validation, auditability, backup/recovery evidence, and release provenance. Documentation or a passing branch-only check is not proof that those operational controls are live.

## Documentation

- [Public documentation landing](docs/index.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Data model](docs/DATA_MODEL.md)
- [Product and technical gap baseline](docs/product-technical-gap-baseline.md)
- [Architecture decisions](docs/adr/)
- [Standards and research evidence](docs/doctoring/)
- [Changelog](CHANGELOG.md)

## Contributing

Product work targets `develop`; release promotion to `main` occurs only through the repository's protected integration process with exact-head checks and review evidence. Contributors should preserve immutable received evidence, tenant-scoped identities, explicit version/compatibility semantics, and bounded-context ownership rather than copying adjacent product authority into this repository.

## License

ContextualWisdomLab original source and documentation in this repository are licensed under the [Apache License 2.0](LICENSE). Third-party dependencies, standards, datasets, generated assets, and external services retain their own terms and must satisfy ContextualWisdomLab's commercial-license intake policy before incorporation or distribution.
