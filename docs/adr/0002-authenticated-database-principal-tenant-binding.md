# ADR 0002: Bind tenant authorization to authenticated database principals

- Status: Accepted
- Date: 2026-09-02
- Scope: PostgreSQL tenant authorization and immutable evidence writes

## Context

The initial persistence bootstrap used a caller-selected `app.tenant_key` session setting in forced row-level-security policies and a `SECURITY INVOKER` ingestion function. That proves tenant-scoped schema mechanics but is not an authentication boundary: any application session allowed to set the custom GUC can select a different tenant context. The same invoker model also requires direct INSERT privileges on immutable evidence tables, allowing callers to bypass digest derivation and replay/conflict controls in `persist_statement_occurrence`.

PostgreSQL distinguishes `session_user`, the principal that established the connection, from `current_user`, which changes under `SET ROLE` and `SECURITY DEFINER`. PostgreSQL row-security guidance applies policy expressions to both visible and newly written rows, and OWASP authorization guidance recommends least privilege, deny-by-default behavior, validation on every request, and integration tests for authorization logic.

## Decision

Tenant authorization at the relational boundary is derived from an administrator-controlled `tenant_database_principal` mapping keyed by PostgreSQL `session_user`. A caller-provided tenant value or custom session GUC is never an authorization source.

`authorized_tenant_key()` is a parameterless, fixed-search-path `SECURITY DEFINER` function whose owner has only the SELECT privilege required to read the principal mapping. Existing forced RLS policies compare each row's `tenant_key` with that authenticated mapping. An unmapped session therefore receives no tenant authorization.

Immutable evidence writes pass through `persist_statement_occurrence`, which becomes a fixed-search-path `SECURITY DEFINER` function owned by the constrained, `NOLOGIN`, `NOSUPERUSER`, `NOBYPASSRLS` role `lrs_evidence_writer`. That owner is not a table owner and receives only the table/sequence privileges needed by the transaction primitive. The function still executes under forced RLS; policy evaluation is bound to the original `session_user`. Data-plane tenant principals receive function EXECUTE and read privileges required by their API path, not direct INSERT/UPDATE/DELETE privileges on immutable evidence tables.

The current high-assurance boundary maps one authenticated database principal to one tenant. A future multiplexed connection-pool design may replace this with another externally authenticated binding only if the data-plane caller cannot forge or retarget that binding; it must not fall back to a freely writable custom GUC.

## Consequences

- Setting `app.tenant_key` no longer changes authorization after migration 0002.
- Cross-tenant writes fail both at the function's authenticated-principal check and at forced RLS.
- Direct immutable-evidence fabrication is outside the normal application privilege set.
- Migration/administrative principals remain separate from data-plane credentials.
- `session_user` is appropriate here precisely because `current_user` changes inside `SECURITY DEFINER`; tests must preserve this distinction.
- Role-to-tenant provisioning becomes a control-plane operation and must be audited in deployment automation before production use.
- Shared/multiplexed database credentials are not supported by this initial tenant-authentication contract.

## Verification

`tests/postgres_principal_boundary.sh` proves that a tenant principal cannot retarget authorization by changing `app.tenant_key`, cannot directly insert canonical evidence, can ingest its own tenant through the controlled function, cannot claim another tenant, cannot read another tenant's canonical evidence, and that the function owner is constrained and lacks `BYPASSRLS`.

Exact-head GitHub Checks remain the execution evidence. This ADR does not claim deployment authentication, secret rotation, SOC 2 readiness, or CSAP compliance before those controls are implemented and verified.

## References

OWASP Foundation. (2026). *Authorization cheat sheet*. OWASP Cheat Sheet Series. https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html

PostgreSQL Global Development Group. (2026). *PostgreSQL 18 documentation: System information functions and operators*. https://www.postgresql.org/docs/current/functions-info.html

PostgreSQL Global Development Group. (2026). *PostgreSQL 17 documentation: Row security policies*. https://www.postgresql.org/docs/17/ddl-rowsecurity.html
