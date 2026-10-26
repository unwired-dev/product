# Spike #830: DeBERTa categorization on iPhone and iPad

## Recommendation

**Feasible on the iPhone 17 Pro Max for the XSmall candidates in FP16 and for
Custom mDeBERTa; not for System mDeBERTa; INT8 is not worth adopting. The iPad Pro
13-inch M4 is not yet measured.**

- **System XSmall (FP16)** classifies a message in one 13.4 ms pass (15.3 ms at
  p95, 71 messages a second sustained) at a 205 MB peak, with every golden token
  and decision matched. It fits background categorization of arriving mail on the
  phone, matching the Mac.
- **Custom XSmall (FP16)** costs one 13.2 ms pass per Custom Category: about
  0.07 s a message at 5 categories, 0.28 s at 20 and 0.69 s at 50.
- **Custom mDeBERTa (FP16, 256 tokens)** runs at 26 ms a pass (about 1.3 s a
  message at 50 categories), faster than the Mac's 31.5 ms, but is 3.8× the
  download of XSmall.
- **System mDeBERTa (FP16, 512 tokens)** is not practical as exported: 766 ms a
  pass at a 1.4 GB peak, rising to 2.0 GB in INT8. Core ML plans 88 of its
  operations on the CPU, as on the Mac.
- **INT8** gives no consistent latency gain: System XSmall improves slightly
  (13.2 ms p50 and 13.5 ms p95, against 13.4 and 15.3 ms in FP16), but loses one
  golden Category membership. Custom XSmall INT8
  takes 96 ms a pass and about 320 mJ of CPU energy a pass against 5 mJ in FP16,
  which suggests the quantized model runs largely on the CPU. The first load of
  INT8 System mDeBERTa took 6.7 minutes and INT8 Custom XSmall 60 seconds.

Proposed iPhone budgets for a delivery follow-up, with this run's headroom:

| Budget                                | Proposal | iPhone 17 Pro Max (System XSmall FP16) |
| ------------------------------------- | -------- | -------------------------------------- |
| Model download                        | ≤ 150 MB | 138 MB zipped                          |
| Pass latency at p95                   | ≤ 25 ms  | 15.3 ms                                |
| Warm benchmark process peak           | ≤ 400 MB | 205 MB                                 |
| Main-thread delay at p95              | ≤ 1 ms   | 0.01 ms                                |
| Custom Categories for interactive use | ≤ 20     | 0.28 s a message at 20                 |

These are provisional budgets for the idle workload below, not qualified delivery
limits. Cold loads, model switches and concurrent Inbox activity need separate
validation; some recorded load/switch peaks exceed 2 GB.

iPad results are deferred: the paired iPad Pro 13-inch M4
(`00008132-0011090A3C03001C`) stayed locked throughout the session, so the build
could not be installed or launched (`CoreDeviceError 10003`, "The device has not
been unlocked recently"). Rerun the commands below on it before setting iPad
budgets. Quality conclusions remain those of #828 and #829.

## Device and versions

- iPhone 17 Pro Max (`iPhone18,2`), iOS 27.2 (24B115), physical, connected over
  USB. Raw device details are in each run's `device.json`.
- Xcode 27.1 (27A9275), Expo SDK 57 (`expo` 57.0.31, `@expo/ui` 57.0.26), React
  Native 0.86.3 with Hermes, a Release build of the `categorization-spike` Mock Mail
  Session signed with an Apple Development certificate. The app is 2.3 GB, 2.2 GB
  of it the bundled models.
- Models and export as in the Mac [report](REPORT.md): the four frozen candidates
  in both precisions, compiled on the Mac and specialized by Core ML on the device.

Both published iPhone evidence files were recorded from source revision
`d444734544d01697d4daf0f60a2ae47047c9c74b`, before the first OCR fixes. They are
historical physical-device observations of that build. The shared session,
request admission and incremental resource cleanup changed in
`30f77a75e63e77e2842bfc8d5f308b9ec00f8a67`. A Release build at that corrected
revision succeeded, but the iPhone states rerun was deferred when the device
disconnected or locked. No post-fix physical run is published here. In particular,
the older lifecycle records do not qualify the corrected session's cancellation,
stale-result rejection or release behavior. The native inference and measurement
sources were unchanged by those OCR fixes.

## Method

The iPhone runs the same Swift runner, tokenizer and category policy as the Mac
host through the same bridge; the page shows them in a native SwiftUI form. The
page's launch-selected unattended run drove the actions its buttons perform, from
[`probe/device-autorun.zsh`](probe/device-autorun.zsh):

```sh
cd apps/mobile
UNWIRED_MOCK_SCENARIO=categorization-spike mise exec -- pnpm native:generate
mise exec -- xcodebuild build -workspace ios/UnwiredMail.xcworkspace -scheme UnwiredMail \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath ../../scratchpad/DerivedData -allowProvisioningUpdates
cd ../..
xcrun devicectl device install app --device <udid> \
  scratchpad/DerivedData/Build/Products/Release-iphoneos/UnwiredMail.app
tools/deberta-mac-spike/probe/device-autorun.zsh <udid> states
tools/deberta-mac-spike/probe/device-autorun.zsh <udid> matrix
```

The device must stay unlocked with Auto-Lock off for the whole run. The script records `device.json`, blanks the app's evidence file, launches
the app with the run selected, copies the evidence back with `devicectl` and checks
it with `summarize.py`. The matrix covers the same candidates, precisions, 3 rounds
of 12 golden samples, 5, 20 and 50 Custom Categories, compute plans and System
XSmall compute units as the Mac. Raw evidence:
[`results/iphone-matrix-2026-10-26.jsonl`](results/iphone-matrix-2026-10-26.jsonl)
and [`results/iphone-states-2026-10-26.jsonl`](results/iphone-states-2026-10-26.jsonl);
tables regenerate with `uv run python summarize.py results/iphone-matrix-2026-10-26.jsonl`
([`results/iphone-tables.md`](results/iphone-tables.md)).

Load, pass, peak memory, energy and main-thread delay have the Mac report's
definitions. Peak memory is the whole app process. The phone stayed connected over
USB; no concurrent Inbox workload ran.

## Results

### Parity on the iPhone

Every candidate and precision matched every golden token id (12 System and 72
Custom checks each). The largest probability difference from the fp32 reference
was 0.008 (System XSmall FP16), 0.019–0.035 for the other FP16 exports and
0.031–0.120 for INT8. The only decision change was the Mac's: System XSmall INT8
drops Orders from an Orders and Flights message.

Against the export tolerances of 0.02 for FP16 and 0.05 for INT8, System mDeBERTa
FP16 (0.0247), Custom mDeBERTa FP16 (0.0346), System mDeBERTa INT8 (0.0650) and
Custom mDeBERTa INT8 (0.1203) exceed the score tolerance despite matching decisions.

### Latency, memory and responsiveness

| Candidate (FP16, all units) | Pass p50 | Pass p95 | First load in matrix | Warm benchmark peak |
| --------------------------- | -------- | -------- | -------------------- | ------------------- |
| System XSmall               | 13.4 ms  | 15.3 ms  | 0.155 s              | 205 MB              |
| System mDeBERTa (512)       | 766 ms   | 780 ms   | 22.4 s               | 1,448 MB            |
| Custom XSmall               | 13.2 ms  | 13.5 ms  | 2.4 s                | 203–317 MB          |
| Custom mDeBERTa             | 26.0 ms  | 26.6 ms  | 0.6 s                | 368–398 MB          |

Custom pass latency stayed flat at 5, 20 and 50 categories, so message latency
scales linearly with the count. Main-thread delay stayed at or below 0.09 ms at
p95 in every matrix run; the worst single delay was 135 ms while INT8 System mDeBERTa
loaded. The thermal state moved from nominal to fair during INT8 System mDeBERTa
and stayed fair to the end without reaching serious. Aggregate p50/p95 stayed
similar across the later Custom Category-count runs of up to 1,800 passes; the
records contain no per-pass time series to establish within-run latency drift.

The table's memory values cover warmed benchmarks, not the whole matrix's load
and model-switch peaks. System mDeBERTa FP16 compute-plan requests reached
2,194 MB, and the next Custom XSmall FP16 golden request peaked at 2,100 MB while
switching away from it. Custom mDeBERTa INT8's golden/load request reached
1,435 MB, versus 298–299 MB in its later benchmarks. These whole-process samples
can include memory retained from the preceding model; they do not isolate a
candidate's cold peak. INT8 Custom mDeBERTa has a lower warm benchmark footprint
than FP16, while the other candidates have higher INT8 benchmark peaks.

### Compute units (System XSmall FP16)

| Units                      | Pass p50 | Pass p95 | Messages a second | CPU energy a pass |
| -------------------------- | -------- | -------- | ----------------- | ----------------- |
| CPU only                   | 29.4 ms  | 30.4 ms  | 33.1              | 124 mJ            |
| CPU and GPU                | 6.0 ms   | 6.9 ms   | 20.3              | 45 mJ             |
| CPU and Neural Engine      | 15.1 ms  | 19.0 ms  | 64.7              | 12 mJ             |
| CPU, GPU and Neural Engine | 13.4 ms  | 15.3 ms  | 71.4              | 6 mJ              |

The GPU has the fastest warm pass but its first pass takes 1,532 ms,
which lowers its sustained throughput. The iPhone compute plan reports 485 of
501 XSmall operations on the Neural Engine, 15 on the GPU, the mask and
relative-position helpers elsewhere; System mDeBERTa keeps 88 operations on the
CPU (`gather_along_axis`, `select`, `cast`, `gather`).

The operation placement differs from the Mac's recorded 456 Neural Engine and
45 GPU operations. These are preferred-device plans, not an execution trace;
shader compilation is a possible explanation for the first-pass delay, not a
directly measured cause.

### Cancellation and release

The pre-fix states run recorded two cancelled benchmarks and two releases. The
autorun invoked Cancel and then simulated dismissal by unmounting the inner
spike component; it did not drive Back to All Inboxes or an interactive Back
gesture. The footprint fell from 363 MB to 279–290 MB after release. The source
discards partial results and the component tests cover late-result rejection;
the JSONL alone does not prove the rendered state. Physical Back/gesture and
post-fix lifecycle qualification remain deferred. The missing-model notice and
absence of a server fallback are covered by source and component tests, not by
these physical evidence files. The Expo client has no Profile Lock yet
([#648](https://github.com/unwired-dev/product/issues/648)), so cancellation on
Profile Lock is unavailable to demonstrate.

## Limitations

- One iPhone; the iPad Pro 13-inch M4 run is deferred until it can be unlocked.
- CPU-only energy attribution as on the Mac, so accelerator runs understate their
  cost; no battery-drain measurement.
- Loads are first loads after install, not reboot-cold loads.
- The run drove the page through its own actions. Component tests substitute
  native controls; screenshots show appearance but do not prove physical picker,
  button or Back interaction.
- The published evidence precedes the OCR fixes; a successful corrected Release
  build does not replace the deferred physical lifecycle rerun.
- No concurrent Inbox workload: main-thread delay measures the idle Mock Mail
  Session only.
- Public and synthetic samples only; no private mail was used.
