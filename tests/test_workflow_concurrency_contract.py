from pathlib import Path


workflow = Path(".github/workflows/quality.yml").read_text(encoding="utf-8")
toolchain = Path("rust-toolchain.toml").read_text(encoding="utf-8")
migration_2 = Path("migrations/0002_database_principal_boundary.sql").read_text(
    encoding="utf-8"
)
migration_3 = Path("migrations/0003_batch_rejection_outcome.sql").read_text(
    encoding="utf-8"
)
rollback_migration = Path("migrations/rollback_statement_evidence.sql").read_text(
    encoding="utf-8"
)
rust_source = Path("src/lib.rs").read_text(encoding="utf-8")

failures: list[str] = []


def require(condition: bool, message: str) -> None:
    """Collect every contract failure so one regression cannot hide another."""
    if not condition:
        failures.append(message)


pull_request_block = workflow.split("  pull_request:", 1)[1].split("  push:", 1)[0]
require("branches:" not in pull_request_block, "stacked pull requests must trigger quality")
require(
    "${{ github.workflow }}-${{ github.repository }}-" in workflow,
    "workflow concurrency must be repository-scoped",
)
require(
    "github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id"
    in workflow,
    "pull-request concurrency must be scoped to the PR number",
)
require(
    "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in workflow,
    "only superseded pull-request runs may be cancelled",
)

# Rust test-binary/codegen instantiations can duplicate the aggregate denominator; count each
# source line once and fail when any unique source line remains uncovered.
require("--show-missing-lines" in workflow, "coverage must report missing source lines")
require("--fail-uncovered-lines 0" in workflow, "coverage must reject uncovered source lines")
require(
    "--fail-under-lines" not in workflow,
    "aggregate instance coverage must not replace the unique source-line contract",
)

# Pin the toolchain proven by exact-head run 34688409404 rather than mutable stable.
require('channel = "1.98.1"' in toolchain, "rust-toolchain.toml must pin Rust 1.98.1")
require("toolchain: 1.98.1" in workflow, "quality must install the same Rust 1.98.1")
require("toolchain: stable" not in workflow, "quality must not install mutable stable")

# Adding constraints and validating existing rows must use separate transactions.
require(
    migration_3.count("NOT VALID") == 2,
    "both replacement CHECK constraints must be added NOT VALID",
)
require(
    migration_3.count("VALIDATE CONSTRAINT") == 2,
    "both replacement CHECK constraints must be validated explicitly",
)
require(
    "COMMIT;\n\nBEGIN;" in migration_3,
    "constraint installation and validation must use separate transactions",
)

# Controlled writers need one documented, version-stable bigint lock key.
require("hashtext" not in migration_2, "controlled writers must not depend on hashtext")
require(
    "CREATE FUNCTION statement_advisory_lock_key" in migration_2,
    "migration 0002 must define the shared lock-key derivation",
)

# Rollback must establish its exclusion barrier over every removable relation before observing
# emptiness. Keep the table list explicit so removing an otherwise unexercised relation fails CI.
rollback_lock_barrier = rollback_migration.split("DO $$", 1)[0]
require(
    "LOCK TABLE" in rollback_lock_barrier
    and "IN ACCESS EXCLUSIVE MODE;" in rollback_lock_barrier,
    "rollback must establish an ACCESS EXCLUSIVE table-lock barrier",
)
for relation_name in (
    "tenant_partition",
    "tenant_database_principal",
    "ingestion_receipt",
    "statement_record",
    "statement_ingestion_item",
    "voiding_relation",
):
    require(
        relation_name in rollback_lock_barrier,
        f"rollback lock barrier must include {relation_name}",
    )

# The public error contract includes self-reference and opposite-role conflicts.
require(
    "opposite voiding role" in rust_source,
    "InvalidVoidingRelation documentation must describe opposite-role conflicts",
)

if failures:
    raise AssertionError("review contract failures:\n- " + "\n- ".join(failures))
