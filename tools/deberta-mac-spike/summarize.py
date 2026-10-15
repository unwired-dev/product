"""Tabulate the Mac host's categorization-spike evidence (one JSON object per line)."""

import argparse
import json
from pathlib import Path

NAMES = {
    "deberta-xsmall-body256": "System XSmall",
    "deberta-mdeberta-body512": "System mDeBERTa",
    "xsmall-zs-adapted-body256-description": "Custom XSmall",
    "mdeberta-nli-adapted-body256-description": "Custom mDeBERTa",
}


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
    arguments = parser.parse_args()
    lines = [json.loads(line) for line in arguments.evidence.read_text().splitlines() if line]
    print(summarize(lines), end="")
