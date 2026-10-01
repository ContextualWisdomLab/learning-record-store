"""Regression contract for reproducible Rust dependency resolution in CI."""

from pathlib import Path
import subprocess
import unittest


class CargoLockContractTests(unittest.TestCase):
    """Keep the service lockfile tracked and every CI Cargo build fail-closed."""

    def test_service_lockfile_is_tracked(self) -> None:
        """A service build must not regenerate dependency resolution implicitly."""
        tracked = subprocess.run(
            ["git", "ls-files", "--error-unmatch", "Cargo.lock"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(tracked.returncode, 0, tracked.stderr)

    def test_ci_cargo_commands_use_locked_resolution(self) -> None:
        """All repository build gates must reject lockfile drift."""
        workflow = Path(".github/workflows/quality.yml").read_text(encoding="utf-8")
        required_commands = (
            "cargo test --all-targets --locked",
            "cargo clippy --all-targets --locked -- -D warnings",
            "cargo doc --no-deps --locked",
            "cargo llvm-cov --all-targets --locked",
        )
        for command in required_commands:
            with self.subTest(command=command):
                self.assertIn(command, workflow)


if __name__ == "__main__":
    unittest.main()
