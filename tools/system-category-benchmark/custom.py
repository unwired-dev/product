"""Custom Category comparison (spike #829) on the corpus v2 validation and test messages.

uv run python custom.py annotate     # write annotation batches to work/custom-annotate/
uv run python custom.py labels       # merge work/custom-annotations/ into custom/labels-v1.jsonl
uv run python custom.py adapt <candidate>                          # System-hypothesis fine-tune
uv run python custom.py score <candidate>[-adapted] <input> <mode>  # NLI scores to work/
"""

import hashlib
import json
import os
import random
import re
import sys
import time
from pathlib import Path

import numpy as np

import corpus
import custom_synthetic
import run
import synthetic

ROOT = Path(__file__).parent
CUSTOM = ROOT / "custom"
WORK = ROOT / "work"
CATEGORIES = json.loads((CUSTOM / "categories-v1.json").read_text())
CONCEPTS = [c["id"] for c in CATEGORIES]
LABELS = CUSTOM / "labels-v1.jsonl"
BATCH = 60
SEED = 829
CANDIDATES = {
    "xsmall-zs": (
        "MoritzLaurer/deberta-v3-xsmall-zeroshot-v1.1-all-33",
        "262ae02f29173eec1c250f90804dc7edc677dcff",
    ),
    "xsmall-nli": (
        "cross-encoder/nli-deberta-v3-xsmall",
        "a150876415327c80daeff35ca6f68f5ed8cf5c24",
    ),
    "mdeberta-nli": (
        "MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7",
        "b5113eb38ab63efdd7f280f8c144ea8b13f978ce",
    ),
}
MODES = ("name", "description", "paraphrase")  # name only, the description, or its paraphrase
HYPOTHESIS = {
    "en": 'This email belongs to the category "{name}".',
    "cs": "Tento e-mail patří do kategorie „{name}“.",
}
# System Categories as hypotheses: glossary definitions, in corpus.CATEGORIES order.
SYSTEM = [
    {
        "en": {
            "name": "Orders",
            "description": "Transactional purchase messages, including confirmations, invoices, "
            "receipts, payment updates, shipping, delivery, cancellations, and returns.",
        },
        "cs": {
            "name": "Objednávky",
            "description": "Transakční zprávy o nákupech, včetně potvrzení, faktur, účtenek, "
            "informací o platbě, odeslání, doručení, zrušení a vrácení.",
        },
    },
    {
        "en": {
            "name": "Newsletters & Promotions",
            "description": "Subscribed newsletters and commercial marketing messages, including "
            "campaigns, coupons, sales, and advertising email.",
        },
        "cs": {
            "name": "Newslettery a akce",
            "description": "Odebírané newslettery a obchodní marketingové zprávy, včetně kampaní, "
            "kupónů, výprodejů a reklamních e-mailů.",
        },
    },
    {
        "en": {"name": "Invites", "description": "Invitations and messages requesting an RSVP."},
        "cs": {
            "name": "Pozvánky",
            "description": "Pozvánky a zprávy, které žádají o potvrzení účasti.",
        },
    },
    {
        "en": {
            "name": "Flights",
            "description": "Flight-related messages, including airline itineraries and boarding "
            "information.",
        },
        "cs": {
            "name": "Lety",
            "description": "Zprávy o letech, včetně itinerářů aerolinek a informací k nástupu.",
        },
    },
    {
        "en": {
            "name": "People",
            "description": "Person-to-person correspondence primarily authored by a human for "
            "direct conversation, excluding bulk mail, newsletters, transactional notifications, "
            "and automated campaigns.",
        },
        "cs": {
            "name": "Lidé",
            "description": "Osobní korespondence mezi lidmi napsaná člověkem pro přímou konverzaci, "
            "kromě hromadné pošty, newsletterů, transakčních oznámení a automatických kampaní.",
        },
    },
]
ADAPTATION = {  # fine-tuning on System Category hypotheses only; Custom meanings stay unseen
    "epochs": 1,
    "batch_size": 16,
    "learning_rate": 2e-5,
    "warmup": 0.1,
    "weight_decay": 0.01,
    "input": "body256",
    "microbatch_tokens": 2048,
}


def messages() -> list[dict]:
    """Validation and test messages of corpus v2 plus the Custom synthetic stratum."""
    splits = run.load_corpus()
    return splits["validation"] + splits["test"] + custom_synthetic.generate()


def annotate() -> None:
    records = sorted(messages(), key=lambda r: hashlib.sha256(r["id"].encode()).hexdigest())
    out = WORK / "custom-annotate"
    out.mkdir(parents=True, exist_ok=True)
    for number, start in enumerate(range(0, len(records), BATCH)):
        text = [
            f"=== ID: {r['id']}\nFrom: {r['from']}\nReply-To: {r['reply_to']}\n"
            f"Recipients: {r['recipients']}  Mailing-list headers: {r['list']}\n"
            f"Date: {r['date']}\nSubject: {r['subject']}\n\n{r['body'][:2500]}\n"
            for r in records[start : start + BATCH]
        ]
        (out / f"batch-{number:02d}.txt").write_text("\n".join(text))
    print(f"{len(records)} messages in {number + 1} batches")


def labels() -> None:
    """Merge annotations; every message needs exactly one entry with known category ids."""
    wanted = {r["id"] for r in messages()}
    merged = {}
    for path in sorted((WORK / "custom-annotations").glob("batch-*.jsonl")):
        for line in path.read_text().splitlines():
            entry = json.loads(line)
            unknown = set(entry["categories"]) - set(CONCEPTS)
            if entry["id"] not in wanted or entry["id"] in merged or unknown:
                raise ValueError(f"{path.name}: bad entry {entry['id']} {unknown}")
            merged[entry["id"]] = sorted(entry["categories"], key=CONCEPTS.index)
    if missing := wanted - merged.keys():
        raise ValueError(f"{len(missing)} messages unlabeled, e.g. {sorted(missing)[:3]}")
    LABELS.write_text(
        "".join(json.dumps({"id": i, "categories": merged[i]}) + "\n" for i in sorted(merged))
    )
    print(f"{len(merged)} labeled messages")


def hypothesis(definition: dict, language: str, mode: str) -> str:
    text = HYPOTHESIS[language].format(name=definition[language]["name"])
    return text if mode == "name" else f"{text} {definition[language][mode]}"


def premise(record: dict, input_key: str) -> str:
    return run.minimized(record) if input_key == "minimized" else run.with_body(record)


def pair_ids(tokenizer, premise_ids: list[int], hypothesis_ids: list[int], max_length: int):
    """[CLS] premise [SEP] hypothesis [SEP], truncating only the premise (only_first)."""
    room = max_length - len(hypothesis_ids) - 3
    if room < 1:
        raise ValueError("the hypothesis leaves no room for the message within the token budget")
    cls, sep = tokenizer.cls_token_id, tokenizer.sep_token_id
    return [cls, *premise_ids[:room], sep, *hypothesis_ids, sep]


def load(source: str, revision: str | None):
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tokenizer = AutoTokenizer.from_pretrained(source, revision=revision)
    # Some checkpoints are stored in float16; run and train in float32 like spike #828.
    model = AutoModelForSequenceClassification.from_pretrained(
        source, revision=revision, dtype=torch.float32
    ).to(device)
    labels = {name.lower(): int(index) for index, name in model.config.id2label.items()}
    negative = labels.get("contradiction", labels.get("not_entailment"))
    return tokenizer, model, device, labels["entailment"], negative


def batches(sequences: list[list[int]], order, pad: int, device: str, max_tokens: int):
    import torch

    start = 0
    while start < len(order):
        width = len(sequences[order[start]])
        end = start + 1
        while (
            end < len(order)
            and (end - start + 1) * max(width, len(sequences[order[end]])) <= max_tokens
        ):
            width = max(width, len(sequences[order[end]]))
            end += 1
        chunk = order[start:end]
        ids = torch.tensor(
            [sequences[i] + [pad] * (width - len(sequences[i])) for i in chunk], device=device
        )
        mask = torch.tensor(
            [[1] * len(sequences[i]) + [0] * (width - len(sequences[i])) for i in chunk],
            device=device,
        )
        yield chunk, ids, mask
        start = end


def adapt(candidate: str) -> None:
    """Fine-tune on train-split System Category hypotheses (entailment vs not) for one epoch."""
    import torch
    from transformers import get_linear_schedule_with_warmup

    random.seed(SEED)
    np.random.seed(SEED)
    torch.manual_seed(SEED)
    name, revision = CANDIDATES[candidate]
    tokenizer, model, device, entail, negative = load(name, revision)
    max_length = run.INPUTS[ADAPTATION["input"]]
    sequences, targets = [], []
    for record in run.load_corpus()["train"]:
        premise_ids = tokenizer(premise(record, ADAPTATION["input"]), add_special_tokens=False)[
            "input_ids"
        ]
        for category, definition in zip(corpus.CATEGORIES, SYSTEM):
            hypothesis_ids = tokenizer(
                hypothesis(definition, record["language"], "description"), add_special_tokens=False
            )["input_ids"]
            sequences.append(pair_ids(tokenizer, premise_ids, hypothesis_ids, max_length))
            targets.append(entail if category in record["labels"] else negative)
    targets = np.array(targets)
    size = ADAPTATION["batch_size"]
    steps = ADAPTATION["epochs"] * -(-len(sequences) // size)
    optimizer = torch.optim.AdamW(
        model.parameters(), lr=ADAPTATION["learning_rate"], weight_decay=ADAPTATION["weight_decay"]
    )
    schedule = get_linear_schedule_with_warmup(optimizer, int(ADAPTATION["warmup"] * steps), steps)
    rng = np.random.default_rng(SEED)
    started, peak_memory = time.time(), 0
    model.train()
    for _ in range(ADAPTATION["epochs"]):
        order = rng.permutation(len(sequences))
        for start in range(0, len(order), size):
            group = order[start : start + size]
            for chunk, ids, mask in batches(
                sequences, group, tokenizer.pad_token_id, device, ADAPTATION["microbatch_tokens"]
            ):
                logits = model(input_ids=ids, attention_mask=mask).logits
                labels = torch.tensor(targets[chunk], device=device)
                loss = torch.nn.functional.cross_entropy(logits, labels)
                (loss * len(chunk) / len(group)).backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            schedule.step()
            optimizer.zero_grad()
            if device == "mps":
                peak_memory = max(peak_memory, torch.mps.driver_allocated_memory())
                torch.mps.empty_cache()
    output = WORK / "custom-adapted" / candidate
    model.save_pretrained(output)
    tokenizer.save_pretrained(output)
    (output / "adaptation.json").write_text(
        json.dumps(
            {
                "base": name,
                "revision": revision,
                "seed": SEED,
                **ADAPTATION,
                "pairs": len(sequences),
                "train_seconds": round(time.time() - started, 1),
                "peak_device_memory_mib": round(peak_memory / 2**20) if device == "mps" else None,
                "load_average": os.getloadavg(),
            },
            indent=1,
        )
        + "\n"
    )
    print(f"adapted {candidate} on {len(sequences)} pairs in {time.time() - started:.0f}s")


def score(run_candidate: str, input_key: str, mode: str) -> None:
    """Entailment probability of every message against every Custom and System hypothesis."""
    import torch

    candidate = run_candidate.removesuffix("-adapted")
    name, revision = CANDIDATES[candidate]
    adapted = run_candidate.endswith("-adapted")
    source = str(WORK / "custom-adapted" / candidate) if adapted else name
    tokenizer, model, device, entail, negative = load(source, None if adapted else revision)
    model.eval()
    max_length = run.INPUTS[input_key]
    records = messages()
    definitions = [(c, mode) for c in CATEGORIES] + [(c, "description") for c in SYSTEM]
    hypothesis_ids = {
        language: [
            tokenizer(hypothesis(d, language, m), add_special_tokens=False)["input_ids"]
            for d, m in definitions
        ]
        for language in ("en", "cs")
    }
    sequences, premise_tokens = [], []
    for record in records:
        ids = tokenizer(premise(record, input_key), add_special_tokens=False)["input_ids"]
        premise_tokens.append(len(ids))
        sequences += [
            pair_ids(tokenizer, ids, h, max_length) for h in hypothesis_ids[record["language"]]
        ]
    lengths = np.array([len(s) for s in sequences])
    order = list(np.argsort(lengths, kind="stable"))
    scores = np.zeros(len(sequences))
    load_before, started = os.getloadavg(), time.time()
    with torch.no_grad():
        for chunk, ids, mask in batches(sequences, order, tokenizer.pad_token_id, device, 16384):
            logits = model(input_ids=ids, attention_mask=mask).logits[:, [entail, negative]]
            scores[chunk] = torch.softmax(logits, dim=-1)[:, 0].cpu().numpy()
    if device == "mps":
        torch.mps.synchronize()
    seconds = time.time() - started
    width = len(definitions)
    hypothesis_lengths = [
        len(h) for language in ("en", "cs") for h in hypothesis_ids[language][: len(CATEGORIES)]
    ]
    meta = {
        "run": f"{run_candidate}-{input_key}-{mode}",
        "candidate": run_candidate,
        "model": name,
        "revision": revision,
        "adapted": adapted,
        "input": input_key,
        "max_length": max_length,
        "mode": mode,
        "device": device,
        "torch": torch.__version__,
        "parameters": sum(p.numel() for p in model.parameters()),
        "pairs": len(sequences),
        "seconds": round(seconds, 1),
        "pairs_per_second": round(len(sequences) / seconds, 1),
        "load_average_before": [round(x, 1) for x in load_before],
        "load_average_after": [round(x, 1) for x in os.getloadavg()],
        "custom_hypothesis_tokens": {
            "mean": float(np.mean(hypothesis_lengths)),
            "max": int(max(hypothesis_lengths)),
        },
        "truncated_pair_fraction": float(
            np.mean(lengths.reshape(-1, width)[:, : len(CATEGORIES)] >= max_length)
        ),
        "premise_tokens_median": float(np.median(premise_tokens)),
    }
    out = WORK / "custom-scores"
    out.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        out / f"{meta['run']}.npz",
        ids=np.array([r["id"] for r in records]),
        scores=scores.reshape(-1, width),
        meta=json.dumps(meta),
    )
    print(json.dumps(meta))


STOPWORDS = {  # space-separated, ASCII-folded with the message text in stems()
    "en": "the and for from that this with about such things messages message email emails my me "
    "i we our or not any other some into their them they you your are was can has have of to "
    "in on at by as is it its be an a who what when how all also more one including like "
    "sent send mail still",
    "cs": "a i v ve na do z ze s se k ke o od po pro při je jsou to ten ta které který která "
    "mé můj moje mi mě já my naše náš nás jejich jak co kde kdy nebo ne ani jako také "
    "zprávy zpráva e-mail e-maily věci například včetně",
}


def stems(text: str, language: str) -> set[str]:
    # Prefix stems tolerate English plurals and Czech inflection in a crude, explainable way.
    words = synthetic.ascii_lower(text).replace("-", " ").split()
    words = ["".join(ch for ch in word if ch.isalnum()) for word in words]
    stop = {synthetic.ascii_lower(w) for w in STOPWORDS[language].split()}
    return {w[:5] for w in words if len(w) > 2 and w not in stop}


def keyword_scores(records: list[dict], input_key: str, mode: str) -> np.ndarray:
    """Share of a category's name (and description) stems found in the message."""
    scores = np.zeros((len(records), len(CATEGORIES)))
    for i, record in enumerate(records):
        language = record["language"]
        text = stems(
            premise(record, "minimized") if input_key == "minimized" else run.with_body(record),
            language,
        )
        for j, category in enumerate(CATEGORIES):
            words = stems(category[language]["name"], language)
            if mode != "name":
                words |= stems(category[language][mode], language)
            scores[i, j] = len(words & text) / max(1, len(words))
    return scores


def load_labels(records: list[dict]) -> np.ndarray:
    labels = {
        entry["id"]: set(entry["categories"])
        for entry in map(json.loads, LABELS.read_text().splitlines())
    }
    return np.array([[c in labels[r["id"]] for c in CONCEPTS] for r in records], dtype=bool)


GRID = np.round(np.arange(0.01, 1.0, 0.01), 2)


def micro_f1(truth: np.ndarray, predicted: np.ndarray) -> float:
    return run.f1(truth.ravel(), predicted.ravel())


def calibrate(scores: np.ndarray, truth: np.ndarray) -> float:
    """One threshold for every Custom Category: a new category has no labels to tune on."""
    values = [micro_f1(truth, scores >= t) for t in GRID]
    return float(GRID[len(GRID) - 1 - int(np.argmax(values[::-1]))])  # ties: abstain more


def calibrate_languages(records, scores, truth, rows, columns) -> dict[str, float]:
    """A threshold per message language, so an English checkpoint's Czech scores cannot move it."""
    languages = np.array([r["language"] for r in records])
    return {
        language: calibrate(
            scores[rows & (languages == language)][:, columns],
            truth[rows & (languages == language)][:, columns],
        )
        for language in ("en", "cs")
    }


def decide(records: list[dict], scores: np.ndarray, thresholds: dict[str, float]) -> np.ndarray:
    return scores >= np.array([thresholds[r["language"]] for r in records])[:, None]


def custom_metrics(truth: np.ndarray, predicted: np.ndarray, concepts: list[int], ci: bool = False):
    supported = [c for c in concepts if truth[:, c].any()]

    def macro(rows):
        return float(np.mean([run.f1(truth[rows, c], predicted[rows, c]) for c in supported]))

    per_category = {}
    for c in concepts:
        t, p = truth[:, c], predicted[:, c]
        tp = int((t & p).sum())
        per_category[CONCEPTS[c]] = {
            "support": int(t.sum()),
            "predicted": int(p.sum()),
            "precision": tp / p.sum() if p.sum() else None,
            "recall": tp / t.sum() if t.sum() else None,
            "f1": run.f1(t, p) if t.sum() else None,
        }
    t, p = truth[:, concepts], predicted[:, concepts]
    result = {
        "messages": len(truth),
        "categories": len(concepts),
        "supported_categories": len(supported),
        "macro_f1": macro(np.arange(len(truth))) if supported else None,
        "micro_f1": run.f1(t.ravel(), p.ravel()),
        "exact_match": float((t == p).all(axis=1).mean()),
        "coverage": float(p.any(axis=1).mean()),
        "gold_coverage": float(t.any(axis=1).mean()),
        "none_precision": float(
            (~t.any(axis=1) & ~p.any(axis=1)).sum() / max(1, (~p.any(axis=1)).sum())
        ),
        "none_recall": float(
            (~t.any(axis=1) & ~p.any(axis=1)).sum() / max(1, (~t.any(axis=1)).sum())
        ),
        "false_assignments_per_message": float((p & ~t).sum(axis=1).mean()),
        "messages_with_false_assignment": float((p & ~t).any(axis=1).mean()),
        "multi_messages": int((t.sum(axis=1) > 1).sum()),
        "multi_errors": int(((t.sum(axis=1) > 1) & ~(t == p).all(axis=1)).sum()),
        "per_category": per_category,
    }
    if ci and supported:
        rng = np.random.default_rng(SEED)
        samples = [macro(rng.integers(0, len(truth), len(truth))) for _ in range(300)]
        result["macro_f1_ci95"] = [
            float(np.percentile(samples, 2.5)),
            float(np.percentile(samples, 97.5)),
        ]
    return result


def evaluate(name: str, scores: np.ndarray, meta: dict) -> dict:
    """Calibrate on validation, report test slices, groups, k sweep, System regressions."""
    records = messages()
    truth = load_labels(records)
    validation = np.array([r["split"] == "validation" for r in records])
    test = ~validation
    custom = scores[:, : len(CATEGORIES)]
    every = list(range(len(CATEGORIES)))
    thresholds = calibrate_languages(records, custom, truth, validation, every)
    predicted = decide(records, custom, thresholds)
    unseen = [i for i, c in enumerate(CATEGORIES) if not c["overlaps_system"]]
    report = {
        "run": name,
        "labels_sha256": hashlib.sha256(LABELS.read_bytes()).hexdigest(),
        "categories_sha256": hashlib.sha256(
            (CUSTOM / "categories-v1.json").read_bytes()
        ).hexdigest(),
        **meta,
        "thresholds": thresholds,
        "slices": {},
        "groups": {},
    }
    t, p = truth[test], predicted[test]
    report["slices"]["all"] = custom_metrics(t, p, every, ci=True)
    tests = [r for r, keep in zip(records, test) if keep]
    for key in sorted({(r["language"], r["stratum"]) for r in tests}):
        rows = np.array([(r["language"], r["stratum"]) == key for r in tests])
        report["slices"]["/".join(key)] = custom_metrics(t[rows], p[rows], every)
    for language in ("en", "cs"):
        rows = np.array([r["language"] == language for r in tests])
        report["slices"][language] = custom_metrics(t[rows], p[rows], every)
    report["groups"] = {
        "unseen": custom_metrics(t, p, unseen),
        "system-overlap": custom_metrics(t, p, [i for i in every if i not in unseen]),
        "ambiguous-name": custom_metrics(
            t, p, [i for i, c in enumerate(CATEGORIES) if c.get("ambiguous_name")]
        ),
    }
    # Category-held-out calibration: thresholds tuned on one half of the categories only.
    folds = []
    for fold in (0, 1):
        tuned = [i for i in every if i % 2 == fold]
        held = [i for i in every if i % 2 != fold]
        fold_thresholds = calibrate_languages(records, custom, truth, validation, tuned)
        folds.append(
            {
                "thresholds": fold_thresholds,
                "held_out_macro_f1": custom_metrics(
                    t, decide(tests, custom[test], fold_thresholds), held
                )["macro_f1"],
                "pooled_macro_f1": custom_metrics(t, p, held)["macro_f1"],
            }
        )
    report["category_heldout_calibration"] = folds
    sweep = {}
    for k in (5, 20, 50):
        draws = []
        for draw in range(5):
            subset = list(np.random.default_rng(SEED + draw).permutation(len(CATEGORIES))[:k])
            m = custom_metrics(t, p, subset)
            draws.append(
                {
                    key: m[key]
                    for key in (
                        "macro_f1",
                        "micro_f1",
                        "coverage",
                        "false_assignments_per_message",
                        "messages_with_false_assignment",
                    )
                }
            )
        sweep[k] = {key: [d[key] for d in draws] for key in draws[0]}
        if "pairs_per_second" in meta:
            sweep[k]["messages_per_second"] = meta["pairs_per_second"] / k
    report["sweep"] = sweep
    if scores.shape[1] > len(CATEGORIES):
        report["system"] = system_regression(records, scores[:, len(CATEGORIES) :], validation)
    report["errors"] = [
        {
            "id": r["id"],
            "slice": f"{r['language']}/{r['stratum']}",
            **({"subject": r["subject"][:80]} if r["source"] == "synthetic" else {}),
            "missed": [CONCEPTS[c] for c in np.flatnonzero(gold & ~row)],
            "extra": [CONCEPTS[c] for c in np.flatnonzero(row & ~gold)],
        }
        for r, row, gold in zip(tests, p, t)
        if (row != gold).any()
    ]
    return report


def system_regression(records: list[dict], scores: np.ndarray, validation: np.ndarray) -> dict:
    """System Categories through the same NLI pipeline, People still only the fallback."""
    rows = np.array([r["stratum"] != "custom-synthetic" for r in records])
    val, test = rows & validation, rows & ~validation
    thresholds = run.calibrate(scores[val], run.gold([r for r, k in zip(records, val) if k]))
    test_records = [r for r, k in zip(records, test) if k]
    truth, predicted = run.gold(test_records), run.decide(scores[test], thresholds)
    slices = {"all": run.slice_metrics(test_records, truth, predicted)}
    for key in sorted({(r["language"], r["stratum"]) for r in test_records}):
        mask = np.array([(r["language"], r["stratum"]) == key for r in test_records])
        slices["/".join(key)] = run.slice_metrics(
            [r for r, k in zip(test_records, mask) if k], truth[mask], predicted[mask]
        )
    return {"thresholds": dict(zip(corpus.CATEGORIES, thresholds.tolist())), "slices": slices}


def replay(records: list[dict], scores: np.ndarray, truth: np.ndarray, thresholds: dict) -> dict:
    """Classify messages in arrival order; each correction becomes a per-sender signal.

    Signals are local correction state consulted only when a later message arrives. No model
    weights change, and an assignment made earlier is never revisited.
    """
    order = sorted(range(len(records)), key=lambda i: (records[i]["date"], records[i]["id"]))
    senders = [corpus.sender_address(r["from"]) for r in records]
    signals: dict[tuple[str, int], bool] = {}
    assigned: dict[int, np.ndarray] = {}
    model_only = {}
    changed = correct = untouched = positive = negative = 0
    for i in order:
        model_only[i] = scores[i] >= thresholds[records[i]["language"]]
        decision = model_only[i].copy()
        for c in range(decision.size):
            decision[c] = signals.get((senders[i], c), decision[c])
        changed += int((decision != model_only[i]).sum())
        correct += int(((decision != model_only[i]) & (decision == truth[i])).sum())
        assigned[i] = decision
        for c in np.flatnonzero(decision != truth[i]):  # the user's override on this message
            signals[(senders[i], c)] = bool(truth[i, c])
            positive += int(truth[i, c])
            negative += int(not truth[i, c])
            # Earlier assignments this signal contradicts are counted, not rewritten.
            untouched += sum(
                1
                for j in assigned
                if j != i and senders[j] == senders[i] and assigned[j][c] != truth[i, c]
            )
    gold = truth[order]
    return {
        "messages": len(order),
        "signals": {"positive": positive, "negative": negative},
        "decisions_changed_by_signals": changed,
        "changed_decisions_correct": correct,
        "earlier_assignments_left_unchanged": untouched,
        "micro_f1_model_only": micro_f1(gold, np.array([model_only[i] for i in order])),
        "micro_f1_with_signals": micro_f1(gold, np.array([assigned[i] for i in order])),
    }


def overrides(name: str) -> dict:
    """Replay the test stream of one run with simulated User Overrides, per slice."""
    data = np.load(WORK / "custom-scores" / f"{name}.npz")
    records = messages()
    truth = load_labels(records)
    thresholds = json.loads((CUSTOM / "results" / f"{name}.json").read_text())["thresholds"]
    scores = data["scores"][:, : len(CATEGORIES)]
    report = {"run": f"overrides-{name}", "thresholds": thresholds, "slices": {}}
    groups = {
        "real": lambda r: r["source"] != "synthetic",
        "synthetic": lambda r: r["source"] == "synthetic",
    }
    for key, keep in groups.items():
        rows = [i for i, r in enumerate(records) if r["split"] == "test" and keep(r)]
        report["slices"][key] = replay(
            [records[i] for i in rows], scores[rows], truth[rows], thresholds
        )
    return report


def agreement() -> None:
    """Compare the labels with an independent relabel of 150 messages by another model."""
    lines = (CUSTOM / "labels-agreement-v1.jsonl").read_text().splitlines()
    other = {e["id"]: set(e["categories"]) for e in map(json.loads, lines)}
    records = [r for r in messages() if r["id"] in other]
    truth = load_labels(records)
    relabel = np.array([[c in other[r["id"]] for c in CONCEPTS] for r in records], dtype=bool)
    kappa = {}
    for c, concept in enumerate(CONCEPTS):
        a, b = truth[:, c], relabel[:, c]
        if a.any() or b.any():
            observed = float((a == b).mean())
            expected = a.mean() * b.mean() + (1 - a.mean()) * (1 - b.mean())
            kappa[concept] = {
                "positives": [int(a.sum()), int(b.sum())],
                "kappa": None if expected == 1 else (observed - expected) / (1 - expected),
            }
    real = np.array([r["source"] != "synthetic" for r in records])
    write(
        {
            "run": "agreement",
            "messages": len(records),
            "real_messages": int(real.sum()),
            "exact_match": float((truth == relabel).all(axis=1).mean()),
            "exact_match_real": float((truth[real] == relabel[real]).all(axis=1).mean()),
            "micro_f1": micro_f1(truth, relabel),
            "micro_f1_real": micro_f1(truth[real], relabel[real]),
            "per_category": kappa,
        }
    )


TEMPLATE_VARIANTS = {  # validation-only probe of the hypothesis wording; "category" is HYPOTHESIS
    "category": (HYPOTHESIS, "{text} {description}"),
    "about": (
        {"en": "This email is about {name}.", "cs": "Tento e-mail se týká tématu „{name}“."},
        "{stem}: {description}",
    ),
}


def templates(candidate: str, count: str = "300") -> None:
    """Compare hypothesis wordings on a fixed validation sample, with and without descriptions."""
    import torch

    name, revision = CANDIDATES[candidate]
    tokenizer, model, device, entail, negative = load(name, revision)
    model.eval()
    records = messages()
    truth = load_labels(records)
    rows = [i for i, r in enumerate(records) if r["split"] == "validation"]
    rows = sorted(random.Random(SEED).sample(rows, int(count)))
    sample = [records[i] for i in rows]
    report = {"run": f"templates-{candidate}", "messages": len(rows), "variants": {}}
    for variant, (names, joined) in TEMPLATE_VARIANTS.items():
        for mode in ("name", "description"):
            sequences = []
            for record in sample:
                language = record["language"]
                ids = tokenizer(premise(record, "body256"), add_special_tokens=False)["input_ids"]
                for category in CATEGORIES:
                    text = names[language].format(name=category[language]["name"])
                    if mode == "description":
                        text = joined.format(
                            text=text, stem=text[:-1], description=category[language]["description"]
                        )
                    h = tokenizer(text, add_special_tokens=False)["input_ids"]
                    sequences.append(pair_ids(tokenizer, ids, h, 256))
            order = list(np.argsort([len(x) for x in sequences], kind="stable"))
            scores = np.zeros(len(sequences))
            with torch.no_grad():
                for chunk, ids, mask in batches(
                    sequences, order, tokenizer.pad_token_id, device, 16384
                ):
                    logits = model(input_ids=ids, attention_mask=mask).logits[:, [entail, negative]]
                    scores[chunk] = torch.softmax(logits, dim=-1)[:, 0].cpu().numpy()
            scores = scores.reshape(len(rows), -1)
            every = list(range(len(CATEGORIES)))
            thresholds = calibrate_languages(
                sample, scores, truth[rows], np.ones(len(rows), bool), every
            )
            predicted = decide(sample, scores, thresholds)
            report["variants"][f"{variant}-{mode}"] = {
                language: custom_metrics(truth[rows][mask], predicted[mask], every)["macro_f1"]
                for language in ("en", "cs")
                for mask in [np.array([r["language"] == language for r in sample])]
            } | {"thresholds": thresholds}
            print(variant, mode, report["variants"][f"{variant}-{mode}"], flush=True)
    write(report)


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


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
        candidate = result["candidate"].removesuffix("-adapted")
        model_name, revision = CANDIDATES[candidate]
        source = WORK / "custom-adapted" / candidate if result["adapted"] else None
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
    """Render custom/tables.md from custom/results/*.json; refuse results on other labels."""
    labels = hashlib.sha256(LABELS.read_bytes()).hexdigest()
    results = {}
    for path in sorted((CUSTOM / "results").glob("*.json")):
        report = json.loads(path.read_text())
        if "slices" in report and "thresholds" in report and "groups" in report:
            if report["labels_sha256"] != labels:
                raise ValueError(f"{path.name} was evaluated on other labels; rerun evaluate")
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
        system[f"#828 {name}"] = json.loads((ROOT / "results" / f"{name}.json").read_text())[
            "slices"
        ]
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


def write(report: dict) -> None:
    out = CUSTOM / "results"
    out.mkdir(exist_ok=True)
    (out / f"{report['run']}.json").write_text(
        json.dumps(report, indent=1, ensure_ascii=False) + "\n"
    )
    print(report["run"], "written")


def evaluate_run(name: str) -> None:
    data = np.load(WORK / "custom-scores" / f"{name}.npz")
    if list(data["ids"]) != [r["id"] for r in messages()]:
        raise ValueError("scores were computed on other messages")
    write(evaluate(name, data["scores"], json.loads(str(data["meta"]))))


def keywords() -> None:
    records = messages()
    for input_key in ("minimized", "body"):
        for mode in ("name", "description"):
            name = f"keywords-{input_key}-{mode}"
            meta = {"method": "keywords", "input": input_key, "mode": mode}
            write(evaluate(name, keyword_scores(records, input_key, mode), meta))


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    {
        "annotate": annotate,
        "labels": labels,
        "adapt": adapt,
        "score": score,
        "evaluate": evaluate_run,
        "keywords": keywords,
        "agreement": agreement,
        "templates": templates,
        "golden": golden,
        "tables": tables,
        "overrides": lambda name: write(overrides(name)),
    }[command](*args)
