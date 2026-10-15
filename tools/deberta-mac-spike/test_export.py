from pathlib import Path

import pytest

import export


def test_mismatched_tokenizer_stops_before_writing(monkeypatch, tmp_path: Path) -> None:
    run = "deberta-xsmall-body256"
    _, entry = export.candidate(run)
    digests = {"model.safetensors": entry["weights_sha256"], "tokenizer.json": "0" * 64}
    monkeypatch.setattr(export, "sha256_file", lambda path: digests[path.name])
    monkeypatch.setattr(export, "MODELS", tmp_path / "models")
    with pytest.raises(SystemExit, match="tokenizer"):
        export.export(run, tmp_path)
    assert not (tmp_path / "models").exists()
