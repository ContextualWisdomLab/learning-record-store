# ADR 0001: Learning record authority boundary

## Status

Accepted

Approved by: ContextualWisdomLab repository owner  
Approval date: 2026-08-19

## Decision

The Learning Record Store is the authoritative CWL service for received xAPI statement evidence, xAPI document resources, attachment bytes and integrity metadata, and explicit compatibility-transformation artifacts. Enrollment, completion policy, authored content, and assessment response ownership remain outside this repository.

Statement evidence is append-only except where xAPI itself defines a semantic mechanism such as voiding; the original received payload is never rewritten. State, Agent Profile, and Activity Profile resources are mutable protocol resources, so the LRS preserves their current protocol state **and** immutable revision evidence for each accepted update or deletion. A document deletion closes the current state while retaining the prior revision chain, request identity, protocol version, content hash, and provenance needed for replay and audit.

## Consequences

LMS progress views are projections from LRS evidence rather than a second learning-event ledger. Historical received statement payloads remain immutable. Document-resource reads return the current protocol state while audit/replay APIs operate on immutable revisions. Repeated same-content operations are idempotent; conflicting replays fail closed. Compatibility conversions are explicit artifacts linking source payload, source and target xAPI versions, converter version, validation result, output hash, and provenance.
