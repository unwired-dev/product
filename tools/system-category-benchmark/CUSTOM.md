# Custom Category benchmark (spike #829)

Can DeBERTa assign user-created Custom Categories, judged only by a name and an
optional Category Description, to English and Czech mail on device? This spike
compares NLI-trained DeBERTa candidates with a description/keyword baseline on
categories no model was trained on. It is research for
[#827](https://github.com/unwired-dev/product/issues/827) and changes nothing in
the apps: no production assignments, no historical classification and no cloud
fallback. Delivery stays in #649 and #650.

It reuses the System Category slice (#828): corpus v2, its input preprocessing
and its measurement code in [run.py](run.py), which this spike does not change,
so the #828 results stay valid. Generated tables are in
[custom/tables.md](custom/tables.md).

## Findings

Test split: 838 messages (171 real-random and 161 real-enriched English, 170
English and 163 Czech System synthetic, 86 English and 87 Czech Custom synthetic),
52 Custom Categories. Macro-F1 is over the categories with test support; every
number comes from [custom/tables.md](custom/tables.md).

1. **NLI checkpoints used as they are do not assign Custom Categories usefully.**
   The best zero-shot run, the XSmall universal classifier with descriptions,
   reaches 0.31 macro-F1 overall and 0.13 on Czech. The XSmall trained only on
   SNLI and MultiNLI reaches 0.09. mDeBERTa reaches 0.14 with descriptions and 0.24
   with names only. The description/keyword baseline reaches 0.37.
2. **Adapting on System Category hypotheses alone is the largest gain.** One epoch
   on train-split System Category definitions, with no Custom Category meaning
   trained, lifts XSmall to 0.39 (95% interval 0.36–0.41). Its 38 unseen
   categories rise from 0.29 to 0.39 and Czech from 0.13 to 0.47. Adapted mDeBERTa
   reaches 0.35 overall and 0.48 on Czech.
3. **Neither candidate is reliably better than keywords overall, but both are
   more precise on real mail.** The keyword baseline's 0.37 (0.34–0.39) overlaps
   the adapted XSmall's interval. On real English mail the adapted XSmall scores
   0.23 (random) and 0.28 (enriched) against the baseline's 0.14 and 0.21. It
   makes 0.20 and 0.47 false assignments per message against 1.49 and 1.84,
   because keywords give nearly every message a category.
4. **Real-mail quality is low.** On the real-random slice the adapted XSmall gives
   a Custom Category to 30% of messages where the labels give one to 64%, with
   micro-F1 0.27. It misses private notes ("Family and friends"), energy trading,
   subscribed reading and regulation. It adds "Tech news", "Updates", "Webinars"
   and "Deals and coupons" to mail they do not describe. Most real categories have
   fewer than ten test positives, so per-category real results are anecdotes.
5. **Descriptions matter, and their wording does too.** With descriptions the
   adapted XSmall scores 0.39; with names only, 0.25. The ambiguous names reach
   0.73 because the description separates bank statements from press statements
   (F1 0.96) and book clubs from nightclubs (1.00). "Updates" still confuses
   project status with software updates (0.25). The raw three-way mDeBERTa does
   worse with descriptions (0.14) than without (0.24). Replacing each description
   with a paraphrase lowers the zero-shot XSmall from 0.31 to 0.26. A validation
   probe of two hypothesis wordings changed English macro-F1 by up to 0.08.
6. **A 256-token budget is enough.** The adapted XSmall scores 0.33 with
   Minimized Classification Input, 0.39 with a 256-token body and 0.38 with 512.
   The hypothesis takes 40 tokens on average (77 at most) of the budget. At 256
   tokens, 25% of pairs still reach the limit.
7. **Cost grows with every category, quality does not change.** Categories are
   scored independently, so macro-F1 stays at 0.39 for 5, 20 and 50 categories.
   False assignments per message grow from 0.08 to 0.25 to 0.64, and the share of
   messages with at least one wrong Custom Category from 7% to 20% to 39%. A
   cross-encoder runs once per message and category: at 50 categories the adapted
   XSmall managed about 1.1 messages per second and mDeBERTa 0.4 on this loaded
   Mac. These are throughput figures under shared load, not device latency.
8. **One threshold per language transfers to unseen categories with a small
   loss.** Tuned on half of the categories, it gives 0.36 and 0.33 on the other
   half, against 0.38 and 0.40 with all categories tuned.
9. **Czech is insufficient evidence.** All Czech is synthetic. The English-only
   adapted XSmall (0.47) matches multilingual mDeBERTa (0.48) on Czech, so the
   Czech slices measure template and shared-vocabulary overlap, not Czech
   understanding. The adapted XSmall assigns "School" to 93 Czech test messages.
10. **System Categories should keep their dedicated classifiers.** Through the
    same NLI pipeline, the adapted XSmall scores 0.83 and adapted mDeBERTa 0.84 on
    System Categories, against 0.87 and 0.92 for the #828 classifiers. On real
    random mail the gap is wider: 0.37 and 0.48 against 0.69 and 0.55. Custom
    Category scores never change the System decision or the People fallback.
11. **Per-sender Future Learning Signals help, but are noisy on real mail.**
    Replaying the real test stream with every error corrected, signals changed 133
    later decisions of the adapted XSmall; 55 of these changes were right.
    Micro-F1 still rose from 0.37 to 0.43, because a corrected false negative adds
    a true positive. Templated synthetic mail rises from 0.50 to 0.90 because
    senders repeat one template. Another 427 earlier assignments that a later
    signal contradicted stayed as assigned.

## Frozen candidate bundle

[custom/bundle-v1.json](custom/bundle-v1.json) freezes one candidate per model
family for each category mode, for the device slices #830 and #831. Weights are
not committed. They are reproducible with the commands below, and the bundle
records each weight file's SHA-256.

| Mode   | Candidate                                                     | Why                                                                                                             |
| ------ | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Custom | Adapted XSmall universal classifier, 256 tokens, descriptions | Best overall and on real mail; 71M parameters. Thresholds 0.71 (English) and 0.85 (Czech).                      |
| Custom | Adapted multilingual mDeBERTa, 256 tokens, descriptions       | The only vocabulary built for Czech; best on Czech System synthetic. 279M parameters. Thresholds 0.92 and 0.98. |
| System | #828 XSmall, 256-token body                                   | The smallest System candidate from #828, unchanged.                                                             |
| System | #828 mDeBERTa, 512-token body                                 | The strongest System candidate from #828, unchanged.                                                            |

Rejected: the zero-shot checkpoints without adaptation, the SNLI/MultiNLI-only
XSmall, names without descriptions, and 512-token Custom inputs (no gain for
twice the cost). The keyword baseline is kept as the bar.

[custom/golden-v1.json](custom/golden-v1.json) holds reference outputs on 12
synthetic test messages (three per language and synthetic stratum). For the
Custom candidates it covers six categories, including the ambiguous "Statements".
It records each message, hypothesis, input token IDs, entailment probability and
membership decision. For the System candidates it records token IDs, the five
probabilities and the categories after the People fallback. Every Custom pair was
checked against the tokenizer's own pair encoding. References were computed in
fp32 (Custom on MPS, System on CPU). A port should reproduce the token IDs
exactly, probabilities within about 1e-3, and decisions except within that
distance of a threshold.

Adaptation cost on this Mac: 19 minutes and 4,352 MiB peak MPS memory for XSmall,
65 minutes and 11,573 MiB for mDeBERTa, both under shared load.

## Run it

Set up the tool as in the [README](README.md#run-it), including `corpus.py fetch`
and `corpus.py build` (or a `work/corpus.jsonl` that passes the manifest check).
Everything downloaded or trained goes to the ignored `work/` directory.

```sh
cd tools/system-category-benchmark

# Labels (already committed; rerunning needs the annotation agents again)
mise exec -- uv run python custom.py annotate   # work/custom-annotate/batch-NN.txt
mise exec -- uv run python custom.py labels     # merge work/custom-annotations/ into custom/labels-v1.jsonl
mise exec -- uv run python custom.py agreement  # compare with custom/labels-agreement-v1.jsonl

# Baseline, probes and candidates
mise exec -- uv run python custom.py keywords
mise exec -- uv run python custom.py templates xsmall-zs 300
mise exec -- uv run python custom.py templates mdeberta-nli 150
mise exec -- uv run python custom.py adapt xsmall-zs
mise exec -- uv run python custom.py adapt mdeberta-nli
for run in "xsmall-zs body256 description" "xsmall-zs body256 name" \
    "xsmall-zs body256 paraphrase" "xsmall-nli body256 description" \
    "mdeberta-nli body256 description" "mdeberta-nli body256 name" \
    "xsmall-zs-adapted body256 description" "xsmall-zs-adapted body256 name" \
    "xsmall-zs-adapted minimized description" "xsmall-zs-adapted body512 description" \
    "mdeberta-nli-adapted body256 description"; do
  mise exec -- uv run python custom.py score ${=run}        # work/custom-scores/<run>.npz
  mise exec -- uv run python custom.py evaluate ${run// /-}  # custom/results/<run>.json
done
for run in xsmall-zs-adapted-body256-description mdeberta-nli-adapted-body256-description; do
  mise exec -- uv run python custom.py overrides $run
done
mise exec -- uv run python custom.py golden xsmall-zs-adapted-body256-description \
    mdeberta-nli-adapted-body256-description
mise exec -- uv run python custom.py tables     # custom/tables.md

mise exec -- uv run pytest
```

`score` computes the entailment probability of every validation and test message
against all 52 Custom Category hypotheses and the five System Category
hypotheses; `evaluate` calibrates and scores it, so a new labeling or threshold
rule never needs a model run. `tables` refuses results evaluated on other labels.
`golden` needs the #828 System candidate artifacts in `work/runs/` (from
`run.py deberta xsmall body256` and `run.py deberta mdeberta body512`).

## Data

### Custom Categories

[custom/categories-v1.json](custom/categories-v1.json) defines 52 Custom
Categories, each with an English and a Czech name (1–40 characters), a
description and a paraphrase of that description (at most 500 characters), as a
user could write them in Settings. They cover what the corpus holds and what
people organize mail by:

- shopping, money and travel, including 14 that overlap a System Category's
  meaning (for example "Online purchases" and Orders);
- personal life: family, school, health, home, utilities, insurance, taxes, car,
  clubs, sports and charity;
- work: energy trading, contracts, regulation, HR, meetings, reports and budgets;
- technical mailing lists: Linux, spam filters, coding and list administration.

Three names are deliberately ambiguous and rely on the description: "Statements"
(bank statements, not press statements), "Club" (not nightclubs) and "Updates"
(colleagues' project status, not software updates). Overlapping definitions are
recorded per category (`overlaps`), for example "My flights" and "Trip plans".

### Messages

The validation (616) and test (665) messages of corpus v2 (English real-random,
English real-enriched, English and Czech synthetic), plus a new Custom synthetic
stratum ([custom_synthetic.py](custom_synthetic.py)) of 356 English and Czech
messages for the personal themes corpus v2 lacks (school, health, bank, home,
utilities, insurance, taxes, car, job search, clubs, sports, charity, statements,
project updates). The Custom synthetic stratum has validation and test templates
only, never training ones, and no sender domain spans both. Each ambiguous-name
theme pairs a positive with a hard negative (a press statement, a nightclub
promotion, a software update notice) in both splits. Czech remains synthetic: no
real Czech mail is used.

### Labels

Claude Opus 5.5 agents labeled all 1,637 messages against all 52 categories with
[custom/rubric.md](custom/rubric.md); the labels are in
[custom/labels-v1.jsonl](custom/labels-v1.jsonl) as message IDs and category IDs
only, without message text. Renderings of one synthetic template were reconciled
to one label set (48 labels changed), keeping slot-dependent differences such as
a lunch invitation to an office room being "Office social". GPT-6.1-Sol relabeled
150 messages (100 real) independently
([custom/labels-agreement-v1.jsonl](custom/labels-agreement-v1.jsonl)): exact label-set agreement 0.61 (0.57 on real mail),
micro-F1 0.83 (0.78 on real mail). Agreement was weakest on "Updates", "Reviews"
and "Bills to pay" (kappa 0.39–0.49), and the relabel alone used "Loyalty
rewards" (5 messages).
**Scores measure agreement with agent labels, not verified accuracy.**

## Methods

**Candidates.** Microsoft's base checkpoints are not zero-shot classifiers, so the
candidates are published NLI fine-tunes, each scored as its own adaptation:

| Key            | Checkpoint (revision)                                                    | Licence    | NLI training (from the model card)                                                                             |
| -------------- | ------------------------------------------------------------------------ | ---------- | -------------------------------------------------------------------------------------------------------------- |
| `xsmall-zs`    | `MoritzLaurer/deberta-v3-xsmall-zeroshot-v1.1-all-33` (`262ae02f`)       | MIT        | DeBERTa v3 XSmall trained on 33 English classification and NLI datasets cast as binary entailment.             |
| `xsmall-nli`   | `cross-encoder/nli-deberta-v3-xsmall` (`a1508764`)                       | Apache-2.0 | DeBERTa v3 XSmall trained on SNLI and MultiNLI (three-way).                                                    |
| `mdeberta-nli` | `MoritzLaurer/mDeBERTa-v3-base-xnli-multilingual-nli-2mil7` (`b5113eb3`) | MIT        | mDeBERTa v3 base trained on 2.7 million NLI pairs in 27 languages; Czech is not among them, only pre-training. |

**Task adaptation (`-adapted`).** One more epoch on train-split pairs of a message
and each **System Category** definition as the hypothesis (11,400 pairs,
entailment versus not, learning rate 2e-5, batch 16, 10% warmup, seed 829,
256-token input). No Custom Category meaning, description or label is trained, so
every Custom Category stays unseen; the 14 categories whose meaning overlaps a
System Category are reported separately from the 38 unseen ones.

**Hypotheses.** `This email belongs to the category "<name>".` (Czech:
`Tento e-mail patří do kategorie „<name>“.`), followed by the description, its
paraphrase, or nothing (`name` mode, a category without a description). The
message is the premise: the Minimized Classification Input of #828 (sender,
Reply-To, list headers, recipient count, subject, 200-character snippet), plus
the rest of the body in the `body256` and `body512` budgets. The budget counts the
message, the hypothesis and the special tokens; only the message is truncated.
The candidates' own tokenizers were checked to produce identical IDs.

**Scoring and abstention.** Each category is scored independently as the
probability of entailment against contradiction (or not-entailment). One threshold
per message language is chosen on validation to maximize micro-F1, preferring the
higher threshold on ties: a new Custom Category has no labels to tune its own
threshold on. Calibration per language lets the English-only checkpoints be read
as English candidates. A second check tunes the threshold on half of the categories
and applies it to the other half. Custom Category scores never change the System
Category decision: People remains the System fallback, and Custom Categories are
assigned alongside System Categories. A message with no Custom Category above the
threshold keeps no Custom Category.

**Baseline.** The share of a category's name and description word stems
(ASCII-folded five-character prefixes without stop words) found in the message,
with the same calibrated threshold.

**Category count.** For 5, 20 and 50 categories, five random nested subsets of the
52; messages per second divide the measured pair throughput by the count, since a
cross-encoder runs once per message and category.

**Future Learning Signals.** The test messages are replayed in arrival order.
Every wrong decision is corrected by a simulated User Override on that message,
which records a positive or negative signal for the sender address and category;
later messages from that sender use the signal instead of the model for that
category. Signals are local correction state: no model weights change, and an
assignment made before a signal is never revisited.

**System Categories through NLI.** The same pipeline scores the five System
Category definitions with per-category thresholds and People as the fallback, to
measure what replacing #828's dedicated classifiers with one NLI model would cost.

## Limitations

- Labels come from LLM agents and were not verified by people; the two annotators
  agree on only 61% of complete label sets.
- The 52 categories and their descriptions were written for this spike, not by
  users. Real descriptions will be shorter, vaguer or longer, and the results are
  sensitive to wording.
- Real mail is English from 1998–2002 and mostly work mail; Czech and all personal
  themes are synthetic, with one template per theme and split, so per-theme
  results describe a template, not a kind of mail.
- Most categories have fewer than ten test positives in any slice.
- Two hypothesis wordings were probed on a validation sample only; adaptation used
  one seed and untuned settings. PyTorch MPS is not bitwise deterministic.
- Throughput and adaptation times come from a Mac mini shared with other agent
  sessions (load averages from 4 to over 700 are recorded per run); they are not
  device or export measurements.
- Thresholds are chosen per message language, which assumes the language is
  known before classification.
- The override replay corrects every error immediately and learns only per sender
  and category; real users correct some errors, later.
- Bootstrap intervals resample messages, not templates, senders or categories.
- Runs not made because of host load: mDeBERTa with a 512-token body, minimized
  input or a paraphrase, and the adapted models without descriptions beyond
  XSmall.

## What would change the decision

Human-verified labels on modern English and real Czech mail against categories
and descriptions written by real users, with at least about 50 test positives per
category group and language. With that corpus, rerun these commands unchanged:

- if an adapted candidate beats the keyword baseline on real mail by more than its
  interval while keeping false assignments below about 0.2 per message at 20
  categories, the English Custom decision becomes adopt for device qualification;
- if adapted mDeBERTa beats the English-only XSmall on real Czech mail, Czech gets
  its own candidate;
- if descriptions written by users lose the gain measured here, the candidates
  need a different hypothesis design before any delivery work.

## Proposed follow-up for #649 and #650

Not implemented here, and those issues are unchanged:

- Keep Custom Category assignment separate from the System Category classifier;
  one shared NLI model would regress System Categories on real mail.
- Encourage a Category Description when a user creates a Custom Category, and
  show what it changed: names alone score much lower.
- Budget for per-category cost. A cross-encoder runs once per enabled Custom
  Category, so either cap automatically evaluated Custom Categories or evaluate a
  bi-encoder that encodes each message once, before #650 commits to one.
- Treat per-sender Future Learning Signals as a narrow tool: on varied real
  senders most of the changes they caused were wrong.
