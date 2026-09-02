# ADR 0001: Learning record authority boundary

## Status

Accepted

Approved by: ContextualWisdomLab repository owner  
Approval date: 2026-08-19

## Decision

The Learning Record Store is the authoritative CWL service for received xAPI statement evidence, xAPI document resources, attachment bytes, and their integrity metadata. Enrollment, completion policy, authored content, and assessment response ownership remain outside this repository. Compatibility transformation artifacts are retained by the LRS as provenance and audit records, but they are not canonical learning evidence and never replace the received source evidence.

Statement evidence is append-only except where xAPI itself defines a semantic mechanism such as voiding; the original received payload is never rewritten. State, Agent Profile, and Activity Profile resources are mutable protocol resources, so the LRS preserves their current protocol state **and** immutable revision evidence for each accepted state-changing update or deletion. A document deletion closes the current state while retaining the prior revision chain, request identity, protocol version, content hash, and provenance needed for replay and audit.

## Consequences

LMS progress views are projections from LRS evidence rather than a second learning-event ledger. Historical received statement payloads remain immutable. Document-resource reads return the current protocol state while audit/replay APIs operate on immutable revisions. Repeating an operation whose accepted document representation and deletion state are already current is idempotent: it does not create a duplicate document revision, although its request receipt remains immutable evidence. A new immutable document revision is created only when an accepted operation changes the current representation or transitions the resource into or out of the deleted state. Conflicting conditional replays fail closed. Compatibility conversions remain explicit provenance records linking source payload, source and target xAPI versions, converter version, validation result, a retrievable immutable transformed artifact, its output hash, and provenance identity.
