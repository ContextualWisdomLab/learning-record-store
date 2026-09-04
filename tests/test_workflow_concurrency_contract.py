from pathlib import Path


workflow = Path(".github/workflows/quality.yml").read_text(encoding="utf-8")

assert "${{ github.workflow }}-${{ github.repository }}-" in workflow
assert "github.event_name == 'pull_request' && github.event.pull_request.number || github.run_id" in workflow
assert "cancel-in-progress: ${{ github.event_name == 'pull_request' }}" in workflow
