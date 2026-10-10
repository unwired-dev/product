# DeBERTa v3 for private email categorization

Research date: 2026-10-10. This is a candidate assessment, not an implementation,
benchmark result, or change to replacement-release scope.

## Recommendation

Evaluate **DeBERTa v3 xsmall first, with small as a challenger**, for an on-device
classifier trained on our System Categories. It is a plausible fit for semantic
email categorization, but a poor justification for replacing deterministic mail
signals before measuring an improvement. Keep base as an offline quality
reference and large as a possible training-time teacher; neither should be the
default mobile download without evidence that the extra cost is worthwhile.

The important sizing correction: **xsmall is about 71 million parameters in a
classifier, not 22 million; small is about 142 million, not 44 million**. Microsoft's
headline numbers exclude the vocabulary embedding matrix. There is no `tiny`
entry in Microsoft's official v3 model list; the smallest is `xsmall`.
[Official model list](https://github.com/microsoft/DeBERTa#pre-trained-models),
[xsmall card](https://huggingface.co/microsoft/deberta-v3-xsmall),
[small card](https://huggingface.co/microsoft/deberta-v3-small).

## What it does

DeBERTa v3 is a text encoder, suitable for attaching a classification head. Its
pretraining uses replaced-token detection and gradient-disentangled embedding
sharing. It is not a generative assistant for writing replies or summaries.
Microsoft's published NLU results support testing it as a language-understanding
candidate; they do **not** establish email classification accuracy.
[Paper](https://arxiv.org/abs/2111.09543),
[model implementation](https://github.com/huggingface/transformers/blob/v4.57.1/src/transformers/models/deberta_v2/modeling_deberta_v2.py).

The raw Microsoft checkpoints are pretrained models, not classifiers already
trained on Orders, Flights, or our other categories. Supervised fine-tuning needs
representative labeled mail. An NLI-trained variant can instead score category
descriptions at runtime, but NLI training is an additional step; simply giving
the raw checkpoint label names does not create a zero-shot classifier.
[Microsoft fine-tuning example](https://huggingface.co/microsoft/deberta-v3-base#fine-tuning-with-hf-transformers),
[Hugging Face zero-shot pipeline](https://huggingface.co/docs/transformers/main/en/main_classes/pipelines#transformers.ZeroShotClassificationPipeline).

## Size: parameters, deployable weights, and downloads

All storage numbers below use **decimal MB** (1 MB = 1,000,000 bytes). These are
weight-only calculations for a conventional five-output sequence classifier,
including its pooler. They are not measured Core ML/ONNX exports or working RAM.
The output count illustrates size; People still requires the product's fallback
rule, described below.

| Variant           | Layers / hidden width | Advertised backbone | Word embeddings | Classifier total, approximately | FP32 weights | FP16 weights | Ideal INT8 weights |
| ----------------- | --------------------- | ------------------- | --------------- | ------------------------------- | ------------ | ------------ | ------------------ |
| xsmall            | 12 / 384              | 22M                 | 49.2M           | 71M                             | 283 MB       | 142 MB       | 71 MB              |
| small             | 6 / 768               | 44M                 | 98.4M           | 142M                            | 568 MB       | 284 MB       | 142 MB             |
| base              | 12 / 768              | 86M                 | 98.4M           | 184M                            | 738 MB       | 369 MB       | 184 MB             |
| large             | 24 / 1024             | 304M                | 131.2M          | 435M                            | 1,740 MB     | 870 MB       | 435 MB             |
| multilingual base | 12 / 768              | 86M                 | 192.8M          | 279M                            | 1,115 MB     | 558 MB       | 279 MB             |

Model-card backbone counts are approximate and not identical to a bare encoder
minus its word matrix. Dimensions come from Microsoft's
[xsmall](https://huggingface.co/microsoft/deberta-v3-xsmall/blob/main/config.json),
[small](https://huggingface.co/microsoft/deberta-v3-small/blob/main/config.json),
[base](https://huggingface.co/microsoft/deberta-v3-base/blob/main/config.json),
[large](https://huggingface.co/microsoft/deberta-v3-large/blob/main/config.json), and
[multilingual](https://huggingface.co/microsoft/mdeberta-v3-base/blob/main/config.json)
configs. The multilingual card rounds its vocabulary and embeddings more coarsely;
the config's actual vocabulary is 251,000.

Reproducible arithmetic from those configs and the
[pinned HF implementation](https://github.com/huggingface/transformers/blob/v4.57.1/src/transformers/models/deberta_v2/modeling_deberta_v2.py):
for hidden width `h`, layer count `L`, vocabulary `V`, and output count `K`,
the bare encoder has `V*h + 512*h + 4*h + L*(12*h*h + 13*h)` parameters.
The pooler and classifier add `h*h + h + K*(h+1)`. With `K=5`, totals are
70,831,877; 141,898,757; 184,425,989; 435,066,885; and 278,813,189 respectively.
Multiply by four, two, or one byte for the table. This calculation excludes
unused pretraining tensors and includes embeddings.

**INT8 is an ideal all-weight estimate.** Quantizing only dense layers while
leaving embeddings in floating point will miss much of the possible saving.
Actual exports also contain scales, metadata, and possibly unquantized operators.
Runtime RAM additionally includes activations, temporary buffers, compiled models,
and the tokenizer. Quantization accuracy and execution-provider support must be
tested; a smaller file is not proof of faster execution.
[ONNX quantization guide](https://onnxruntime.ai/docs/performance/model-optimizations/quantization.html),
[Apple compression conversion](https://apple.github.io/coremltools/docs-guides/source/opt-conversion.html).

The **published `pytorch_model.bin` downloads are different**:

| Variant           | Official checkpoint bytes | Rounded download |
| ----------------- | ------------------------- | ---------------- |
| xsmall            | 241,453,931               | 241 MB           |
| small             | 286,059,269               | 286 MB           |
| base              | 371,146,213               | 371 MB           |
| large             | 873,673,253               | 874 MB           |
| multilingual base | 1,332,809,049             | 1,333 MB         |

These are observed file sizes from the official Hub API with `blobs=true`:
[xsmall](https://huggingface.co/api/models/microsoft/deberta-v3-xsmall?blobs=true),
[small](https://huggingface.co/api/models/microsoft/deberta-v3-small?blobs=true),
[base](https://huggingface.co/api/models/microsoft/deberta-v3-base?blobs=true),
[large](https://huggingface.co/api/models/microsoft/deberta-v3-large?blobs=true),
[multilingual](https://huggingface.co/api/models/microsoft/mdeberta-v3-base?blobs=true).
English tokenizers add 2,464,616 bytes; the multilingual tokenizer adds 4,305,025.

Do not label these downloads FP32. Inspection of each checkpoint's initial ZIP
pickle metadata by HTTP range request found `HalfStorage` in the English files;
the multilingual file contains both `HalfStorage` and `FloatStorage`. Xsmall also
contains additional embedding `_weight` entries. Published pretraining archives
therefore cannot be used as direct parameter-count or final-app-size measurements.
No full model download or execution was needed for this inspection.

Observed repository revisions, in table order:
`4b419818330868dff6a60ad3e6b1c730f8b8c0c6`,
`a36c739020e01763fe789b4b85e2df55d6180012`,
`8ccc9b6f36199bec6961081d44eb72fb3f7353f3`,
`64a8c8eab3e352a784c658aef62be1662607476f`,
`a0484667b22365f84929a935b5e50a51f71f159d`.

## Fit to our product

The product forbids sending message content to a server for AI processing.
Its categories can overlap: Orders, Newsletters & Promotions, Invites, Flights,
and user-defined Custom Categories are independently applicable. People is a
fallback for direct correspondence when no purpose-specific System Category
matches. Messages can remain uncategorized. Classification starts with metadata,
subject, snippet, and headers before considering already-local body text;
categorization never fetches a missing body from a provider.
[Product privacy premise](../../GLOSSARY.md),
[organization vocabulary](../domain/organization.md),
[organization behavior](../product/organization.md#categorization-and-conflicts),
[classification boundary](../adr/0007-classification-engine-interface.md).

My proposed evaluation design follows from those requirements:

- **System Categories:** fine-tune a multi-label classifier with independent
  thresholds. Avoid a single softmax that forces every message into exactly one
  category. Apply People eligibility and fallback separately from category scores.
- **Custom Categories:** a fixed output head cannot acquire a new semantic class
  merely because a user names it. Evaluate an NLI-trained model using category
  names and descriptions, or a separate lightweight local adaptation method.
  An optional description helps distinguish ambiguous names.
- **Corrections:** a user's positive or negative category change should update
  future local decisions without changing previous assignments. This product
  behavior is not automatically provided by DeBERTa; it needs explicit local
  learning or rule state. Do not assume full on-device model retraining.
- **Scope:** categorize new mail by default; historical work requires the existing
  explicit, bounded opt-in. A faster model does not change that rule.

For NLI, each message/category pair becomes an inference input. Work therefore
grows roughly with category count, even if pairs are batched. Use independent
label scoring (`multi_label=True` in the HF reference pipeline), then calibrate
our own thresholds. Scores are not established email-domain confidence values.
[Pipeline semantics](https://huggingface.co/docs/transformers/main/en/main_classes/pipelines#transformers.ZeroShotClassificationPipeline).

All five official configs specify `max_position_embeddings: 512`. Treat **512
tokens, including special tokens and any category hypothesis**, as the supported
baseline budget. This is not 512 words. Relative-position mechanics do not
establish reliable arbitrary-length email behavior. Start with minimized input;
if needed, extract bounded relevant body text after removing quoted history and
boilerplate. Compare chunking only if truncation creates demonstrated errors;
it increases inference work. Sources: the five configs above and
[tokenizer documentation](https://huggingface.co/docs/transformers/main/en/model_doc/deberta-v2#transformers.DebertaV2Tokenizer).

English v3 checkpoints should not be assumed to classify Czech or other languages
well. Microsoft's multilingual v3 base was trained on CC100; the official model
list describes 102 languages. Its XNLI results demonstrate cross-lingual transfer,
not language-by-language email quality. A multilingual inbox needs per-language
evaluation and a larger model budget, or a different multilingual candidate.
[Multilingual model card](https://huggingface.co/microsoft/mdeberta-v3-base),
[official model list](https://github.com/microsoft/DeBERTa#pre-trained-models).

## Running on iPhone, iPad, and Mac

Two plausible native deployment paths are PyTorch → Core ML, or PyTorch → ONNX →
ONNX Runtime. Core ML Tools supports PyTorch conversion and FP16 ML programs.
ONNX Runtime has a React Native package for Android/iOS and a Core ML execution
provider for iOS/macOS. This establishes available building blocks, **not verified
DeBERTa v3 compatibility or Neural Engine execution**.
[Apple conversion](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html),
[ONNX React Native source](https://github.com/microsoft/onnxruntime/blob/main/js/react_native/README.md),
[Core ML execution provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html).

For our Expo host, native inference requires a development/native build; Expo Go
cannot add arbitrary native libraries. For the AppKit React Native Mac host,
the iOS React Native package alone is insufficient evidence: validate a macOS
native bridge and runtime independently. Export parity, the SentencePiece
tokenizer, operator support, provider partitioning/fallback, and cancellation are
part of the deployment experiment.
[Expo native-code guide](https://docs.expo.dev/workflow/customizing/),
[ONNX provider allocation](https://onnxruntime.ai/docs/execution-providers/),
[our native Mac setup](../macos-client.md).

Xsmall has fewer weights and a narrower hidden state; small has fewer sequential
layers but twice the width. Neither parameter count nor layer count alone proves
which has lower device latency. Measure both. The project targets iOS, iPadOS,
and macOS 27; this research did not run builds or benchmarks on those hosts.
[Native validation policy](../agents/native-validation.md).

The Microsoft model cards identify the weights as MIT licensed, and the official
repository provides the MIT license. Retain required notices. A separately
downloaded NLI fine-tune or training dataset requires its own provenance and
license check; it does not inherit acceptability merely from the base model.
[Microsoft license](https://github.com/microsoft/DeBERTa/blob/master/LICENSE),
[base model license metadata](https://huggingface.co/microsoft/deberta-v3-base).

## Concrete evaluation before adoption

This is a proposed experiment, not a claim of completed validation. The approved
[spike #827](https://github.com/unwired-dev/product/issues/827) and its child
slices #828–831 govern execution: evaluate English and Czech, with System and
Custom Categories reported separately; begin with public datasets and synthetic
cases, and add private mail only after separate explicit authorization. Include
mDeBERTa as a Czech-capable candidate. Physical phone evidence must include the
oldest supported standard, non-Pro iPhone, identified from Apple's compatibility
list for OS 27 or newer. No numerical adoption budget or fixed timebox has been
approved; record measured tradeoffs before proposing either.

The steps below provide research starting points within that approved scope:

1. Build a locally held, appropriately authorized labeled corpus for our actual
   categories. Include overlaps, uncategorized mail, newsletters resembling human
   mail, transactional messages, and relevant languages. Separate senders, Threads,
   and repeated templates across training/validation/test, with a later-time test
   slice to reduce leakage. Do not upload private user mail for training.
2. Compare existing rules, a cheap text-feature classifier, fine-tuned xsmall,
   fine-tuned small, and base as a quality reference. For Custom Categories,
   separately test NLI on categories unseen during task adaptation. Avoid letting
   strong System Category results conceal weak Custom Category performance.
3. Evaluate metadata/subject/snippet inputs first; measure the additional benefit
   and frequency of body fallback. Sweep 128/256/512 token budgets and, for NLI,
   5/20/50 candidate categories. These are experiment settings, not usage claims.
4. Report per-category precision/recall, macro-F1, coverage versus abstention,
   People false positives, overlap handling, and per-language results. Calibrate
   thresholds on validation data and freeze them before the held-out test. Include
   error costs for downstream cleanup and contact suggestions; overall accuracy
   alone is insufficient.
5. Export the best small candidates. Verify tokenizer and output parity before
   and after FP16/INT8 conversion. On physical supported iPhone, iPad, and Mac
   devices, measure final download size, peak memory, cold load, warm p50/p95
   latency, sustained batch energy/thermal behavior, and CPU versus Core ML
   execution. Include simultaneous Inbox activity and background cancellation.
6. Adopt only if quality improves enough over rules to justify measured storage,
   memory, latency, and energy costs. If fixed categories work but dynamic ones
   do not, preserve that distinction rather than claiming universal categorization.

No email accuracy, latency, memory, battery, export-compatibility, or OS 27
qualification result was produced here. The completed work is source research,
checkpoint metadata inspection, and reproducible size arithmetic.
