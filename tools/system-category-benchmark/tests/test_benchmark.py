import json

import numpy as np
import pytest

import corpus
import rules
import run
import synthetic


def test_rules_match_the_swift_prototype_cases():
    # MessageCategorizationServiceTests.testRuleBasedEngineUsesPeopleOnlyAsFallback
    alice = "Alice <alice@example.com>"
    assert rules.classify(alice, "", "Dinner", "See you tomorrow", None) == []
    assert rules.classify(
        alice, "", "Dinner", "See you tomorrow", "Dinner plans for tomorrow."
    ) == ["People"]
    assert rules.classify(alice, "", "Dinner after landing", "Your flight itinerary", None) == [
        "Flights"
    ]
    assert rules.classify("News <noreply@shop.example>", "", "Hi", "Weekly digest", "Hello") == []


def test_people_is_only_a_fallback():
    probabilities = np.array([[0.9, 0.1, 0.1, 0.8, 0.9], [0.1, 0.1, 0.1, 0.1, 0.9], [0.1] * 5])
    predicted = run.decide(probabilities, np.full(5, 0.5))
    assert predicted.tolist() == [
        [True, False, False, True, False],
        [False, False, False, False, True],
        [False] * 5,
    ]


def test_synthetic_test_templates_are_never_trained():
    records = synthetic.generate()
    corpus.assign_splits(records)
    by_split = {}
    for record in records:
        by_split.setdefault(record["split"], set()).add(record["template"])
    assert not by_split["train"] & (by_split["validation"] | by_split["test"])
    for language in ("en", "cs"):
        tested = {t.rsplit("-", 1)[0] for t in by_split["test"] if t.startswith(language)}
        assert tested == {f"{language}-{group}" for group in synthetic.TEMPLATES[language]}


def test_real_messages_sharing_a_sender_body_or_thread_stay_in_one_split():
    def message(id_, sender, subject, body, source="enron"):
        return {
            "id": id_,
            "stratum": "real-random",
            "source": source,
            "from": sender,
            "subject": subject,
            "body": body,
        }

    records = [
        message(str(i), f"person{i}@enron.com", f"Topic {i}", f"Body {i}") for i in range(60)
    ]
    records += [
        message(f"dilbert-{i}", f"bulk{i}@example.com", f"Daily strip {i}", "Same strip")
        for i in range(10)
    ]
    records += [
        message(
            f"list-{archive}",
            f"{archive}@example.com",
            "Re: build fails",
            f"Reply {archive}",
            source,
        )
        for archive, source in [("a", "spamassassin-easy_ham"), ("b", "spamassassin-easy_ham_2")]
    ]
    records += [
        message(f"sender-{i}", "boss@enron.com", f"Memo {i}", f"Memo {i}") for i in range(5)
    ]
    corpus.assign_splits(records)
    assert len({r["split"] for r in records}) == 3
    for prefix in ("dilbert-", "list-", "sender-"):
        assert len({r["split"] for r in records if r["id"].startswith(prefix)}) == 1


def test_synthetic_senders_never_span_splits():
    records = synthetic.generate()
    corpus.assign_splits(records)
    splits = {}
    for record in records:
        address = corpus.sender_address(record["from"])
        splits.setdefault(address, set()).add(record["split"])
    assert all(len(found) == 1 for found in splits.values())


def test_rebuild_preserves_the_frozen_corpus_and_evaluation_rejects_input_changes(
    tmp_path, monkeypatch
):
    records = synthetic.generate()
    selected = [
        next(r for r in records if synthetic.template_split(r["template"]) == split)
        for split in ("train", "validation", "test")
    ]
    work = tmp_path / "work"
    work.mkdir()
    (work / "candidates.jsonl").write_text("")
    labels = tmp_path / "labels.jsonl"
    labels.write_text("")
    (tmp_path / "synthetic.py").write_text("fixture generator")
    (tmp_path / "corpus").mkdir()
    manifest = tmp_path / "corpus" / "manifest-v1.json"
    for module in (corpus, run):
        monkeypatch.setattr(module, "ROOT", tmp_path)
        monkeypatch.setattr(module, "WORK", work)
    monkeypatch.setattr(corpus, "LABELS", labels)
    monkeypatch.setattr(corpus, "MANIFEST", manifest)
    monkeypatch.setattr(synthetic, "generate", lambda: [dict(r) for r in selected])
    corpus.build()
    frozen_manifest = manifest.read_bytes()
    frozen_corpus = (work / "corpus.jsonl").read_bytes()
    corpus.build()
    assert manifest.read_bytes() == frozen_manifest
    assert (work / "corpus.jsonl").read_bytes() == frozen_corpus
    assert len(run.load_corpus()["test"]) == 1

    selected[-1]["body"] = "Changed held-out input"
    with pytest.raises(ValueError, match="frozen manifest"):
        corpus.build()
    assert manifest.read_bytes() == frozen_manifest
    assert (work / "corpus.jsonl").read_bytes() == frozen_corpus

    original = [json.loads(line) for line in frozen_corpus.splitlines()]
    for field in ("subject", "body", "from", "split"):
        changed = [dict(r) for r in original]
        changed[-1][field] = "train" if field == "split" else "Changed input"
        (work / "corpus.jsonl").write_text("\n".join(map(json.dumps, changed)))
        with pytest.raises(ValueError, match="frozen manifest"):
            run.load_corpus()
    changed = original + [{**original[-1], "split": "train"}]
    (work / "corpus.jsonl").write_text("\n".join(map(json.dumps, changed)))
    with pytest.raises(ValueError, match="frozen manifest"):
        run.load_corpus()


def test_saved_errors_keep_public_ids_and_only_synthetic_subjects(tmp_path, monkeypatch):
    monkeypatch.setattr(run, "RESULTS", tmp_path)
    test = [
        {
            "id": "public:1",
            "language": "en",
            "stratum": "real-random",
            "subject": "Public mail text",
            "labels": ["People"],
        },
        {
            "id": "synthetic:1",
            "language": "en",
            "stratum": "synthetic",
            "subject": "Synthetic example",
            "labels": ["People"],
        },
    ]
    run.evaluate("redaction", test, np.zeros((2, 5), dtype=bool), {})
    result = json.loads((tmp_path / "redaction.json").read_text())
    assert "Public mail text" not in (tmp_path / "redaction.json").read_text()
    assert result["errors"][0]["id"] == "public:1"
    assert "subject" not in result["errors"][0]
    assert result["errors"][1]["subject"] == "Synthetic example"
