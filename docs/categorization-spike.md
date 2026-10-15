# DeBERTa categorization spike in the native Mac host

[#831](https://github.com/unwired-dev/product/issues/831) asks whether the frozen
DeBERTa candidates from [#829](https://github.com/unwired-dev/product/issues/829)
run practically inside the AppKit React Native host. This is an isolated research
spike for [#827](https://github.com/unwired-dev/product/issues/827). It changes no
Category assignment, classifies no mailbox and has no server fallback. Delivery
stays in [#649](https://github.com/unwired-dev/product/issues/649) and
[#650](https://github.com/unwired-dev/product/issues/650). The findings, with the
measurements and a feasibility recommendation, are in the
[spike report](../tools/deberta-mac-spike/REPORT.md).

## Selecting the spike

Only the Mac `categorization-spike` [Mock Mail Session](mock-mail-sessions.md) build
contains the spike. It shows the synthetic `open-read-relaunch` mailbox, and when no
message is selected the reader shows the **Categorization spike** page. Every other
build, including production and TestFlight, compiles neither the page nor its Core
ML runner; `verify:bundle` rejects the page in any other bundle.

## Behavior

The page offers four pop-ups: **Candidate** (the two System and two Custom
candidates), **Precision** (FP16 or INT8), **Compute units** and **Sample** (the
twelve synthetic golden messages, six English and six Czech). Custom candidates add
**Custom Categories**: the six golden categories, or the first 5, 20 or 50 of the
52 in `categories-v1.json`.

- **Classify** shows the bounded input and its token count, every category's score
  against its threshold, a checkmark for each membership, and the decided
  categories. A message with no membership shows **Uncategorized**: the candidate
  abstains. System candidates apply People only when no purpose category applies.
- **Benchmark** runs every sample three times with the selected Custom Category
  count and shows progress with **Cancel**.
- **Check Golden Outputs** compares token ids, scores and decisions with the
  frozen golden outputs on this Mac.
- **Compute Plan** reports where Core ML plans to run each operation and which
  operations the Neural Engine cannot take.

Each result also reports model load time (only on the first load of a candidate,
precision and compute-unit choice), pass latency, peak memory, main-thread delay,
the kernel's CPU energy estimate and the thermal state before and after.

**Cancel**, and dismissing the page by selecting a message or closing the window,
stop a request before its next model pass, never show its partial result and
release the loaded model. A build without exported models, or a model that fails to
load, shows an unavailable notice; nothing falls back to a server. The Mac host has
no Profile Lock yet ([#648](https://github.com/unwired-dev/product/issues/648)), so
cancellation on Profile Lock is not demonstrated.

Each result is appended as one JSON line to `categorization-spike.jsonl` in the
app's temporary directory; the page shows its path.

## Build and run

Export the models first, as the [export tool](../tools/deberta-mac-spike/README.md)
describes. The build copies `tools/deberta-mac-spike/work/models` and the golden
files into the app; without exported models the page reports them unavailable.

```sh
cd apps/macos
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm native:build Testing
open ../../artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app
```

## Verify

```sh
cd native/categorization-spike && swift test
cd apps/macos && mise exec -- pnpm exec jest test/categorization-spike.test.tsx
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/macos build
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/macos verify:bundle
```

The Swift tests check the tokenizer, preprocessing, category policy and FP16 Core ML
decisions against every golden output, plus cancellation; a candidate whose export
is missing fails with the export command to run. The component tests cover the unavailable state,
decoded results, a malformed result failing closed, Cancel and dismissal. Mac
results do not establish feasibility on the standard iPhone baseline, which
[#830](https://github.com/unwired-dev/product/issues/830) owns.
