# DeBERTa categorization spike on Mac, iPhone and iPad

[#831](https://github.com/unwired-dev/product/issues/831) and
[#830](https://github.com/unwired-dev/product/issues/830) ask whether the frozen
DeBERTa candidates from [#829](https://github.com/unwired-dev/product/issues/829)
run practically inside the AppKit React Native host and the Expo client on iPhone
and iPad. This is an isolated research
spike for [#827](https://github.com/unwired-dev/product/issues/827). It changes no
Category assignment, classifies no mailbox and has no server fallback. Delivery
stays in [#649](https://github.com/unwired-dev/product/issues/649) and
[#650](https://github.com/unwired-dev/product/issues/650). The findings, with the
measurements and a feasibility recommendation, are in the Mac
[spike report](../tools/deberta-mac-spike/REPORT.md) and the iPhone and iPad
[mobile report](../tools/deberta-mac-spike/MOBILE.md).

## Selecting the spike

Only the `categorization-spike` [Mock Mail Session](mock-mail-sessions.md) builds
contain the spike. They show the synthetic `open-read-relaunch` mailbox. On Mac and
iPad, the reader shows the **Categorization spike** page when no message is
selected. iPhone opens on the page; **Back** to All Inboxes leaves it for the
session. Every other build, including production and TestFlight, compiles neither
the page nor its Core ML runner; `verify:bundle` rejects the page in any other
bundle.

## Behavior

The page offers four pop-ups (pickers in a form on iPhone and iPad): **Candidate** (the two System and two Custom
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
  frozen golden outputs on this device.
- **Compute Plan** reports where Core ML plans to run each operation and which
  operations the Neural Engine cannot take.

Each result also reports model load time (only on the first load of a candidate,
precision and compute-unit choice), pass latency, peak memory, main-thread delay,
the kernel's CPU energy estimate and the thermal state before and after.

**Cancel**, and dismissing the page by selecting a message, closing the window or,
on iPhone, going Back, stop a request before its next model pass, never show its partial result and
release the loaded model. A build without exported models, or a model that fails to
load, shows an unavailable notice; nothing falls back to a server. The Mac host has
no Profile Lock yet ([#648](https://github.com/unwired-dev/product/issues/648)), and
neither has the Expo client, so cancellation on Profile Lock is not demonstrated.
On iPhone and iPad the benchmark shows sample progress without running statistics.

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

For a connected iPhone or iPad, generate the scenario and build Release for the
device; the [mobile report](../tools/deberta-mac-spike/MOBILE.md) lists the exact
commands, including the unattended `UNWIRED_SPIKE_AUTORUN` runs and copying the
results from the app container.

```sh
cd apps/mobile
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm native:generate
mise exec -- pnpm ios --configuration Release --device
```

## Verify

Run these commands from the repository root:

```sh
swift test --package-path native/categorization-spike
mise exec -- pnpm --filter @private-email/macos exec jest test/categorization-spike.test.tsx
mise exec -- pnpm --filter @private-email/mobile exec jest test/categorization-spike.test.tsx test/categorization-spike-routing.test.tsx
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/mobile build
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/mobile verify:bundle
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/macos build
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm --filter @private-email/macos verify:bundle
```

The Swift tests check the tokenizer, preprocessing, category policy and FP16 Core ML
decisions against every golden output, plus cancellation; a candidate whose export
is missing fails with the export command to run. The component tests cover the unavailable state,
decoded results, a malformed result failing closed, Cancel and dismissal. Mac
results do not establish feasibility on the physical iPhone and iPad. Following the
owner's [#1106](https://github.com/unwired-dev/product/issues/1106) decision, #830
targets the available iPhone 17 Pro Max and iPad Pro 13-inch M4 on version-27
systems. Only the iPhone is measured so far; the iPad run is deferred (see the
[mobile report](../tools/deberta-mac-spike/MOBILE.md)). A standard non-Pro iPhone is not a prerequisite. Results hold for each
tested configuration only, never for untested hardware.
