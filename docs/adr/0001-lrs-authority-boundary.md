# ADR 0001: Learning record authority boundary

## Status

Proposed

## Decision

The Learning Record Store is the authoritative CWL service for received xAPI learning records, xAPI document resources, attachments, and their integrity metadata. Enrollment, completion policy, authored content, and assessment response ownership remain outside this repository.

## Consequences

LMS progress views are projections from LRS evidence rather than a second learning-event ledger. Historical received payloads remain immutable, and compatibility conversions are explicit artifacts with provenance.
