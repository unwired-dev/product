# DeBERTa Core ML export (spike #831)

Converts the four candidates that [#829](https://github.com/unwired-dev/product/issues/829)
froze in `../system-category-benchmark/custom/bundle-v1.json` to Core ML, and checks
each export against the frozen golden outputs on this Mac. The Mac host runs the
exports in the [categorization spike](../../docs/categorization-spike.md). Findings
and measurements are in [REPORT.md](REPORT.md).

This is a separate uv project so the #828/#829 benchmark digests, which hash that
project's `uv.lock`, stay valid. It reads the bundle, golden outputs and Custom
Category definitions from the benchmark and never changes them.

## Run it

The weights are not committed. Reproduce them with the benchmark's commands
(`run.py deberta xsmall body256`, `run.py deberta mdeberta body512` and
`custom.py adapt` for the two Custom candidates), then pass each weights directory.
`export.py` refuses weights whose SHA-256 differs from the frozen bundle and
tokenizers whose SHA-256 differs from the files verified against every golden
input ID, before replacing any output.

```sh
cd tools/deberta-mac-spike
mise trust .mise.toml && mise install
mise exec -- uv sync

benchmark=../system-category-benchmark/work
mise exec -- uv run python export.py deberta-xsmall-body256 "$benchmark/runs/deberta-xsmall-body256"
mise exec -- uv run python export.py deberta-mdeberta-body512 "$benchmark/runs/deberta-mdeberta-body512"
mise exec -- uv run python export.py xsmall-zs-adapted-body256-description "$benchmark/custom-adapted/xsmall-zs"
mise exec -- uv run python export.py mdeberta-nli-adapted-body256-description "$benchmark/custom-adapted/mdeberta-nli"
```

Each run writes `work/models/<run>/` (ignored): `fp16.mlmodelc`, `int8.mlmodelc`,
the tokenizer and a `manifest.json` with the candidate's thresholds and labels. It
writes `results/<run>.json` (committed): sizes, INT8 quantization coverage and, for
each precision and compute unit, the largest absolute probability difference from
the fp32 golden outputs, the decisions that changed and Python prediction latency.
A run exits with status 1 when an export exceeds its tolerance (0.02 for FP16, 0.05
for INT8) after writing its artifacts and result, so the overrun stays on record.

## Conversion

Core ML Tools 9.0 converts a traced PyTorch 2.7.0 graph to an FP16 ML Program for
macOS 15 or later, with fixed `[1, max_length]` inputs. INT8 applies per-channel
symmetric linear weight quantization to every large weight, the word embeddings
included; activations stay FP16. The conversion needs three patches to the Hugging
Face DeBERTa v2 model, applied only inside `export.py`:

- **Scripted helpers.** Six `@torch.jit.script` functions keep shape-dependent
  control flow that Core ML cannot type (`rel_pos_ids` branch types differ); the
  export traces their Python bodies instead.
- **Attention scale.** The tracer keeps `sqrt(head size)` as an int32, which MIL's
  `sqrt` rejects; a converter override casts it to fp32.
- **Mask fill.** The attention mask fills with fp32's minimum, which becomes `-inf`
  in FP16; fully masked padding rows then turn NaN on the CPU and spread through
  later layers. The export fills with `-1e4`, which leaves every unmasked score
  unchanged.

The original experiments with enumerated or flexible sequence lengths reported
Core ML prediction crashes (SIGSEGV) on macOS 27.0.1. To exercise either path
without changing `work/models` or the fixed-export results, run one opt-in probe:

```sh
mise exec -- uv run python probe/shapes.py deberta-xsmall-body256 "$benchmark/runs/deberta-xsmall-body256" --shape enumerated --timeout 300
# Substitute --shape flexible to try a bounded sequence-length range.
```

The probe reuses the FP16 converter, checks the frozen weights hash, and predicts
at half and full token budgets on CPU_ONLY. Enumerated inputs allow those two
lengths; flexible inputs allow 1 through the full budget. A subprocess contains
prediction crashes and limits conversion plus prediction to 300 seconds. Temporary
models go under ignored `work/` and are removed afterward. The probe writes
`results/shape-<run>-<shape>.json` with the command, versions, hash, progress,
exit code, signal, timeout and stderr tail. It exits 1 for a failed or timed-out
worker. These are failure probes, not parity checks or alternate deployable exports.
The retained [enumerated XSmall run](results/shape-deberta-xsmall-body256-enumerated.json)
converted and predicted at 128 tokens, then failed at 256 tokens with Core ML error
`-5`, exit 1 and no signal in 44.7 seconds. The flexible path was not rerun, and the
original SIGSEGV observation has no retained crash log.

NumPy 2.4 and later break Core ML Tools 9.0 (`only 0-dimensional arrays can be
converted`); this project pins NumPy below 2.4. PyTorch 2.7.1 and later are untested
by Core ML Tools 9.0. Neither dependency-upgrade path has a retained reproduction.

## Test

```sh
mise exec -- uv run pytest
mise exec -- uv run ruff check . && mise exec -- uv run ruff format --check .
cd ../../native/categorization-spike && swift test
```

The unattended `probe/autorun.zsh App.app matrix` run validates all 43 expected
successful action records before exiting successfully and saves `host-tables.md`
beside the raw evidence. Failed, missing, duplicate or unexpected actions fail
the run. To validate a retained matrix, run
`mise exec -- uv run python summarize.py --check-matrix results/host-matrix-2026-10-15.jsonl`
from this directory. The `states` run similarly requires both sample results,
including Custom abstention, and its two intentional cancellations and releases
with `--check-states`. Ordinary summaries still accept mixed result and lifecycle
records without either check flag.
