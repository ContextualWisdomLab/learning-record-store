from pathlib import Path


workflow = Path(".github/workflows/quality.yml").read_text(encoding="utf-8")

pull_request_block = workflow.split("  pull_request:", 1)[1].split("  push:", 1)[0]
assert "branches:" not in pull_request_block
assert "${{ github.workflow }}-${{ github.repository }}-" in workflow
assert "github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id" in workflow
assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in workflow
assert '"--json"' in workflow
assert '"--output-path"' in workflow
assert 'line_total["covered"] != line_total["count"]' in workflow
