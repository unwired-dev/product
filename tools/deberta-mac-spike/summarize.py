"""Tabulate the Mac host's categorization-spike evidence (one JSON object per line)."""

import argparse
import json
from collections import Counter
from pathlib import Path

NAMES = {
    "deberta-xsmall-body256": "System XSmall",
    "deberta-mdeberta-body512": "System mDeBERTa",
    "xsmall-zs-adapted-body256-description": "Custom XSmall",
    "mdeberta-nli-adapted-body256-description": "Custom mDeBERTa",
}


def check_matrix(lines: list[dict]) -> None:
    """Require the successful actions scheduled by the page's autorunMatrix."""
    expected = []
    for run in NAMES:
        counts = [5, 20, 50] if "adapted" in run else [0]
        for precision in ("fp16", "int8"):
            for kind in ("golden", "classification"):
                expected.append((run, precision, "all", kind, 0))
            expected.extend((run, precision, "all", "passMs", count) for count in counts)
        expected.extend((run, "fp16", unit, "plan", 0) for unit in ("all", "cpuAndNeuralEngine"))
    expected.extend(
        ("deberta-xsmall-body256", "fp16", unit, "passMs", 0)
        for unit in ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine")
    )
    actual = []
    for entry in lines:
        request = entry.get("request")
        kinds = [kind for kind in ("golden", "classification", "passMs", "plan") if kind in entry]
        if "error" in entry or not isinstance(request, dict) or len(kinds) != 1:
            raise SystemExit("Matrix contains a failed or unexpected action record")
        actual.append(
            (
                request.get("run"),
                request.get("precision"),
                request.get("units"),
                kinds[0],
                entry.get("categoryCount", 0),
            )
        )
    if Counter(actual) != Counter(expected):
        raise SystemExit("Matrix is incomplete or contains duplicate/unexpected actions")


def check_states(lines: list[dict]) -> None:
    """Require two displayed samples and the two intentional cancellations/releases."""
    expected = [
        {"run": "deberta-xsmall-body256", "precision": "fp16", "units": "all"},
        {
            "run": "xsmall-zs-adapted-body256-description",
            "precision": "int8",
            "units": "cpuAndNeuralEngine",
        },
    ]
    classifications = [
        entry for entry in lines if "classification" in entry and "error" not in entry
    ]
    if (
        len(lines) != 6
        or [entry.get("request") for entry in classifications] != expected
        or classifications[1]["classification"].get("categories") != []
        or sum(entry.get("error") == "cancelled" for entry in lines) != 2
        or sum("release" in entry for entry in lines) != 2
    ):
        raise SystemExit("States run is missing sample results, cancellations or releases")


def row(cells) -> str:
    return "| " + " | ".join(str(cell) for cell in cells) + " |"


def table(header, rows) -> list[str]:
    return [row(header), row(["---"] * len(header)), *map(row, rows)]


def summarize(lines: list[dict]) -> str:
    golden, benchmark, plans, other = [], [], [], []
    for entry in lines:
        request = entry.get("request")
        if not isinstance(request, dict):
            other.append(entry)
            continue
        name = NAMES.get(request.get("run"), request.get("run"))
        process = entry["process"]
        label = [name, request["precision"].upper(), request["units"]]
        if "golden" in entry:
            report = entry["golden"]
            golden.append(
                [
                    *label,
                    report["checked"],
                    len(report["tokenMismatches"]),
                    f"{report['maxAbsProbabilityDifference']:.4f}",
                    "; ".join(report["decisionChanges"]) or "none",
                    f"{entry['loadMs']:.0f}" if "loadMs" in entry else "warm",
                ]
            )
        elif "passMs" in entry:
            benchmark.append(
                [
                    *label,
                    entry["categoryCount"] or "–",
                    entry["passes"],
                    f"{entry['passMs']['p50']:.1f}",
                    f"{entry['passMs']['p95']:.1f}",
                    f"{entry['messagesPerSecond']:.2f}",
                    f"{process['peakFootprintMB']:.0f}",
                    f"{process['energyMillijoules'] / entry['passes']:.0f}",
                    f"{process['mainThreadLagMs']['p95']:.2f}",
                    f"{process['thermalBefore']} → {process['thermalAfter']}",
                ]
            )
        elif "plan" in entry:
            plan = entry["plan"]
            plans.append(
                [
                    *label,
                    ", ".join(f"{k} {v}" for k, v in sorted(plan["preferred"].items())),
                    ", ".join(f"{k} {v}" for k, v in sorted(plan["withoutNeuralEngine"].items()))
                    or "none",
                ]
            )
    out = ["## Golden parity in the host", ""]
    out += table(
        [
            "Candidate",
            "Precision",
            "Units",
            "Checked",
            "Token mismatches",
            "Max abs Δp",
            "Decision changes",
            "Load ms",
        ],
        golden,
    )
    out += ["", "## Benchmarks (3 rounds of 12 samples)", ""]
    out += table(
        [
            "Candidate",
            "Precision",
            "Units",
            "Custom Categories",
            "Passes",
            "Pass p50 ms",
            "Pass p95 ms",
            "Messages/s",
            "Peak MB",
            "CPU mJ/pass",
            "Main thread p95 ms",
            "Thermal",
        ],
        benchmark,
    )
    out += ["", "## Compute plans", ""]
    out += table(
        ["Candidate", "Precision", "Units", "Preferred device (ops)", "No Neural Engine (ops)"],
        plans,
    )
    if other:
        out += ["", "## Cancellations and releases", ""]
        out += [f"- `{json.dumps(entry, sort_keys=True)}`" for entry in other]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    checks = parser.add_mutually_exclusive_group()
    checks.add_argument(
        "--check-matrix", action="store_true", help="require all 43 successful actions"
    )
    checks.add_argument(
        "--check-states", action="store_true", help="require the six lifecycle records"
    )
    arguments = parser.parse_args()
    lines = [json.loads(line) for line in arguments.evidence.read_text().splitlines() if line]
    if arguments.check_matrix:
        check_matrix(lines)
    if arguments.check_states:
        check_states(lines)
    print(summarize(lines), end="")
