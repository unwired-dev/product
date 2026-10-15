# Spike #831: DeBERTa categorization in the native Mac host

## Recommendation

**Feasible on the Mac for the XSmall candidates in FP16; not yet for System
mDeBERTa; INT8 weight quantization is not worth adopting.**

- **System XSmall (FP16)** classifies a message in one 13 ms pass on the Neural
  Engine and GPU (72 messages a second sustained), with every golden decision and
  token matched. It fits background categorization of arriving mail.
- **Custom XSmall (FP16)** costs one 16 ms pass per Custom Category: about 0.1 s a
  message at 5 categories, 0.3 s at 20 and 0.8 s at 50. Interactive use is
  practical up to roughly 20 categories; larger sets need batching or a cheaper
  formulation before delivery.
- **Custom mDeBERTa (FP16, 256 tokens)** works at 31 ms a pass (about 1.6 s a
  message at 50 categories) but is 3.8× the download of XSmall (531 MB zipped).
- **System mDeBERTa (FP16, 512 tokens)** is not practical as exported: 3.1 s a
  pass. Core ML plans its relative-position `gather_along_axis` and `select`
  operations on the CPU (88 CPU operations), so most of the model waits on the
  CPU. It needs a different relative-position export before it can be judged.
- **INT8** halves the download but gives no latency gain, uses as much or more
  peak memory than FP16 here, widens probability drift (up to 0.12 in the host,
  0.50 for Custom XSmall on CPU+GPU in the export check) and changes one System
  XSmall decision. The first load of INT8 System mDeBERTa took 29.5 minutes.

Mac results do not establish feasibility on the limiting standard iPhone; that
evidence belongs to [#830](https://github.com/unwired-dev/product/issues/830).
Quality conclusions remain those of #828 and #829; this report measures whether the
frozen pipelines run, not how good they are.

## Host and versions

- Apple Mac mini, `Mac16,10`, Apple M4, 16 GB, macOS 27.0.1 (26A434), physical.
  Shared with other agent sessions; load averages were 1.7–2.5 during the matrix.
- Xcode 27.0, React Native macOS 0.81.9 with Hermes, the packaged `Testing`
  configuration of the `categorization-spike` Mock Mail Session, ad-hoc signed
  under a disposable `dev.unwired.mock.*` identity in the App Sandbox.
- Export: Core ML Tools 9.0, PyTorch 2.7.0, Transformers 5.19.0, NumPy 2.3.5 (see
  [README](README.md)). Models: the four frozen candidates in
  `../system-category-benchmark/custom/bundle-v1.json`, verified by SHA-256.

## Method

The app bundles the compiled models (2.2 GB for all four candidates in both
precisions) and runs them through a first-party Swift runner on the system Core ML
framework, called from the page through a React Native bridge. The tokenizer,
preprocessing and category policy are Swift ports checked token for token against
the golden outputs.

The page's launch-selected unattended run (`probe/autorun.zsh matrix`) drove the
same actions as its buttons, because this host cannot enable XCTest Automation
Mode without a password (`probe/run.zsh` is the XCUITest equivalent). For each
candidate and precision it checked the golden outputs, classified one sample and
benchmarked 3 rounds of the 12 golden samples; Custom candidates ran 5, 20 and 50
Custom Categories. It then recorded compute plans and compared compute units for
System XSmall. Raw evidence: [`results/host-matrix-2026-10-15.jsonl`](results/host-matrix-2026-10-15.jsonl);
tables regenerate with `uv run python summarize.py results/host-matrix-2026-10-15.jsonl`
([`results/host-tables.md`](results/host-tables.md)).

- **Load** is the first load of a candidate, precision and compute-unit choice in a
  fresh process; it includes Core ML's device specialization, which the system
  caches across launches, so later launches load faster. No cache was purged, so
  these are first-use loads after install, not reboot-cold loads.
- **Pass** latency is per model pass, excluding tokenization; p50 and p95 are
  warm. Throughput includes tokenization and the first pass.
- **Peak memory** is the process's sampled physical footprint (10 ms) during the
  request, including the Inbox host.
- **Energy** is the kernel's CPU energy estimate for the process; it does not
  attribute GPU or Neural Engine energy, so accelerator runs understate their cost.
- **Interface responsiveness** is how late the main thread answered a 10 ms probe
  while inference ran on a background queue beside the live Inbox.

## Results

### Sizes

| Candidate       | FP16 compiled | FP16 zipped | INT8 compiled | INT8 zipped |
| --------------- | ------------- | ----------- | ------------- | ----------- |
| System XSmall   | 153 MB        | 138 MB      | 78 MB         | 67 MB       |
| System mDeBERTa | 589 MB        | 529 MB      | 302 MB        | 256 MB      |
| Custom XSmall   | 153 MB        | 138 MB      | 78 MB         | 67 MB       |
| Custom mDeBERTa | 579 MB        | 531 MB      | 292 MB        | 257 MB      |

INT8 quantizes every large weight, the word embeddings included (`results/<run>.json`).

### Parity in the host

Every candidate and precision matched every golden token id (12 System and 72
Custom checks each). The largest probability difference from the fp32 reference
was 0.009 (System XSmall FP16), 0.023–0.035 for the other FP16 exports, and
0.03–0.12 for INT8. The only decision change was System XSmall INT8 dropping Orders
(0.41 against its 0.40 threshold) from an Orders and Flights message. The export
check's tolerance is 0.02 for FP16 and 0.05 for INT8, so the mDeBERTa and Custom
XSmall FP16 exports and most INT8 exports exceed it without changing decisions.

### Latency, memory and responsiveness

| Candidate (FP16, all units) | Pass p50 | Pass p95 | First load | Peak memory  |
| --------------------------- | -------- | -------- | ---------- | ------------ |
| System XSmall               | 13.3 ms  | 13.7 ms  | 1.8 s      | 348 MB       |
| System mDeBERTa (512)       | 3,098 ms | 3,151 ms | 11.8 s     | 2,161 MB     |
| Custom XSmall               | 16.4 ms  | 17.6 ms  | 9.5 s      | 650–1,182 MB |
| Custom mDeBERTa             | 31.5 ms  | 32.1 ms  | 17.5 s     | 434–928 MB   |

Custom latency scales linearly with the category count, one pass per category.
Main-thread delay stayed at or below 0.24 ms at p95 in every run, and the thermal
state stayed nominal throughout; no sustained-load throttling was observed in
runs of up to about 2.5 minutes.

### Compute units (System XSmall FP16)

| Units                      | Pass p50 | First pass | CPU energy a pass |
| -------------------------- | -------- | ---------- | ----------------- |
| CPU only                   | 172 ms   | 189 ms     | 21 mJ             |
| CPU and GPU                | 12.5 ms  | 2,659 ms   | 7 mJ              |
| CPU and Neural Engine      | 14.5 ms  | 37 ms      | 2 mJ              |
| CPU, GPU and Neural Engine | 13.3 ms  | 13 ms      | 6 mJ              |

Core ML's compute plan places 456 of 501 operations on the Neural Engine and 45 on
the GPU for the XSmall models. The operations the Neural Engine cannot take are the
attention-mask and relative-position helpers (`cast`, `expand_dims`, `gather`,
`greater_equal`, `select`). The GPU path compiles its shaders on the first pass
(2.7 s).

### Cancellation and release

Cancel stopped a running benchmark before its next pass and showed no partial
result. Dismissing the page mid-benchmark cancelled it the same way and released
the model: the footprint fell from 402 MB to 137 MB. A missing model shows the
unavailable notice; nothing falls back to a server. The Mac host has no Profile
Lock yet ([#648](https://github.com/unwired-dev/product/issues/648)), so
cancellation on Profile Lock is unavailable to demonstrate.

## Failed and unexplored paths

- Enumerated or flexible sequence lengths convert but crash Core ML prediction
  (SIGSEGV), so every input pads to its full budget; short messages pay for 256 or
  512 tokens. Multifunction models with a few fixed lengths were not tried.
- Batched passes for Custom Categories were not tried; each category is a separate
  pass.
- The System mDeBERTa relative-position export was not reworked.
- Activation quantization and palettization were not tried; INT8 here is
  weight-only.

## Limitations

- One physical Mac on a shared host; another session's work could add noise,
  though load stayed low.
- Ad-hoc signing: the synthetic Inbox beside the page could not open its private
  storage (an expected Keychain limitation), which does not affect the spike.
- The run drove the page through its own actions, not synthetic clicks; pop-up
  and button interaction are covered by the component tests.
- CPU-only energy attribution, no reboot-cold loads, and no runs longer than a few
  minutes.
- Public and synthetic samples only; no private mail was used.
