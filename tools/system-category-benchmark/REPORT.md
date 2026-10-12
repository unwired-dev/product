# System Category benchmark: results (spike #828)

Corpus v2, 3,561 messages (2,280 train, 616 validation, 665 frozen test). Method,
data provenance and commands are in the [README](README.md); every number below
comes from [results/tables.md](results/tables.md), generated from `results/*.json`.

Corpus v1 was withdrawn after review found an identical newsletter body, one
SpamAssassin Thread and 107 synthetic sender addresses crossing splits. Corpus v2
keeps every sender address, normalized body and real Thread inside one split, and
`corpus.py build` refuses a corpus that breaks this. All results were rerun on v2.

**Read the real-public numbers as agreement with agent labels, not verified
accuracy.** Claude Opus 5.5 agents labelled the real messages against the
[rubric](corpus/rubric.md); a GPT-6.1-Sol relabel of 150 of them agreed exactly
on 90% of label sets (Cohen's kappa: Newsletters & Promotions 0.98, Invites 0.87,
People 0.83, Orders 0.33 on 1 versus 5 positives, Flights no positives).

## Findings

1. **The existing keyword rules are not a usable quality reference.** Macro-F1 is
   0.35 on Minimized Classification Input and 0.42 with the body. They score
   0.00–0.02 on Czech because every keyword is English, and with the body they
   assign People to 72 of the 86 Uncategorized real-random test messages.
2. **A cheap text-feature model is as good overall as fine-tuned DeBERTa.** Word
   and character TF-IDF with logistic regression reaches 0.87 macro-F1 with
   minimized input and trains in about a second. Across three training seeds,
   the DeBERTa configurations average 0.82–0.88, so none is reliably better
   overall. Seeds alone move a single DeBERTa configuration by up to 0.12.
3. **DeBERTa is consistently better at the People and Uncategorized boundary on
   real mail.** In all 18 seeded DeBERTa runs, People F1 on enriched real mail is
   0.82–0.90 against TF-IDF's 0.75–0.76. On the real-random slice, DeBERTa
   recovers 62–90% of Uncategorized messages against TF-IDF's 51–56%, with 9–33
   People false positives against TF-IDF's 33–39.
4. **mDeBERTa with a 512-token body is the only configuration that beats TF-IDF on
   enriched real mail in every seed.** It scores 0.84–0.89 macro-F1 there (mean
   0.87) against TF-IDF's 0.76–0.78, driven by Orders (F1 0.78–0.87 against
   0.64–0.67, 13 messages) and Flights (0.80–1.00, 6 messages). Its overall mean is
   0.88 (0.87–0.92), within noise of TF-IDF.
5. **Body text helps the larger model and destabilizes the smallest.** For
   mDeBERTa the 512-token body raises the enriched real-mail mean from 0.75 to
   0.87. XSmall gains on enriched mail with a 256-token body (0.70 to 0.79) but is
   unstable at 512 tokens (overall 0.76–0.88). Without a body, every model's real
   Flights F1 swings between 0.00 and 0.67 across seeds. A 512-token body costs
   2.4× to 2.9× the training time of minimized input.
6. **Real-world quality per category is insufficient evidence.** The real test
   slices hold 1 Orders and 0 Flights messages in the random sample and 13 and 6
   in the enriched one; one Orders message moves real-random macro-F1 by 0.25.
   Use the support-filtered table for real-random comparisons.
7. **Czech is insufficient evidence.** All Czech messages are synthetic. TF-IDF
   (0.88) and the English-only XSmall (0.86–0.88 across seeds) score about as
   well on held-out Czech templates as multilingual mDeBERTa (0.86–0.94), which
   shows the synthetic set measures template generalization, not Czech language
   understanding. English checkpoint quality must not be assumed to transfer to
   real Czech mail.

## Candidates

| Candidate                                    | Decision                        | Why                                                                                                                                                                                                                                                            |
| -------------------------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| mDeBERTa v3 base, 512-token body             | Keep: strongest candidate       | The only configuration better than TF-IDF on enriched real mail in every seed; best Orders and Flights; the only vocabulary built for Czech. Largest: 279M parameters, 1,064 MiB fp32 weights, 10,549–11,490 MiB peak training memory, 31 minutes of training. |
| DeBERTa v3 XSmall, 256-token body            | Keep: smallest promising        | Matches TF-IDF on enriched real mail (0.77–0.80) with the consistent People and Uncategorized gain and stable real Flights (0.75–0.80); 71M parameters, 271 MiB weights, 4,396 MiB peak training memory, 7 minutes.                                            |
| XSmall or mDeBERTa with minimized input only | Keep only as a comparison point | As good overall as TF-IDF, but real Flights falls to 0.00 in some seeds.                                                                                                                                                                                       |
| DeBERTa v3 Small                             | Reject                          | No advantage over XSmall beyond noise (overall 0.84, enriched real mail 0.68 mean with minimized input) at twice the size.                                                                                                                                     |
| XSmall with a 512-token body                 | Reject                          | Unstable across seeds (overall 0.76–0.88) at 2.9× the training time of minimized input.                                                                                                                                                                        |
| Keyword rules                                | Reject as the comparison target | Far below every learned method and unusable for Czech.                                                                                                                                                                                                         |
| TF-IDF logistic regression                   | Keep as the baseline            | As good overall as every DeBERTa candidate and nearly free to train; the bar for any model.                                                                                                                                                                    |

These candidates feed the Custom Category slice (#829) and the device slices
(#830, #831). Single configurations vary by up to 0.12 macro-F1 across seeds, so
later slices should compare several seeds or select a checkpoint on validation
rather than trust one run. This spike measured no on-device size, memory or
latency budget.

## Detail

### Selected macro-F1 (seed 828, 95% bootstrap interval)

| Run                        | All              | Real random      | Real enriched    | English synthetic | Czech synthetic  |
| -------------------------- | ---------------- | ---------------- | ---------------- | ----------------- | ---------------- |
| rules-body                 | 0.42 (0.37–0.46) | 0.16 (0.12–0.21) | 0.41 (0.32–0.48) | 0.66 (0.59–0.73)  | 0.02 (0.01–0.04) |
| tfidf-minimized            | 0.87 (0.84–0.89) | 0.69 (0.30–0.78) | 0.76 (0.66–0.84) | 0.88 (0.81–0.93)  | 0.88 (0.79–0.93) |
| deberta-xsmall-minimized   | 0.86 (0.84–0.88) | 0.66 (0.34–0.82) | 0.76 (0.66–0.84) | 0.95 (0.93–0.97)  | 0.86 (0.82–0.90) |
| deberta-xsmall-body256     | 0.87 (0.85–0.90) | 0.69 (0.32–0.79) | 0.79 (0.71–0.85) | 0.99 (0.97–1.00)  | 0.85 (0.78–0.90) |
| deberta-mdeberta-minimized | 0.88 (0.86–0.90) | 0.61 (0.39–0.77) | 0.82 (0.71–0.89) | 0.92 (0.89–0.95)  | 0.91 (0.87–0.94) |
| deberta-mdeberta-body512   | 0.92 (0.90–0.94) | 0.55 (0.35–0.65) | 0.89 (0.83–0.93) | 1.00 (0.99–1.00)  | 0.94 (0.91–0.96) |

Seed 828 is the best of three seeds for mDeBERTa with a 512-token body; its
three-seed mean is 0.88 overall and 0.87 on enriched real mail. All sixteen
primary runs, twelve additional seed runs, per-category precision and recall,
coverage, overlap errors and People false positives per slice are in
[results/tables.md](results/tables.md).

### Coverage and abstention

Half of the real-random test messages are Uncategorized under the rubric. With
seed 828, XSmall with minimized input assigns a category to 58% of the slice and
recovers 80% of Uncategorized messages; mDeBERTa with a 512-token body assigns 63%
and recovers 69%. TF-IDF assigns 74% (recall 0.51) and the body rules 95% (recall
0.06): the rules abstain almost never because their People fallback accepts any
body-checked mail without automated markers. The synthetic test slices hold only
6 Uncategorized messages each, so they say little about abstention.

### Overlaps and failure patterns

The most frequent errors per minimized-input run are in
[results/tables.md](results/tables.md).

- **Real Uncategorized mail becomes People.** Automated approvals, forwards and
  system notifications written in plain prose are the largest real-random error
  for TF-IDF and every DeBERTa model (11–32 messages).
- **A seat-upgrade notice gains Orders.** XSmall labels all 48 English and Czech
  renderings of the held-out "seat upgrade confirmed" Flights template as
  Orders + Flights; Small does so for all 24 Czech renderings.
- **Airfare marketing becomes Flights.** The rubric files airfare sales under
  Newsletters & Promotions only; TF-IDF and mDeBERTa substitute Flights, and
  XSmall and Small substitute Orders + Flights or Orders, on the held-out Czech
  airfare template.
- **Overlap templates lose one label.** On Czech, Small drops Invites from a
  promotional summit invitation (20 messages) and Flights from a change-fee
  receipt (16).
- **Internal newsletters become Uncategorized, and an all-staff notice becomes
  Invites.** Enron internal newsletters are among the main enriched real-mail
  misses for XSmall and mDeBERTa; mDeBERTa labels the held-out "office closed" notice
  Invites.

### People fallback

People is one of the model's five outputs but is assigned only when no purpose
category passes its threshold, so it never co-occurs with Orders, Newsletters &
Promotions, Invites or Flights. The rules apply the prototype's own fallback. No
learned model assigned People to a synthetic automated message written to look
personal; the remaining People false positives are on real mail.

### Training cost

Apple M4 Mac mini, 16 GB, macOS 27, PyTorch 2.14.1 MPS, fp32, 4 epochs over
2,280 messages. The twelve primary DeBERTa runs took 2.4 hours of training.

| Model         | Parameters | Checkpoint download | Fine-tuned fp32 weights | Train time, minimized / 256 / 512 body | Peak training memory |
| ------------- | ---------: | ------------------: | ----------------------: | -------------------------------------- | -------------------: |
| XSmall        |      70.8M |             232 MiB |                 271 MiB | 4.3 / 7.0 / 12.3 min                   |      4,281–5,332 MiB |
| Small         |     141.9M |             275 MiB |                 542 MiB | 6.5 / 9.8 / 15.4 min                   |      6,190–6,379 MiB |
| mDeBERTa base |     278.8M |           1,275 MiB |               1,064 MiB | 12.6 / 21.0 / 30.9 min                 |    10,549–11,490 MiB |

Download sizes are the pinned `pytorch_model.bin` plus `spm.model`. Peak memory
is the largest MPS driver allocation sampled after optimizer steps during training,
not a process-RSS measurement or a continuous peak. All size and memory values
in this report use MiB (1 MiB = 1,048,576 bytes). These are training costs on a Mac;
exported, quantized and on-device sizes, memory and latency belong to #830 and
#831.

### Preprocessing and omitted content

Minimized input keeps the sender, Reply-To, whether mailing-list headers exist,
the recipient count, the subject and a 200-character snippet of the whitespace-
normalized body. It omits all other headers, attachments and HTML markup. HTML
bodies are reduced to text by removing tags, scripts and styles; quoted replies
and signatures are kept. Body variants append the rest of the normalized body
and truncate the whole input at the token budget: 5% of training inputs reach the
128-token limit with minimized input, 43% with a 128-token body and 19% with a
512-token body. The body variants are separate full-corpus comparisons, not an
implemented conditional fallback policy. Rules and TF-IDF are unbounded
baselines; only DeBERTa applies the named tokenizer budgets.

## Limitations

- Real-public labels come from LLM agents and were not verified by people;
  Orders agreement between the two annotators was poor (kappa 0.33), mostly on
  corporate asset sales and change orders discussed between colleagues.
- The real sources are English mail from 1998–2002: no modern HTML commercial
  mail, delivery notifications or airline apps, and Enron has no mailing-list
  headers.
- Rare real categories have single-digit test support; per-category real
  results are anecdotes.
- Czech is synthetic and template-based; templates and senders are held out per
  split, but the remaining slot vocabulary is shared.
- Hyperparameters were not tuned; thresholds were calibrated on pooled
  validation across languages and strata; six configurations have three seeds
  and the rest one.
- Bootstrap intervals resample individual messages, not independent sender,
  Thread or template groups; related renderings can make them too narrow.
- Time is not separated, so the results do not estimate later-time
  generalization.

## What would change the decision

Human-verified labels on modern English and real Czech mail, either public or
authorized private mail kept on device, with at least about 50 test positives per
category and language. With that corpus, rerun these commands unchanged: if a
DeBERTa candidate then beats TF-IDF by more than the seed spread on real mail,
the English decision becomes adopt for further device qualification; if
mDeBERTa beats the English checkpoints on real Czech mail, Czech gets its own
candidate.

## Proposed follow-up for #649 and #650

Not implemented here, and those issues are unchanged:

- Measure the existing rules against a labelled sample before relying on them;
  their People fallback mislabels most automated real mail.
- Treat a TF-IDF-sized model as the baseline a DeBERTa candidate must beat.
- Prefer Minimized Classification Input first and a bounded body fallback only
  where it adds evidence, such as Orders and Flights, matching the existing
  privacy order.
- Settle the rubric gaps recorded in [corpus/rubric.md](corpus/rubric.md)
  (discussion lists, trading confirmations, corporate transactions, airfare
  marketing) before collecting human labels.
