"""Evidence summaries must accept the lifecycle records emitted by the native bridge."""

import json
from pathlib import Path

from summarize import summarize


def test_mixed_results_cancellations_and_releases():
    matrix = Path(__file__).parent / "results/host-matrix-2026-10-15.jsonl"
    results = [json.loads(line) for line in matrix.read_text().splitlines()]
    lifecycle = [
        {"request": "benchmark-1", "error": "cancelled"},
        {"release": {"footprintBeforeMB": 402, "footprintAfterMB": 137}},
    ]

    summary = summarize([*results, *lifecycle])

    assert summary.startswith(summarize(results))
    assert "## Cancellations and releases" in summary
    for entry in lifecycle:
        assert f"- `{json.dumps(entry, sort_keys=True)}`" in summary
