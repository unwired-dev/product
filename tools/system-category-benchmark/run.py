"""Train, calibrate and evaluate one method on the frozen corpus.

uv run python run.py rules                       # existing keyword rules, minimized then body
uv run python run.py tfidf                       # word and character TF-IDF logistic regression
uv run python run.py deberta <model> <input> [seed]  # model: xsmall | small | mdeberta
                                                     # input: minimized | body128 | body256 | body512
"""

import hashlib
import json
import random
import sys
import time
from pathlib import Path

import numpy as np

import corpus
import rules

ROOT = Path(__file__).parent
WORK = ROOT / "work"
RESULTS = ROOT / "results"
CATEGORIES = corpus.CATEGORIES
SEED = 828
MODELS = {
    "xsmall": ("microsoft/deberta-v3-xsmall", "4b419818330868dff6a60ad3e6b1c730f8b8c0c6"),
    "small": ("microsoft/deberta-v3-small", "a36c739020e01763fe789b4b85e2df55d6180012"),
    "mdeberta": ("microsoft/mdeberta-v3-base", "a0484667b22365f84929a935b5e50a51f71f159d"),
}
INPUTS = {"minimized": 128, "body128": 128, "body256": 256, "body512": 512}
HYPERPARAMETERS = {
    "epochs": 4,
    "batch_size": 16,
    "learning_rate": 5e-5,
    "warmup": 0.1,
    "weight_decay": 0.01,
    # Memory only: a batch is split into micro-batches of at most this many padded tokens and
    # its gradients accumulated, so mDeBERTa at 512 tokens fits a 16 GB Mac.
    "microbatch_tokens": 2048,
}


def snippet(record: dict) -> str:
    # Gmail-style snippet: the first 200 characters of normalized body text.
    return corpus.normalize(record["body"])[:200]


def minimized(record: dict) -> str:
    return "\n".join(
        [
            f"From: {record['from']}",
            f"Reply-To: {record['reply_to']}",
            f"Mailing list: {'yes' if record['list'] else 'no'}",
            f"Recipients: {record['recipients']}",
            f"Subject: {corpus.normalize(record['subject'])}",
            f"Snippet: {snippet(record)}",
        ]
    )


def with_body(record: dict) -> str:
    # The tokenizer truncates this to the token budget, so the body fills what remains.
    return minimized(record) + "\nBody: " + corpus.normalize(record["body"])[200:]


def load_corpus() -> dict[str, list[dict]]:
    records = [json.loads(line) for line in (WORK / "corpus.jsonl").read_text().splitlines()]
    manifest = json.loads(corpus.MANIFEST.read_text())
    test = sorted((r["id"], tuple(r["labels"])) for r in records if r["split"] == "test")
    frozen = hashlib.sha256(json.dumps(test).encode()).hexdigest()
    if (
        frozen != manifest["frozen_test_sha256"]
        or corpus.corpus_sha256(records) != manifest["corpus_sha256"]
    ):
        raise ValueError("corpus inputs or split membership differ from the frozen manifest")
    return {
        split: [r for r in records if r["split"] == split]
        for split in ("train", "validation", "test")
    }


def gold(records: list[dict]) -> np.ndarray:
    return np.array([[c in r["labels"] for c in CATEGORIES] for r in records], dtype=bool)


def decide(probabilities: np.ndarray, thresholds: np.ndarray) -> np.ndarray:
    """Independent purpose decisions; People only as the fallback when none applies."""
    predicted = probabilities >= thresholds
    predicted[:, 4] &= ~predicted[:, :4].any(axis=1)
    return predicted


def f1(truth: np.ndarray, predicted: np.ndarray) -> float:
    tp = (truth & predicted).sum()
    return 0.0 if tp == 0 else 2 * tp / (truth.sum() + predicted.sum())


def calibrate(probabilities: np.ndarray, truth: np.ndarray) -> np.ndarray:
    """Pick each threshold on validation to maximize F1; People after the purpose thresholds."""
    grid = np.round(np.arange(0.05, 0.96, 0.05), 2)
    thresholds = np.full(5, 0.5)
    for column in range(4):
        if truth[:, column].any():
            scores = [f1(truth[:, column], probabilities[:, column] >= t) for t in grid]
            thresholds[column] = grid[
                len(grid) - 1 - int(np.argmax(scores[::-1]))
            ]  # ties: abstain more
    scores = []
    for t in grid:
        thresholds[4] = t
        scores.append(f1(truth[:, 4], decide(probabilities, thresholds)[:, 4]))
    thresholds[4] = grid[len(grid) - 1 - int(np.argmax(scores[::-1]))]
    return thresholds


def slice_metrics(records: list[dict], truth: np.ndarray, predicted: np.ndarray) -> dict:
    per_category = {}
    for column, category in enumerate(CATEGORIES):
        t, p = truth[:, column], predicted[:, column]
        tp = int((t & p).sum())
        per_category[category] = {
            "support": int(t.sum()),
            "predicted": int(p.sum()),
            "precision": tp / p.sum() if p.sum() else None,
            "recall": tp / t.sum() if t.sum() else None,
            "f1": f1(t, p) if t.sum() else None,
        }
    supported = [c for c in range(5) if truth[:, c].any()]

    def macro(rows):
        return float(np.mean([f1(truth[rows, c], predicted[rows, c]) for c in supported]))

    rng = np.random.default_rng(SEED)
    samples = [macro(rng.integers(0, len(records), len(records))) for _ in range(1000)]
    multi = truth.sum(axis=1) > 1
    return {
        "messages": len(records),
        "macro_f1": macro(np.arange(len(records))) if supported else None,
        "macro_f1_ci95": [float(np.percentile(samples, 2.5)), float(np.percentile(samples, 97.5))]
        if supported
        else None,
        "macro_over": [CATEGORIES[c] for c in supported],
        "exact_match": float((truth == predicted).all(axis=1).mean()),
        "coverage": float(predicted.any(axis=1).mean()),
        "gold_coverage": float(truth.any(axis=1).mean()),
        "uncategorized_precision": float(
            (~truth.any(axis=1) & ~predicted.any(axis=1)).sum()
            / max(1, (~predicted.any(axis=1)).sum())
        ),
        "uncategorized_recall": float(
            (~truth.any(axis=1) & ~predicted.any(axis=1)).sum() / max(1, (~truth.any(axis=1)).sum())
        ),
        "overlap_messages": int(multi.sum()),
        "overlap_errors": int((multi & ~(truth == predicted).all(axis=1)).sum()),
        "people_false_positives": int((predicted[:, 4] & ~truth[:, 4]).sum()),
        "people_false_positives_on_uncategorized": int(
            (predicted[:, 4] & ~truth.any(axis=1)).sum()
        ),
        "per_category": per_category,
    }


def evaluate(name: str, test: list[dict], predicted: np.ndarray, extra: dict) -> None:
    truth = gold(test)
    slices = {"all": np.ones(len(test), dtype=bool)}
    for key in sorted({(r["language"], r["stratum"]) for r in test}):
        slices["/".join(key)] = np.array([(r["language"], r["stratum"]) == key for r in test])
    report = {"run": name, **extra, "slices": {}}
    for key, mask in slices.items():
        rows = np.flatnonzero(mask)
        report["slices"][key] = slice_metrics([test[i] for i in rows], truth[rows], predicted[rows])
    errors = [
        {
            "id": r["id"],
            "slice": f"{r['language']}/{r['stratum']}",
            **({"subject": r["subject"][:80]} if r["stratum"] == "synthetic" else {}),
            "gold": r["labels"],
            "predicted": [c for c, p in zip(CATEGORIES, row) if p],
        }
        for r, row, t in zip(test, predicted, truth)
        if (row != t).any()
    ]
    report["errors"] = errors
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / f"{name}.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")
    overall = report["slices"]["all"]
    print(
        f"{name}: macro-F1 {overall['macro_f1']:.3f} {overall['macro_f1_ci95']} errors {len(errors)}"
    )


def run_rules(splits: dict) -> None:
    for variant, use_body in [("minimized", False), ("body", True)]:
        predicted = np.array(
            [
                [c in assigned for c in CATEGORIES]
                for r in splits["test"]
                for assigned in [
                    rules.classify(
                        r["from"],
                        r["reply_to"],
                        r["subject"],
                        snippet(r),
                        r["body"] if use_body else None,
                    )
                ]
            ],
            dtype=bool,
        )
        evaluate(
            f"rules-{variant}", splits["test"], predicted, {"method": "rules", "input": variant}
        )


def run_tfidf(splits: dict) -> None:
    from scipy.sparse import hstack
    from sklearn.feature_extraction.text import TfidfVectorizer
    from sklearn.linear_model import LogisticRegression

    for variant, text in [("minimized", minimized), ("body", with_body)]:
        started = time.time()
        word = TfidfVectorizer(ngram_range=(1, 2), min_df=2, sublinear_tf=True)
        char = TfidfVectorizer(
            analyzer="char_wb",
            ngram_range=(2, 5),
            min_df=2,
            sublinear_tf=True,
            max_features=200_000,
        )
        train_text = [text(r) for r in splits["train"]]
        features = hstack([word.fit_transform(train_text), char.fit_transform(train_text)]).tocsr()

        truth = gold(splits["train"])
        classifiers = [
            LogisticRegression(C=4.0, class_weight="balanced", max_iter=2000).fit(
                features, truth[:, c]
            )
            for c in range(5)
        ]

        def probabilities(records, text=text, word=word, char=char, classifiers=classifiers):
            values = [text(r) for r in records]
            matrix = hstack([word.transform(values), char.transform(values)]).tocsr()
            return np.column_stack([clf.predict_proba(matrix)[:, 1] for clf in classifiers])

        thresholds = calibrate(probabilities(splits["validation"]), gold(splits["validation"]))
        seconds = time.time() - started
        predicted = decide(probabilities(splits["test"]), thresholds)
        evaluate(
            f"tfidf-{variant}",
            splits["test"],
            predicted,
            {
                "method": "tfidf-logistic-regression",
                "input": variant,
                "thresholds": dict(zip(CATEGORIES, thresholds.tolist())),
                "train_seconds": round(seconds, 1),
            },
        )


def run_deberta(splits: dict, model_key: str, input_key: str, seed: int = SEED) -> None:
    import torch
    from transformers import (
        AutoModelForSequenceClassification,
        AutoTokenizer,
        get_linear_schedule_with_warmup,
    )

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    name, revision = MODELS[model_key]
    max_length = INPUTS[input_key]
    text = minimized if input_key == "minimized" else with_body
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tokenizer = AutoTokenizer.from_pretrained(name, revision=revision)
    # The checkpoints are stored in float16; AdamW on float16 weights turns NaN after one step.
    model = AutoModelForSequenceClassification.from_pretrained(
        name,
        revision=revision,
        num_labels=5,
        problem_type="multi_label_classification",
        dtype=torch.float32,
    ).to(device)

    def encode(records):
        return tokenizer([text(r) for r in records], truncation=True, max_length=max_length)[
            "input_ids"
        ]

    size = HYPERPARAMETERS["batch_size"]

    def batches(ids, groups, labels=None):
        for chunk in groups:
            width = max(len(ids[i]) for i in chunk)
            input_ids = torch.tensor(
                [ids[i] + [tokenizer.pad_token_id] * (width - len(ids[i])) for i in chunk],
                device=device,
            )
            mask = torch.tensor(
                [[1] * len(ids[i]) + [0] * (width - len(ids[i])) for i in chunk], device=device
            )
            yield (
                input_ids,
                mask,
                None
                if labels is None
                else torch.tensor(labels[chunk], dtype=torch.float32, device=device),
            )

    def length_grouped(ids, rng):
        # Like transformers' group_by_length: sort shuffled 50-batch windows by length so each
        # batch pads to similar lengths, then shuffle the batches.
        order = rng.permutation(len(ids))
        groups = []
        for start in range(0, len(order), 50 * size):
            window = sorted(order[start : start + 50 * size], key=lambda i: -len(ids[i]))
            groups += [window[j : j + size] for j in range(0, len(window), size)]
        return [groups[i] for i in rng.permutation(len(groups))]

    train_ids, truth = encode(splits["train"]), gold(splits["train"])
    steps = HYPERPARAMETERS["epochs"] * -(-len(train_ids) // size)
    optimizer = torch.optim.AdamW(
        model.parameters(),
        lr=HYPERPARAMETERS["learning_rate"],
        weight_decay=HYPERPARAMETERS["weight_decay"],
    )
    schedule = get_linear_schedule_with_warmup(
        optimizer, int(HYPERPARAMETERS["warmup"] * steps), steps
    )
    started = time.time()
    model.train()
    rng = np.random.default_rng(seed)
    peak_memory = 0
    for _ in range(HYPERPARAMETERS["epochs"]):
        for group in length_grouped(train_ids, rng):
            width = max(len(train_ids[i]) for i in group)
            micro = max(1, HYPERPARAMETERS["microbatch_tokens"] // width)
            chunks = [group[j : j + micro] for j in range(0, len(group), micro)]
            for (input_ids, mask, labels), chunk in zip(batches(train_ids, chunks, truth), chunks):
                loss = model(input_ids=input_ids, attention_mask=mask, labels=labels).loss
                # The loss is a mean, so weight each micro-batch to reproduce the batch mean.
                (loss * len(chunk) / len(group)).backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            schedule.step()
            optimizer.zero_grad()
            if device == "mps":
                peak_memory = max(peak_memory, torch.mps.driver_allocated_memory())
                # Without this the MPS allocator caches every batch shape and a 16 GB Mac swaps.
                torch.mps.empty_cache()
    if device == "mps":
        torch.mps.synchronize()
    train_seconds = time.time() - started
    model.eval()

    @torch.no_grad()
    def probabilities(records):
        ids = encode(records)
        order = np.argsort([len(i) for i in ids])
        groups = [order[start : start + size] for start in range(0, len(order), size)]
        output = np.zeros((len(ids), 5))
        for (input_ids, mask, _), chunk in zip(batches(ids, groups), groups):
            logits = model(input_ids=input_ids, attention_mask=mask).logits
            output[chunk] = torch.sigmoid(logits).cpu().numpy()
        return output

    thresholds = calibrate(probabilities(splits["validation"]), gold(splits["validation"]))
    predicted = decide(probabilities(splits["test"]), thresholds)
    run = f"deberta-{model_key}-{input_key}" + ("" if seed == SEED else f"-seed{seed}")
    output = WORK / "runs" / run
    model.save_pretrained(output)
    tokenizer.save_pretrained(output)
    (output / "thresholds.json").write_text(
        json.dumps(dict(zip(CATEGORIES, thresholds.tolist())), indent=2) + "\n"
    )
    evaluate(
        run,
        splits["test"],
        predicted,
        {
            "method": "deberta-fine-tune",
            "model": name,
            "revision": revision,
            "input": input_key,
            "max_length": max_length,
            "hyperparameters": HYPERPARAMETERS,
            "seed": seed,
            "device": device,
            "dtype": "float32",
            "torch": torch.__version__,
            "parameters": sum(p.numel() for p in model.parameters()),
            "train_examples": len(train_ids),
            "train_seconds": round(train_seconds, 1),
            "truncated_train_fraction": float(np.mean([len(i) >= max_length for i in train_ids])),
            "peak_device_memory_mib": round(peak_memory / 2**20) if device == "mps" else None,
            "thresholds": dict(zip(CATEGORIES, thresholds.tolist())),
        },
    )


if __name__ == "__main__":
    splits = load_corpus()
    {"rules": lambda: run_rules(splits), "tfidf": lambda: run_tfidf(splits)}.get(
        sys.argv[1], lambda: run_deberta(splits, sys.argv[2], sys.argv[3], *map(int, sys.argv[4:5]))
    )()
