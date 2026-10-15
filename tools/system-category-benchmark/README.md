# System Category benchmark (spike #828)

A reproducible comparison of the existing keyword rules, a cheap text-feature
baseline and fine-tuned DeBERTa v3 XSmall, Small and multilingual mDeBERTa for
the five System Categories in English and Czech. It is research for
[#827](https://github.com/unwired-dev/product/issues/827) and changes nothing in
the apps: no production assignments, historical classification or cloud
fallback. Delivery stays in #649 and #650.

Findings, the recommended candidates and limitations are in [REPORT.md](REPORT.md).
The generated tables are in [results/tables.md](results/tables.md). The Custom
Category comparison (spike #829) reuses this corpus and runner and is described in
[CUSTOM.md](CUSTOM.md).

Corpus v2 replaces v1, which review withdrew because duplicate bodies, one Thread
and synthetic sender addresses crossed splits. Every result was rerun on v2.

## Run it

The tool is a standalone [uv](https://docs.astral.sh/uv/) project outside the
pnpm workspace. A scoped `.mise.toml` pins uv, and uv installs Python 3.12 and the
locked dependencies from `uv.lock`. A clone needs no private data and no bundled
weights: `fetch` downloads the pinned public sources and Hugging Face downloads
the pinned checkpoints on first use. Everything downloaded or trained goes to the
ignored `work/` directory.

```sh
cd tools/system-category-benchmark
mise trust .mise.toml && mise install
mise exec -- uv sync

mise exec -- uv run python corpus.py fetch    # ~490 MB, verified by sha256
mise exec -- uv run python corpus.py select   # deterministic annotation candidates
mise exec -- uv run python corpus.py build    # reconstruct corpus; verify the frozen manifest

mise exec -- uv run python run.py rules
mise exec -- uv run python run.py tfidf
for model in xsmall small mdeberta; do
  for input in minimized body128 body256 body512; do
    mise exec -- uv run python run.py deberta "$model" "$input"
  done
done
for seed in 1 2; do                          # seed variation for selected runs
  mise exec -- uv run python run.py deberta xsmall minimized $seed
  mise exec -- uv run python run.py deberta xsmall body256 $seed
  mise exec -- uv run python run.py deberta small minimized $seed
  mise exec -- uv run python run.py deberta mdeberta minimized $seed
  mise exec -- uv run python run.py deberta mdeberta body512 $seed
  mise exec -- uv run python run.py deberta xsmall body512 $seed
done
mise exec -- uv run python report.py          # results/tables.md

mise exec -- uv run pytest
mise exec -- uv run ruff check . && mise exec -- uv run ruff format --check .
```

`build` refuses a corpus in which any sender address, normalized body or real
Thread spans two splits, and verifies the existing manifest before writing the
reconstructed corpus. Every `run.py` command checks a hash of all records, inputs
and split memberships against `corpus/manifest-v2.json`. Changed data requires a
new corpus version, not replacement of the manifest.
Each result records that corpus hash and a digest of `run.py`, `rules.py`,
`corpus.py` and `uv.lock`. `report.py` refuses results with missing or mismatched
digests. Rerun every result after changing the corpus or any of those files,
including preprocessing, training settings or dependency versions. The intended
model, input-budget and seed variants use the same benchmark digest.
The 24 v2 DeBERTa results had both provenance fields backfilled after a
configuration audit, without retraining. Rules and TF-IDF baselines were rerun to
record the corpus hash; their benchmark digests were then backfilled after the
same audit. Scores, thresholds and errors are unchanged; only TF-IDF wall times
changed.
The twelve primary DeBERTa runs took about 2.5 hours (2.4 hours of training) on an
Apple M4 Mac mini with 16 GB of memory (see the report). PyTorch's MPS backend
is not bitwise deterministic, so a rerun can differ slightly from the committed
results even with the fixed seed (828).

Each DeBERTa run leaves a candidate artifact in `work/runs/<run>/`: the
fine-tuned weights, tokenizer and the validation-calibrated thresholds. The
commands above are the artifact-generation recipe; artifacts are not committed.

## Public data inventory

No public dataset carries these categories, so labels come from the
[rubric](corpus/rubric.md). Spam/ham and other datasets' labels are never mapped
onto System Categories.

| Source                                                                                                                                                                                                  | Provenance and permission                                                                                                                                                                                                                                                        | Language           | Used for            | Fit with the categories                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Enron email corpus, Hugging Face [`corbt/enron-emails`](https://huggingface.co/datasets/corbt/enron-emails) at revision `cfc06c75` (517,401 rows; 243,072 after removing empty and duplicated messages) | Corporate mail made public by the US FERC investigation and [distributed by CMU for research](https://www.cs.cmu.edu/~enron/); the dataset card states no licence. Used for research only; message text is never committed.                                                      | English, 1998–2002 | Real-public stratum | Mostly People and internal business mail; newsletters and meeting requests are common; Orders and Flights are rare and mostly travel-agency or e-commerce mail in personal folders. No mailing-list headers. |
| [SpamAssassin public corpus](https://spamassassin.apache.org/old/publiccorpus/) `20030228` `easy_ham`, `easy_ham_2`, `hard_ham` (4,150 parsed ham messages)                                             | Public-forum mail, mail supplied for publication and newsletters; [the readme](https://spamassassin.apache.org/old/publiccorpus/readme.html) retains sender copyright and prohibits testing in live mail systems. Research use only; text never committed. Spam archives unused. | English, 2002      | Real-public stratum | Discussion mailing-list posts (Uncategorized under the rubric) and commercial newsletters in `hard_ham`; almost no Orders, Invites or Flights.                                                               |
| Synthetic generator ([`synthetic.py`](synthetic.py))                                                                                                                                                    | Written for this spike.                                                                                                                                                                                                                                                          | English and Czech  | Synthetic stratum   | All five categories, Uncategorized, overlaps and hard cases, by construction.                                                                                                                                |

Checked and not used:

- [`imnim/multiclass-email-classification`](https://huggingface.co/datasets/imnim/multiclass-email-classification)
  (MIT, 2,105 rows) and
  [`djeungafrank/email-classification-single-label`](https://huggingface.co/datasets/djeungafrank/email-classification-single-label)
  (MIT, 1,230 rows) look template- or model-generated (`Dear [Recipient]`) and use
  different label schemes (Business, Reminders, Travel & Bookings, Finance & Bills).
  Mapping them would equate unrelated labels.
- Spam/ham sets such as `SetFit/enron_spam` and `diegovelilla/email-classification-dataset`:
  spam labels are not System Categories.
- Czech: no public Czech personal or commercial mail corpus was found. The Hugging
  Face results for Czech email are address lists, not messages. Czech results are
  synthetic only and are not independent real-world Czech validation.

## Corpus v2

`corpus.py select` draws, with seed 828:

- **real-random**: 600 Enron messages and 250 messages sampled from SpamAssassin
  `easy_ham` and `easy_ham_2` together.
- **real-enriched**: 300 Enron messages whose subject matches a broad enrichment
  pattern, all 250 `hard_ham` messages, and subject-targeted Enron pools for
  Flights (150), Orders (150) and Invites (100), added after the first annotation
  pass found too few of them. These patterns overlap the keyword rules, so the
  enriched stratum favours the rules and is reported separately.

Claude Opus 5.5 agents labelled all 1,800 candidates against the rubric
(`corpus/labels-real-v1.jsonl`, reused unchanged by corpus v2; 21 excluded). The
labels are not human-verified.
GPT-6.1-Sol relabelled a random 150 (`corpus/labels-agreement-v1.jsonl`) as an
agreement check. Real-public scores therefore measure agreement with agent labels,
not verified accuracy. The implementation decision panel selected this annotation
approach over synthetic-only labels; its votes are recorded by the review handoff.

`synthetic.py` renders 48 English and 48 Czech templates, 24 times each with
deduplication (1,782 messages). Templates rather than messages are split: in each
template group the last template is test, the one before validation, and the
rest train, so test phrasing is never trained. Sender names, shops and airlines
come from disjoint per-split pools, so no synthetic sender address or shop/airline
domain appears in two splits. Personal addresses share the `mail.example` domain.
Overlap templates cover
Orders + Flights and Invites + Newsletters & Promotions. Hard cases cover automated
mail written to look personal, airfare marketing and personal mail that mentions
flights or orders.

Real messages are split by hashing connected groups into 60/20/20 buckets (1,171,
276 and 332 messages, because groups differ in size). Messages sharing a sender
address, a normalized body or a normalized thread subject within one source
(Enron or SpamAssassin, across its archives) always land in the same split. Time
is not separated, so v2 does not estimate later-time generalization.
`corpus/manifest-v2.json` records counts, source and label hashes, the test
ID/label hash and the full corpus hash.

## Methods

The input fields are sender, Reply-To,
whether mailing-list headers are present, recipient count, subject and a
200-character snippet of the body. The `body128`, `body256` and `body512`
variants append the rest of the body. DeBERTa truncates the whole input to the
named token budget, including special tokens. Its minimized variant uses 128
tokens. Rules and TF-IDF use the fields without token truncation; their `body`
variant reads the whole extracted body as an unbounded comparison baseline.

- **rules**: a Python port of the Swift prototype's `RuleBasedClassificationEngine`.
  It matches keywords in the minimized input, then the body, and assigns People
  only to body-checked direct correspondence without automated markers. With the
  minimized input only, the engine's `needsBody` result counts as Uncategorized.
- **tfidf**: word 1–2-gram and character 2–5-gram TF-IDF with one balanced
  logistic regression per category.
- **deberta**: one five-output multi-label head fine-tuned with binary
  cross-entropy for 4 epochs, batch 16, learning rate 5e-5 with 10% warmup and
  linear decay, weight decay 0.01, gradient clipping at 1.0, fp32 on MPS and
  an effective batch of 16 with a 2,048-padded-token micro-batch budget.
  Checkpoints are pinned:
  `microsoft/deberta-v3-xsmall` `4b419818`, `microsoft/deberta-v3-small`
  `a36c7390` and `microsoft/mdeberta-v3-base` `a0484667` (all MIT).

Learned methods train on train and calibrate one threshold per category on
validation, choosing the F1-maximizing value from 0.05 to 0.95 and preferring the
higher threshold on ties. The procedure was fixed before any test evaluation.
Decisions are independent per category. People is applied explicitly as a
fallback: it is assigned only when no purpose category passes its threshold.
A message with no category stays Uncategorized.
