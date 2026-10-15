import json

import numpy as np
import pytest

import custom_benchmark as custom
import custom_report
import custom_synthetic


class Tokenizer:
    cls_token_id, sep_token_id = 1, 2


def test_only_the_message_is_truncated_to_fit_the_hypothesis():
    assert custom.pair_ids(Tokenizer(), [10, 11, 12, 13], [20, 21], 8) == [
        1,
        10,
        11,
        12,
        2,
        20,
        21,
        2,
    ]
    with pytest.raises(ValueError):
        custom.pair_ids(Tokenizer(), [10], [20] * 6, 8)


def test_custom_synthetic_has_no_training_split_and_no_shared_senders():
    records = custom_synthetic.generate()
    assert {r["split"] for r in records} == {"validation", "test"}
    for language in ("en", "cs"):
        domains = {
            split: {
                r["from"].rsplit("@", 1)[1]
                for r in records
                if r["split"] == split and r["language"] == language
            }
            for split in ("validation", "test")
        }
        assert not (domains["validation"] & domains["test"]) - {"mail.example>"}
        senders = {
            split: {r["from"] for r in records if r["split"] == split and r["language"] == language}
            for split in ("validation", "test")
        }
        assert not senders["validation"] & senders["test"]


def test_ambiguous_names_have_a_hard_negative_in_every_split():
    for theme in ("statements", "club-membership", "project-updates"):
        for templates in custom_synthetic.TEMPLATES[theme]:
            assert len(templates) == 4  # positive and negative for validation, then for test


def test_every_message_has_valid_labels():
    lines = custom.LABELS.read_text().splitlines()
    labels = {e["id"]: e["categories"] for e in map(json.loads, lines)}
    assert labels.keys() == {r["id"] for r in custom.messages()}
    assert {c for cs in labels.values() for c in cs} <= set(custom.CONCEPTS)


def test_category_definitions_respect_product_limits():
    names = set()
    for category in custom.CATEGORIES:
        for language in ("en", "cs"):
            definition = category[language]
            assert 1 <= len(definition["name"].strip()) <= 40
            assert len(definition["description"]) <= 500
            assert len(definition["paraphrase"]) <= 500
        names.add(category["en"]["name"].lower())
    assert len(names) == len(custom.CATEGORIES)
    assert not names & {"orders", "newsletters & promotions", "people", "invites", "flights"}


def test_one_threshold_prefers_abstaining_on_ties():
    scores = np.array([[0.9, 0.2], [0.4, 0.95]])
    truth = np.array([[True, False], [False, True]])
    assert custom.calibrate(scores, truth) == 0.9  # the highest threshold keeping both


def test_signals_change_only_later_messages_from_the_same_sender():
    records = [
        {"id": "1", "date": "1", "from": "Shop <a@shop.example>", "language": "en"},
        {"id": "2", "date": "2", "from": "Shop <a@shop.example>", "language": "en"},
        {"id": "3", "date": "3", "from": "Other <b@other.example>", "language": "en"},
    ]
    scores = np.array([[0.1, 0.9], [0.1, 0.9], [0.1, 0.9]])
    truth = np.array([[True, False], [True, False], [False, True]])
    result = custom.replay(records, scores, truth, {"en": 0.5})
    # Message 1 is wrong on both categories and is corrected by the user; message 2 inherits
    # both signals; message 3 is from another sender and keeps the model decision.
    assert result["signals"] == {"positive": 1, "negative": 1}
    assert result["decisions_changed_by_signals"] == 2
    assert result["changed_decisions_correct"] == 2
    assert result["micro_f1_model_only"] < result["micro_f1_with_signals"]


def test_keyword_stems_fold_czech_diacritics_and_drop_stopwords():
    assert custom.stems("Účty k zaplacení", "cs") == {"ucty", "zapla"}
    assert custom.stems("Bills to pay", "en") == {"bills", "pay"}


@pytest.mark.parametrize(
    "field", ["corpus_sha256", "categories_sha256", "benchmark_sha256", "weights_sha256"]
)
def test_evaluate_refuses_stale_cached_scores(tmp_path, monkeypatch, field):
    records = custom.messages()
    metadata = {**custom.provenance(), field: "stale"}
    if field == "weights_sha256":
        metadata.update(adapted=True, candidate="xsmall-zs-adapted")
        weights = tmp_path / "custom-adapted" / "xsmall-zs" / "model.safetensors"
        weights.parent.mkdir(parents=True)
        weights.write_bytes(b"replacement-weights")
    monkeypatch.setattr(custom, "WORK", tmp_path)
    (tmp_path / "custom-scores").mkdir()
    np.savez_compressed(
        tmp_path / "custom-scores" / "stale.npz",
        ids=np.array([r["id"] for r in records]),
        scores=np.zeros((len(records), len(custom.CATEGORIES))),
        meta=json.dumps(metadata),
    )
    with pytest.raises(ValueError, match=field):
        custom.evaluate_run("stale")


@pytest.mark.parametrize("field", ["categories_sha256", "benchmark_sha256", "labels_sha256"])
def test_tables_refuses_stale_reports(tmp_path, monkeypatch, field):
    metadata = custom.provenance() | {"labels_sha256": custom.sha256_file(custom.LABELS)}
    result = {
        **metadata,
        "run": "stale",
        "groups": {},
        "slices": {},
        "thresholds": {},
        field: "stale",
    }
    (tmp_path / "results").mkdir()
    (tmp_path / "results" / "stale.json").write_text(json.dumps(result))
    monkeypatch.setattr(custom_report, "CUSTOM", tmp_path)
    with pytest.raises(ValueError, match=field):
        custom_report.tables()
