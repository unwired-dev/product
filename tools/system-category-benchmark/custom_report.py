"""Frozen native candidate bundles and generated Custom Category report tables."""

import hashlib
import json
import re
from pathlib import Path

import numpy as np

import corpus
import run
from custom_benchmark import (
    CANDIDATES,
    CATEGORIES,
    CONCEPTS,
    CUSTOM,
    HYPOTHESIS,
    ROOT,
    WORK,
    hypothesis,
    load,
    messages,
    pair_ids,
    premise,
    require_current,
    sha256_file,
)

GOLDEN_CATEGORIES = [
    "online-purchases",
    "flights-booked",
    "statements",
    "kids-school",
    "event-invitations",
    "family-friends",
]


SYSTEM_RUNS = ["deberta-xsmall-body256", "deberta-mdeberta-body512"]  # spike #828 candidates


LICENSES = {
    "MoritzLaurer/deberta-v3-xsmall-zeroshot-v1.1-all-33": "MIT",
    "cross-encoder/nli-deberta-v3-xsmall": "Apache-2.0",
    "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7": "MIT",
}


def golden(*custom_runs: str) -> None:
    """Freeze the candidate bundle and reference outputs on synthetic test messages."""
    import torch
    from huggingface_hub import hf_hub_download
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    synthetic_tests = [r for r in messages() if r["split"] == "test" and r["source"] == "synthetic"]
    records = []
    for key in sorted({(r["language"], r["stratum"]) for r in synthetic_tests}):
        group = [r for r in synthetic_tests if (r["language"], r["stratum"]) == key]
        records += sorted(group, key=lambda r: hashlib.sha256(r["id"].encode()).hexdigest())[:3]
    fields = ("id", "language", "from", "reply_to", "list", "recipients", "subject", "body")
    golden = {"messages": [{k: r[k] for k in fields} for r in records], "custom": [], "system": []}
    bundle = {"custom": [], "system": []}
    for name in custom_runs:
        result = json.loads((CUSTOM / "results" / f"{name}.json").read_text())
        require_current(result, name, labeled=True, weights=True)
        candidate = result["candidate"].removesuffix("-adapted")
        model_name, revision = CANDIDATES[candidate]
        source = WORK / "custom-adapted" / candidate if result["adapted"] else None
        if source:
            require_current(
                json.loads((source / "adaptation.json").read_text()), str(source), weights=True
            )
        tokenizer, model, device, entail, negative = load(
            str(source) if source else model_name, None if source else revision
        )
        model.eval()
        weights = (
            source / "model.safetensors"
            if source
            else Path(hf_hub_download(model_name, "model.safetensors", revision=revision))
        )
        outputs = []
        for record in records:
            text = premise(record, result["input"])
            for concept in GOLDEN_CATEGORIES:
                category = CATEGORIES[CONCEPTS.index(concept)]
                h = hypothesis(category, record["language"], result["mode"])
                ids = pair_ids(
                    tokenizer,
                    tokenizer(text, add_special_tokens=False)["input_ids"],
                    tokenizer(h, add_special_tokens=False)["input_ids"],
                    result["max_length"],
                )
                reference = tokenizer(
                    text, h, truncation="only_first", max_length=result["max_length"]
                )["input_ids"]
                assert ids == reference, "pair assembly differs from the tokenizer"
                with torch.no_grad():
                    logits = model(input_ids=torch.tensor([ids], device=device)).logits[0]
                p = float(torch.softmax(logits[[entail, negative]], dim=-1)[0])
                outputs.append(
                    {
                        "message": record["id"],
                        "category": concept,
                        "hypothesis": h,
                        "input_ids": ids,
                        "entailment_probability": round(p, 6),
                        "member": p >= result["thresholds"][record["language"]],
                    }
                )
        golden["custom"].append({"run": name, "outputs": outputs})
        bundle["custom"].append(
            {
                "run": name,
                "model": model_name,
                "revision": revision,
                "license": LICENSES[model_name],
                "adaptation": json.loads((source / "adaptation.json").read_text())
                if source
                else "none: the published NLI checkpoint, scored zero-shot",
                "weights_sha256": sha256_file(weights),
                "input": result["input"],
                "max_length": result["max_length"],
                "hypothesis": HYPOTHESIS,
                "description": result["mode"],
                "entailment_label": model.config.id2label[entail],
                "negative_label": model.config.id2label[negative],
                "thresholds": result["thresholds"],
            }
        )
    for name in SYSTEM_RUNS:
        path = WORK / "runs" / name
        tokenizer = AutoTokenizer.from_pretrained(path)
        model = AutoModelForSequenceClassification.from_pretrained(path, dtype=torch.float32)
        model.eval()
        thresholds = json.loads((path / "thresholds.json").read_text())
        max_length = run.INPUTS[name.rsplit("-", 1)[1]]
        outputs = []
        for record in records:
            ids = tokenizer(run.with_body(record), truncation=True, max_length=max_length)[
                "input_ids"
            ]
            with torch.no_grad():
                probabilities = torch.sigmoid(model(input_ids=torch.tensor([ids])).logits)[0]
            decided = run.decide(
                probabilities.numpy()[None], np.array([thresholds[c] for c in corpus.CATEGORIES])
            )[0]
            outputs.append(
                {
                    "message": record["id"],
                    "input_ids": ids,
                    "probabilities": {
                        c: round(float(v), 6) for c, v in zip(corpus.CATEGORIES, probabilities)
                    },
                    "categories": [c for c, d in zip(corpus.CATEGORIES, decided) if d],
                }
            )
        golden["system"].append({"run": name, "outputs": outputs})
        result = json.loads((ROOT / "results" / f"{name}.json").read_text())
        bundle["system"].append(
            {
                "run": name,
                "model": result["model"],
                "revision": result["revision"],
                "license": "MIT",
                "adaptation": "spike #828 fine-tune; reproduce with run.py deberta "
                + " ".join(name.split("-")[1:]),
                "weights_sha256": sha256_file(path / "model.safetensors"),
                "input": result["input"],
                "max_length": max_length,
                "thresholds": thresholds,
                "people_fallback": True,
            }
        )
    (CUSTOM / "golden-v1.json").write_text(json.dumps(golden, ensure_ascii=False) + "\n")
    (CUSTOM / "bundle-v1.json").write_text(json.dumps(bundle, indent=2, ensure_ascii=False) + "\n")
    print(f"golden outputs for {len(records)} messages")


def fmt(value) -> str:
    return "–" if value is None else f"{value:.2f}"


def table(header: list[str], rows: list[list]) -> str:
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(lines + ["| " + " | ".join(map(str, row)) + " |" for row in rows]) + "\n"


def tables() -> None:
    """Render custom/tables.md, refusing incompatible experiments or annotations."""
    results = {}
    for path in sorted((CUSTOM / "results").glob("*.json")):
        report = json.loads(path.read_text())
        require_current(report, path.name, labeled=True)
        if "slices" in report and "thresholds" in report and "groups" in report:
            results[report["run"]] = report
    slices = [
        "en",
        "cs",
        "en/real-random",
        "en/real-enriched",
        "en/synthetic",
        "en/custom-synthetic",
        "cs/synthetic",
        "cs/custom-synthetic",
    ]
    out = [
        "# Custom Category results (spike #829)\n",
        (
            "Generated by `custom.py tables` from `custom/results/*.json`. Test split; macro-F1 "
            "is over the Custom Categories with test support in each slice.\n"
        ),
        "## Macro-F1 by slice\n",
    ]
    rows = []
    for name, r in results.items():
        a = r["slices"]["all"]
        ci = a.get("macro_f1_ci95")
        rows.append(
            [
                name,
                f"{fmt(a['macro_f1'])} ({fmt(ci[0])}–{fmt(ci[1])})" if ci else fmt(a["macro_f1"]),
                *[fmt(r["slices"][k]["macro_f1"]) for k in slices],
                f"{r['thresholds']['en']:.2f} / {r['thresholds']['cs']:.2f}",
            ]
        )
    out.append(table(["Run", "All (95% CI)", *slices, "Threshold en / cs"], rows))
    out.append("\n## Category groups (all languages)\n")
    out.append(
        table(
            ["Run", "Unseen meanings", "Overlap a System Category", "Ambiguous names"],
            [
                [
                    n,
                    *[
                        fmt(r["groups"][g]["macro_f1"])
                        for g in ("unseen", "system-overlap", "ambiguous-name")
                    ],
                ]
                for n, r in results.items()
            ],
        )
    )
    out.append("\n## Coverage and abstention\n")
    out.append(
        "Coverage is the share of messages given at least one Custom Category; gold coverage is the "
        "same for the labels. None precision/recall treat “no Custom Category” as a decision.\n\n"
    )
    rows = []
    for n, r in results.items():
        for k in ("en", "cs", "en/real-random"):
            m = r["slices"][k]
            rows.append(
                [
                    n,
                    k,
                    fmt(m["micro_f1"]),
                    f"{m['coverage']:.2f} / {m['gold_coverage']:.2f}",
                    fmt(m["none_precision"]),
                    fmt(m["none_recall"]),
                    fmt(m["false_assignments_per_message"]),
                    f"{m['multi_errors']} / {m['multi_messages']}",
                ]
            )
    out.append(
        table(
            [
                "Run",
                "Slice",
                "Micro-F1",
                "Coverage / gold",
                "None precision",
                "None recall",
                "False assignments per message",
                "Multi-label errors",
            ],
            rows,
        )
    )
    out.append("\n## Calibration on held-out categories\n")
    out.append(
        "Thresholds tuned on validation with only the even (fold 1) or odd (fold 2) categories, then "
        "applied to the other half on test, against the pooled thresholds on that same half.\n\n"
    )
    out.append(
        table(
            ["Run", "Fold 1 held-out / pooled", "Fold 2 held-out / pooled"],
            [
                [
                    n,
                    *[
                        f"{fmt(f['held_out_macro_f1'])} / {fmt(f['pooled_macro_f1'])}"
                        for f in r["category_heldout_calibration"]
                    ],
                ]
                for n, r in results.items()
            ],
        )
    )
    out.append("\n## Candidate-category count\n")
    out.append(
        "Five random nested draws of 5, 20 and 50 of the 52 categories; mean (min–max). Messages per "
        "second divide the measured pair throughput by the category count.\n\n"
    )
    rows = []
    for n, r in results.items():
        for k, v in r["sweep"].items():
            mean = lambda key, v=v: f"{np.mean(v[key]):.2f} ({min(v[key]):.2f}–{max(v[key]):.2f})"
            rows.append(
                [
                    n,
                    k,
                    mean("macro_f1"),
                    mean("false_assignments_per_message"),
                    mean("messages_with_false_assignment"),
                    f"{v['messages_per_second']:.1f}" if "messages_per_second" in v else "–",
                ]
            )
    out.append(
        table(
            [
                "Run",
                "Categories",
                "Macro-F1",
                "False assignments per message",
                "Messages with a false assignment",
                "Messages per second",
            ],
            rows,
        )
    )
    out.append("\n## Throughput and input budget\n")
    out.append(
        "Apple M4 Mac mini shared with other agent sessions; the load average is part of the "
        "measurement. MPS, fp32, batches of up to 16,384 padded tokens.\n\n"
    )
    out.append(
        table(
            [
                "Run",
                "Parameters",
                "Pairs",
                "Pairs per second",
                "Load average (1 min) before / after",
                "Hypothesis tokens mean / max",
                "Pairs at the token limit",
                "Median message tokens",
            ],
            [
                [
                    n,
                    f"{r['parameters'] / 1e6:.1f}M",
                    r["pairs"],
                    r["pairs_per_second"],
                    f"{r['load_average_before'][0]:.0f} / {r['load_average_after'][0]:.0f}",
                    f"{r['custom_hypothesis_tokens']['mean']:.0f} / {r['custom_hypothesis_tokens']['max']}",
                    f"{r['truncated_pair_fraction']:.0%}",
                    f"{r['premise_tokens_median']:.0f}",
                ]
                for n, r in results.items()
                if "pairs" in r
            ],
        )
    )
    out.append("\n## System Categories through the same NLI pipeline\n")
    out.append(
        "Glossary definitions as hypotheses, per-category thresholds on validation and People as the "
        "fallback, against the spike #828 classifiers on the same test messages.\n\n"
    )
    # System hypotheses always carry their definitions, so other modes would repeat these rows.
    system = {
        n: r["system"]["slices"]
        for n, r in results.items()
        if "system" in r and r["mode"] == "description"
    }
    for name in ("tfidf-minimized", "deberta-xsmall-body256", "deberta-mdeberta-body512"):
        result = json.loads((ROOT / "results" / f"{name}.json").read_text())
        expected = json.loads(corpus.MANIFEST.read_text())["corpus_sha256"]
        if (
            result.get("corpus_sha256") != expected
            or result.get("benchmark_sha256") != run.benchmark_sha256()
        ):
            raise ValueError(f"#828 {name}: stale corpus or benchmark; rerun run.py")
        system[f"#828 {name}"] = result["slices"]
    keys = ["all", "en/real-random", "en/real-enriched", "en/synthetic", "cs/synthetic"]
    out.append(
        table(
            ["Run", *keys], [[n, *[fmt(v[k]["macro_f1"]) for k in keys]] for n, v in system.items()]
        )
    )
    out.append("\n## Per-category results\n")
    for n, r in results.items():
        if n.startswith("keywords"):
            continue
        out.append(f"\n### {n}\n\n")
        rows = []
        for c in CONCEPTS:
            cells = []
            for k in ("en", "cs"):
                m = r["slices"][k]["per_category"][c]
                cells.append(
                    f"{m['support']}: {fmt(m['precision'])} / {fmt(m['recall'])} / {fmt(m['f1'])}"
                )
            rows.append([c, *cells])
        out.append(
            table(["Category", "English support: P / R / F1", "Czech support: P / R / F1"], rows)
        )
    extra = {p.stem: json.loads(p.read_text()) for p in (CUSTOM / "results").glob("*.json")}
    out.append("\n## Annotation agreement\n")
    a = extra["agreement"]
    out.append(
        f"An independent relabel of {a['messages']} messages ({a['real_messages']} real): exact label-set "
        f"agreement {a['exact_match']:.2f} ({a['exact_match_real']:.2f} real), micro-F1 "
        f"{a['micro_f1']:.2f} ({a['micro_f1_real']:.2f} real).\n\n"
    )
    out.append(
        table(
            ["Category", "Positives (labels / relabel)", "Cohen's kappa"],
            [
                [c, f"{v['positives'][0]} / {v['positives'][1]}", fmt(v["kappa"])]
                for c, v in a["per_category"].items()
            ],
        )
    )
    out.append("\n## Hypothesis wording probe (validation sample)\n")
    out.append(
        "Thresholds tuned and scored on the same validation sample, so only the comparison between "
        "wordings is meaningful.\n\n"
    )
    out.append(
        table(
            ["Probe", "Wording and description", "English", "Czech"],
            [
                [n, v, fmt(m["en"]), fmt(m["cs"])]
                for n, r in extra.items()
                if n.startswith("templates-")
                for v, m in r["variants"].items()
            ],
        )
    )
    out.append("\n## Future Learning Signals\n")
    out.append(
        "Test messages replayed in arrival order; every error is corrected by a simulated User "
        "Override, which records a per-sender signal for that category.\n\n"
    )
    rows = []
    for n, r in extra.items():
        if n.startswith("overrides-"):
            for k, v in r["slices"].items():
                rows.append(
                    [
                        n.removeprefix("overrides-"),
                        k,
                        v["messages"],
                        f"{v['signals']['positive']} / {v['signals']['negative']}",
                        v["decisions_changed_by_signals"],
                        v["changed_decisions_correct"],
                        v["earlier_assignments_left_unchanged"],
                        f"{v['micro_f1_model_only']:.2f} → {v['micro_f1_with_signals']:.2f}",
                    ]
                )
    out.append(
        table(
            [
                "Run",
                "Slice",
                "Messages",
                "Signals + / −",
                "Decisions changed",
                "Changed correctly",
                "Earlier assignments left unchanged",
                "Micro-F1 model → with signals",
            ],
            rows,
        )
    )
    text = re.sub(r"\n*(#{1,3} [^\n]+)\n*", r"\n\n\1\n\n", "".join(out)).lstrip()
    text = re.sub(r"([^\n|])\n(\|)", r"\1\n\n\2", text)  # a blank line before every table
    (CUSTOM / "tables.md").write_text(re.sub(r"\n{3,}", "\n\n", text))
    print(f"{len(results)} runs")
