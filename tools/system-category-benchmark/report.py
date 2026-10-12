"""Render results/*.json, the corpus manifest and annotator agreement as results/tables.md."""

import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path

import corpus

ROOT = Path(__file__).parent
RESULTS = ROOT / "results"
CATEGORIES = corpus.CATEGORIES
SLICES = ["all", "en/real-random", "en/real-enriched", "en/synthetic", "cs/synthetic"]
ORDER = ["rules", "tfidf", "deberta-xsmall", "deberta-small", "deberta-mdeberta"]
INPUT_ORDER = ["minimized", "body", "body128", "body256", "body512"]
PRIMARY_SEED = 828


def number(value, digits=2):
    return "–" if value is None else f"{value:.{digits}f}"


def runs() -> list[dict]:
    results = [json.loads(path.read_text()) for path in RESULTS.glob("*.json")]

    def key(result):
        family = next(i for i, prefix in enumerate(ORDER) if result["run"].startswith(prefix))
        return family, INPUT_ORDER.index(result["input"]), result.get("seed", PRIMARY_SEED)

    return sorted(results, key=key)


def corpus_table() -> list[str]:
    counts = json.loads((corpus.MANIFEST).read_text())["counts"]
    lines = [
        "| Slice | Split | Messages | "
        + " | ".join(CATEGORIES)
        + " | Uncategorized | Multi-label |",
        "| --- | --- | ---: | " + " | ".join("---:" for _ in CATEGORIES) + " | ---: | ---: |",
    ]
    for slice_ in SLICES[1:]:
        for split in ("train", "validation", "test"):
            prefix = f"{slice_}/{split}/"
            values = [
                counts.get(prefix + c, 0)
                for c in ["messages", *CATEGORIES, "uncategorized", "multi-label"]
            ]
            lines.append(f"| {slice_} | {split} | " + " | ".join(str(v) for v in values) + " |")
    return lines


def summary_table(results: list[dict]) -> list[str]:
    lines = [
        "| Run | " + " | ".join(SLICES) + " | Train time (s) | Peak MPS memory (MiB) |",
        "| --- | " + " | ".join("---" for _ in SLICES) + " | ---: | ---: |",
    ]
    for result in results:
        cells = []
        for slice_ in SLICES:
            metrics = result["slices"].get(slice_)
            if metrics is None or metrics["macro_f1"] is None:
                cells.append("–")
                continue
            low, high = metrics["macro_f1_ci95"]
            cells.append(f"{metrics['macro_f1']:.2f} ({low:.2f}–{high:.2f})")
        lines.append(
            f"| {result['run']} | "
            + " | ".join(cells)
            + f" | {result.get('train_seconds', '–')} | {result.get('peak_device_memory_mib') or '–'} |"
        )
    return lines


def supported_table(results: list[dict], minimum: int = 5) -> list[str]:
    lines = [
        "| Run | " + " | ".join(SLICES) + " |",
        "| --- | " + " | ".join("---" for _ in SLICES) + " |",
    ]
    for result in results:
        cells = []
        for slice_ in SLICES:
            per_category = result["slices"][slice_]["per_category"].values()
            scores = [c["f1"] for c in per_category if c["support"] >= minimum]
            cells.append(f"{statistics.mean(scores):.2f} ({len(scores)})" if scores else "–")
        lines.append(f"| {result['run']} | " + " | ".join(cells) + " |")
    return lines


def category_table(results: list[dict], slice_: str) -> list[str]:
    lines = [
        f"Slice `{slice_}`, precision / recall per category (support in the header).",
        "",
    ]
    first = next(r for r in results if slice_ in r["slices"])["slices"][slice_]
    header = [f"{c} ({first['per_category'][c]['support']})" for c in CATEGORIES]
    lines += [
        "| Run | "
        + " | ".join(header)
        + " | Coverage (gold) | Uncat. P / R | Overlap errors | People FP (on uncat.) |",
        "| --- | " + " | ".join("---" for _ in CATEGORIES) + " | --- | --- | --- | --- |",
    ]
    for result in results:
        metrics = result["slices"].get(slice_)
        if metrics is None:
            continue
        cells = [
            f"{number(metrics['per_category'][c]['precision'])} / {number(metrics['per_category'][c]['recall'])}"
            for c in CATEGORIES
        ]
        lines.append(
            f"| {result['run']} | "
            + " | ".join(cells)
            + f" | {metrics['coverage']:.2f} ({metrics['gold_coverage']:.2f})"
            + f" | {metrics['uncategorized_precision']:.2f} / {metrics['uncategorized_recall']:.2f}"
            + f" | {metrics['overlap_errors']}/{metrics['overlap_messages']}"
            + f" | {metrics['people_false_positives']} ({metrics['people_false_positives_on_uncategorized']}) |"
        )
    return lines


def seed_table(results: list[dict]) -> list[str]:
    groups = defaultdict(list)
    for result in results:
        if "seed" in result:
            groups[result["run"].split("-seed")[0]].append(result)
    lines = [
        "| Run | Seeds | " + " | ".join(SLICES) + " |",
        "| --- | --- | " + " | ".join("---" for _ in SLICES) + " |",
    ]
    for run, group in groups.items():
        if len(group) < 2:
            continue
        cells = []
        for slice_ in SLICES:
            values = [r["slices"][slice_]["macro_f1"] for r in group]
            cells.append(f"{statistics.mean(values):.2f} ({min(values):.2f}–{max(values):.2f})")
        seeds = ", ".join(str(r["seed"]) for r in group)
        lines.append(f"| {run} | {seeds} | " + " | ".join(cells) + " |")
    return lines


def failure_table(results: list[dict]) -> list[str]:
    lines = [
        "| Run | Slice | Gold → predicted | Count | Synthetic subject or public ID |",
        "| --- | --- | --- | ---: | --- |",
    ]
    for result in results:
        if result["input"] != "minimized" or result["method"] == "rules":
            continue
        patterns = Counter()
        examples = {}
        for error in result["errors"]:
            key = (
                error["slice"],
                " + ".join(error["gold"]) or "Uncategorized",
                " + ".join(error["predicted"]) or "Uncategorized",
            )
            patterns[key] += 1
            examples.setdefault(
                key, " ".join(error.get("subject", error["id"]).split()).replace("|", "/")
            )
        for (slice_, gold, predicted), count in patterns.most_common(6):
            example = examples[(slice_, gold, predicted)]
            lines.append(
                f"| {result['run']} | {slice_} | {gold} → {predicted} | {count} | {example} |"
            )
    return lines


def kappa(a: list[bool], b: list[bool]) -> float | None:
    n = len(a)
    observed = sum(x == y for x, y in zip(a, b)) / n
    pa, pb = sum(a) / n, sum(b) / n
    expected = pa * pb + (1 - pa) * (1 - pb)
    return None if expected == 1 else (observed - expected) / (1 - expected)


def agreement_table() -> list[str]:
    def load(path):
        return {e["id"]: e for e in map(json.loads, path.read_text().splitlines())}

    primary = load(corpus.LABELS)
    second = load(ROOT / "corpus" / "labels-agreement-v1.jsonl")
    both = [i for i in second if not primary[i]["exclude"] and not second[i]["exclude"]]
    excluded = sum(primary[i]["exclude"] != second[i]["exclude"] for i in second)
    exact = sum(set(primary[i]["labels"]) == set(second[i]["labels"]) for i in both) / len(both)
    lines = [
        (
            f"{len(second)} randomly chosen real-public messages were labelled again by "
            f"{next(iter(second.values()))['annotator']}. On the {len(both)} both kept, the label sets "
            f"agree exactly for {exact:.2f}; the exclusion decision differs for {excluded} of {len(second)}."
        ),
        "",
        "| Category | Primary positives | Second positives | Both | Cohen's kappa |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for category in CATEGORIES:
        a = [category in primary[i]["labels"] for i in both]
        b = [category in second[i]["labels"] for i in both]
        lines.append(
            f"| {category} | {sum(a)} | {sum(b)} | {sum(x and y for x, y in zip(a, b))} | {number(kappa(a, b))} |"
        )
    return lines


def main() -> None:
    every_run = runs()
    results = [r for r in every_run if r.get("seed", PRIMARY_SEED) == PRIMARY_SEED]
    sections = [
        "# Generated tables",
        "",
        f"Generated by `uv run python report.py` from `results/*.json` and `corpus/{corpus.MANIFEST.name}`.",
        "Real-public labels are agent annotations, so real-public scores measure agreement with",
        "those labels, not verified real-world accuracy.",
        "",
        f"## Corpus {corpus.CORPUS_VERSION}",
        "",
        *corpus_table(),
        "",
        "## Annotator agreement",
        "",
        *agreement_table(),
        "",
        "## Macro-F1 by slice (95% bootstrap interval)",
        "",
        "Macro-F1 averages the categories with test support in that slice.",
        "",
        *summary_table(results),
        "",
        "## Macro-F1 over categories with at least 5 test messages",
        "",
        "A category with one or two test messages moves macro-F1 by up to 0.25 per message;",
        "this view drops such categories (the number of categories kept is in parentheses).",
        "",
        *supported_table(results),
        "",
        "## Seed variation",
        "",
        "Mean macro-F1 (min–max) across training seeds; the tables above use seed 828.",
        "",
        *seed_table(every_run),
        "",
        "## Most frequent test errors (minimized input)",
        "",
        *failure_table(results),
    ]
    for slice_ in SLICES:
        sections += ["", f"## Per-category results: {slice_}", "", *category_table(results, slice_)]
    (RESULTS / "tables.md").write_text("\n".join(sections) + "\n")
    print(f"wrote {len(every_run)} runs to results/tables.md")


if __name__ == "__main__":
    main()
