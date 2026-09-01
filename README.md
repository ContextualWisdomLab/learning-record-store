# Learning Record Store

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/ContextualWisdomLab/learning-record-store)

Authoritative xAPI learning-record persistence for the CWL Learning Platform.

## Scope

The service will validate, store, query, and preserve xAPI statements, xAPI document resources, and attachments with tenant isolation and reproducible conformance evidence.

xAPI 2.0 is the canonical target. xAPI 1.0.3 is supported only through an explicit compatibility surface required by cmi5 Quartz; received historical payloads are never silently rewritten.

The repository does not own course enrollment, learner completion policy, authored content, psychometric response data, or billing state.

## Branching

Product work targets `develop`; release promotion to `main` occurs only after exact-head review and required checks.

See `docs/ARCHITECTURE.md`, `docs/DATA_MODEL.md`, and `docs/doctoring/REFERENCES.md`.
