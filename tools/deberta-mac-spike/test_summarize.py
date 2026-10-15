"""Evidence summaries must accept the lifecycle records emitted by the native bridge."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

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


@pytest.mark.parametrize("change", ["none", "failed", "duplicate", "missing"])
def test_matrix_command_requires_every_successful_action(tmp_path: Path, change: str):
    root = Path(__file__).parent
    results = [
        json.loads(line)
        for line in (root / "results/host-matrix-2026-10-15.jsonl").read_text().splitlines()
    ]
    if change == "failed":
        results[0] = {"request": "golden-1", "error": "failed"}
    elif change == "duplicate":
        results[0] = results[1]
    elif change == "missing":
        results.pop()
    evidence = tmp_path / "evidence.jsonl"
    evidence.write_text("\n".join(json.dumps(entry) for entry in results))

    checked = subprocess.run(
        [sys.executable, str(root / "summarize.py"), "--check-matrix", str(evidence)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert (checked.returncode == 0) == (change == "none"), checked.stderr
    if change == "none":
        assert "## Golden parity in the host" in checked.stdout


@pytest.mark.parametrize("failed", [False, True])
def test_states_command_allows_cancellation_but_rejects_failed_samples(
    tmp_path: Path, failed: bool
):
    root = Path(__file__).parent
    matrix = [
        json.loads(line)
        for line in (root / "results/host-matrix-2026-10-15.jsonl").read_text().splitlines()
    ]
    custom = next(
        entry
        for entry in matrix
        if "classification" in entry
        and entry["request"]["run"] == "xsmall-zs-adapted-body256-description"
        and entry["request"]["precision"] == "int8"
    )
    results = [matrix[1], custom]
    results[1]["request"]["units"] = "cpuAndNeuralEngine"
    results[1]["classification"]["categories"] = []
    if failed:
        results[0] = {"request": "classify-1", "error": "failed"}
    for request in ("benchmark-3", "benchmark-4"):
        results.extend(
            [{"request": request, "error": "cancelled"}, {"release": {"footprintAfterMB": 137}}]
        )
    evidence = tmp_path / "states.jsonl"
    evidence.write_text("\n".join(json.dumps(entry) for entry in results))

    checked = subprocess.run(
        [sys.executable, str(root / "summarize.py"), "--check-states", str(evidence)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert (checked.returncode == 0) == (not failed), checked.stderr
