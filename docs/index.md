# Learning Record Store

Learning Record Store is the ContextualWisdomLab persistence boundary for durable learning evidence. It is being built to validate, preserve, and query xAPI statements, document resources, attachments, and voiding relationships while keeping tenant boundaries and received evidence explicit.

## Product responsibility

This repository owns learning-record persistence and retrieval. xAPI 2.0 is the canonical target; xAPI 1.0.3 compatibility is limited to the explicit cmi5 Quartz boundary. The service does not own enrollment, learner-completion policy, authored course content, psychometric response data, or billing state.

The repository is still pre-release. Documentation and active pull requests describe reviewed design and implementation work, but no production endpoint, package, hosted service, or standards-conformance certification is advertised from this page.

## Start here

- [Repository README](../README.md) — product scope and repository status.
- [Architecture](ARCHITECTURE.md) — bounded context and system structure.
- [Data model](DATA_MODEL.md) — normalized learning-evidence model and invariants.
- [Product and technical gap baseline](product-technical-gap-baseline.md) — current gaps and evidence required for commercialization.
- [Architecture decisions](adr/) — reviewed decisions and rejected alternatives.
- [Research and standards evidence](doctoring/) — normative references and traceability.
- [Changelog](../CHANGELOG.md) — repository-visible changes.
- [GitHub Releases](https://github.com/ContextualWisdomLab/learning-record-store/releases) — future versioned release artifacts when they exist.
- [Ask DeepWiki](https://deepwiki.com/ContextualWisdomLab/learning-record-store) — repository-aware questions and navigation.

## Architecture and evidence boundary

Learning records are treated as durable evidence rather than mutable application state. Canonical records, replay/conflict evidence, voiding relationships, and compatibility transformations must remain distinguishable so downstream learning products can reason about provenance without rewriting the received history.

Cross-product integration should use reviewed contracts instead of reading another product's application tables directly. Shared learning interoperability contracts belong in `learning-interoperability-contracts`; LMS, content-studio, and learning-record-store runtime responsibilities remain separate bounded contexts.

## Security and operations

Tenant isolation, authenticated and authorized access, immutable evidence preservation, reproducible standards validation, recovery, and auditable release provenance are required before production-readiness claims. Active design or source work is not treated as deployed evidence until protected integration and exact-head verification succeed.

## Publication status

This file is a GitHub Pages source prerequisite, not proof that Pages is live. Publication is complete only after the source reaches the protected default branch, the organization-owned repository metadata reconciler enables the reviewed Pages configuration, deployment succeeds, and the public HTTPS content is re-read successfully.
