# System Category benchmark: architecture notes

Reviewer-only companion to [the benchmark guide](../../tools/system-category-benchmark/README.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Issue [#828](https://github.com/unwired-dev/product/issues/828) governs this isolated
comparison; [#827](https://github.com/unwired-dev/product/issues/827) governs the
later synthesis. Neither authorizes production integration or model adoption.

## Scope and authority

The standalone Python/uv project is research tooling outside the pnpm workspace.
Its lockfile is not a second JavaScript workspace or a native renderer dependency.
It imports no application code and writes no Inbox assignments. Public sources
and generated examples live under ignored `work/`; committed real-mail evidence
contains source IDs, labels and metrics rather than subjects or bodies.

The comparison follows the [DeBERTa research assessment](../research/deberta-v3-email-classification.md)
for checkpoint totals, task fine-tuning, token budgets including special tokens,
independent category decisions and separate Czech evaluation. The issue takes
precedence over the assessment's proposed base-model comparison and native-export
steps, which are not #828 deliverables. PyTorch fp32 files and sampled training
allocations are not deployment sizes or native inference evidence.

[ADR 0007](../adr/0007-classification-engine-interface.md) and
[ADR 0024](../adr/0024-allow-multiple-categories-per-message.md) retain the local,
minimized-first boundary, purpose-category overlap, People fallback, Uncategorized
State and future-only User Override semantics. This tool measures batch input
variants; it implements neither conditional production body access nor learning
from User Overrides. No provider fetch, cloud fallback or historical assignment
path is added to the product. [ADR 0069](../adr/0069-expand-the-apple-launch-to-power-user-mail.md)
does not turn this spike into launch qualification.

## Training implementation

The published checkpoints contain float16 tensors. The implementation casts
weights to fp32 because AdamW training on the loaded float16 weights diverged to
NaN. Length-grouped batches reduce padding; gradients from micro-batches weighted
by their share of the effective batch reproduce its mean loss. A 2,048-padded-token
budget and per-step MPS cache release avoid allocator growth and swapping on the
16 GB training Mac. These mechanisms change memory use, not the requested token
budget or effective batch size. Reproduction settings remain in the operational
guide and `run.py`.

Corpus v2 groups real messages with union-find over sender address, normalized
body and normalized subject within a source family. SpamAssassin archives share
one family, keeping cross-archive Threads together. Synthetic templates and
sender-identifying slot values are held out by split. Personal addresses still
share `mail.example`; shop and airline domains are disjoint. Build-time checks
reject any sender address, normalized body or real Thread spanning splits, and
ordinary rebuilds verify the frozen full-record digest instead of replacing it.
Time is not separated, and individual-message bootstrap intervals do not account
for sender, Thread or template clustering. These limitations remain disclosed.

## Annotation decision

Question: label the real-public stratum with LLM-agent annotation under the rubric
and disclose it (A), or keep only synthetic labels and report real-world quality
as unavailable (B)? Votes: Claude Fable 5.1 A, GPT-6-Astra A, GPT-6.1-Sol B.
Outcome: A. The dissent says agent labels measure agreement with the annotator,
not accuracy; the report treats real-public scores that way. No human verification
or authorization to annotate private mail follows from this choice.

## Split-isolation review decision

The reviewer independently found nine identical-body Daily Dilbert records across
splits, one cross-archive Thread, and 107 synthetic senders shared across splits.
The binary panel considered:

- A: retain v1 as disclosed exploratory/insufficient-evidence results and accept
  the spike as complete without claiming split isolation passed.
- B: keep #828 blocked on corrected grouping and a full rerun; fix independent
  issues within this review's explicit no-full-retraining limit.

Claude Fable 5.1 chose A because the affected real test rows are few and the
reported label/data gaps already prevent adoption. GPT-6.1-Sol and GPT-6-Astra
chose B because avoidable split defects violate a separate acceptance criterion;
disclosing them does not satisfy it. B wins 2–1. The implementer then replaced v1
with corpus v2 and reran all twelve primary DeBERTa configurations, twelve
additional seed runs and four rule/TF-IDF baselines. Round-2 independent review
of all 3,561 reconstructed records found no cross-split sender addresses,
normalized bodies, real Thread keys or synthetic template IDs; both frozen
hashes and all manifest counts matched. This resolves the split-isolation blocker.
The withdrawn v1 results are not evidence for the completed comparison. The
annotation decision and insufficient-evidence limits are unchanged.

## Result provenance

Result loading verifies both the manifest's full-record corpus hash and a shared
digest of `run.py`, `rules.py`, `corpus.py` and `uv.lock`. This includes input
rendering, threshold calibration, training settings, pinned checkpoints and
locked dependencies while allowing the declared model, input-budget and seed
grid. Hashing whole files is deliberately conservative: even a formatting-only
edit invalidates saved results. This avoids an incomplete inventory of settings
or helper functions that can change the experiment.

The 24 original v2 DeBERTa results were migrated to both provenance fields without
retraining. Rules and TF-IDF baselines were rerun to stamp the corpus hash; their
benchmark digests were subsequently backfilled after the same audit. Only TF-IDF
wall times changed. T3 checkpoint `bee7a533` at 2026-10-12 03:11 +02:00 contains the
full-record guard before the v2 grid started at 03:13:43 in the local grid log.
Checkpoint `e8d4bd43` at 03:14 contains the current v2 manifest hash; checkpoints
from `56b2d373` through `e6950c94` contain all 24 byte-identical DeBERTa results
later committed at `2b28b71b`. Their v2 log scores and error counts, training
counts and saved thresholds agree with the results.

Review compared historical and current input rendering for every one of the
3,561 frozen records, verified unchanged model revisions, token budgets,
hyperparameters and seeds, and compared the training, calibration and metric
helper definitions, rules and dependency lockfile. Earlier normalization and
split-grouping refactors preserved the rendered inputs and full corpus digest.
The new experiment digest identifies the compatible instrumented code after
that audit, rather than claiming it was emitted by the original training runs.
The migration changes no predictions, thresholds or metrics. Future experiments
must rerun instead of restamping existing artifacts after a substantive change.

## Extraction inventory

The operational README retains all input fields, token budgets, training settings,
commands, artifact locations, provenance, label caveats and fallback behavior.
Its float16-divergence rationale, batch-memory mechanisms and annotation panel
transcript moved here without changing the experiment. Its grouping description
states v2's measured isolation and remaining time limits.
The report retains requested empirical findings and provisional candidate choices;
it records the v2 rerun and remaining label, data and native-evidence limits explicitly.
