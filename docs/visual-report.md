# Visual report

The visual report compares reproducible native captures of the populated Inbox with the
approved Figma frames and with reviewed native baselines
([#1061](https://github.com/unwired-dev/product/issues/1061)). It runs in reporting mode: it
never blocks a pull request, and it never reports a missing capture, reference or baseline
as passing.

Two results stay separate:

- **Figma conformance** compares a capture with its pinned, exported frame. A deviation is a
  finding for design review, not a failure.
- **Native baseline regression** compares a capture with the reviewed native screenshot of
  the same state. A regression shows that the app's rendering changed since the baseline was
  reviewed.

Coverage today is the canonical populated Inbox on iPhone in Light and Dark. iPad and Mac,
empty, error and loading states and other screens come in later slices. Mock content proves
appearance only, not provider integration.

## Run it

Build a `UNWIRED_MOCK_SCENARIO=open-read-relaunch` simulator Release app as in
[Expo validation](expo-client.md#validate), with `UNWIRED_COMMIT=$(git rev-parse HEAD)` set
when generating the native project so the app records its revision (the report reads
`unstamped` otherwise), then from `apps/mobile`:

```sh
mise exec -- pnpm test:visual /absolute/path/to/Release-iphonesimulator/UnwiredMail.app
```

The second argument selects another simulator device type; the default is
`com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro`. The command runs the
`testInboxVisual` journey through the [native runner](agents/native-validation.md), which owns the
Simulator, exports the journey's attachments from its result bundle and writes the report to
`artifacts/expo-bootstrap/native-<id>/visual-report/`. It exits 1 when the journey fails or the
report is incomplete.

In CI, the non-required **Expo visual report (iPhone)** job of the Mobile workflow runs the
same command on the packaged app the **Expo native build** job made, adds `report.md` to the
job summary and uploads the report as `expo-visual-report-iPhone-<run>-<attempt>`.

## What a capture fixes

`testInboxVisual` launches the `open-read-relaunch` preview Inbox, whose Synthetic Test
Messages are the [Mock Mail Session](mock-mail-sessions.md) fixture, once per appearance. It
switches the Simulator's appearance with `XCUIDevice.appearance`, and captures the whole screen
once two screenshots a second apart are identical. It fixes:

| Input       | Value                                                                                                                                              |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Content     | The `open-read-relaunch` fixture messages                                                                                                          |
| Clock       | `-UnwiredNow 2026-09-28T10:30:00Z`, which only a preview Inbox build reads; the status bar override reads 9:41, which the Simulator draws as 09:41 |
| Locale      | `-AppleLanguages (en) -AppleLocale en_US`, time zone `TZ=UTC`                                                                                      |
| Text size   | `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryL` (the default Large)                                                                 |
| Appearance  | Light, then Dark                                                                                                                                   |
| Device      | iPhone 18 Pro Simulator, iOS 27.0 runtime, portrait, 402 × 874 pt at 3×                                                                            |
| Status bar  | 9:41 override (drawn 09:41), Wi-Fi, four cellular bars, a full battery not charging (`simctl status_bar`)                                          |
| Environment | The journey's `Visual environment` attachment, the Xcode version and the app revision                                                              |

The runner sets the status bar for this journey only. The report records the environment and
the app's `UnwiredCommit` revision in `result.json` and in each capture's
`baseline-candidate.json`. A baseline compares only with a capture from the same environment,
Xcode version included: any other capture leaves the baseline comparison incomplete. The
committed baselines come from the CI job (Xcode 27.0), so a local run with another Xcode
version reports Figma conformance and an incomplete baseline comparison.

## References and provenance

[`apps/mobile/visual/inbox.json`](../apps/mobile/visual/inbox.json) maps each capture to its
expected images, which are committed beside it, so CI never needs Figma:

- `figma`: the Figma file, frame node, the approved section that holds it, the export scale,
  the export time and the exported PNG's SHA-256. The frames are the newest approved iPhone
  Inbox frames: **Proposal · iPhone — Inbox List · Light** from
  "#2647 #2646 #2131 Inbox consistency review · approved 2026-11-22" and
  **A2 iPhone · Inbox · Dark · lighter unread dot** from
  "#2650 Warning amber and unread dot · approved 2026-11-22". `fileVersion` is `null`: the
  Figma MCP server cannot read or save version history, so the committed export and its hash
  are the pin until a version ID is recorded (see [Refresh](#refresh-a-reference)).
- `baseline`: the reviewed native capture with the app revision, toolchain and environment it
  was captured with, and the review that accepted it.

The report refuses an image whose SHA-256 differs from the manifest, so a reference cannot be
replaced without changing its provenance in the same reviewed change.

## Read the report

`visual-report/` holds `result.json`, `report.md` and, per capture:

- `actual.png`, the capture;
- `figma/reference.png`, `figma/overlay.png` and `figma/diff.png`;
- `baseline/reference.png`, `baseline/overlay.png` and `baseline/diff.png`;
- `baseline-candidate.json`, the provenance a reviewed baseline of this capture would record.

`overlay.png` blends reference and capture half and half; `diff.png` draws differing pixels
in red over a faded reference. A design reviewer, or the design judge, reads
`figma/reference.png` and `actual.png` as the frame and the capture of one state.

`result.json` lists, separately:

| Field                 | Meaning                                                                                                                     |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `figmaDeviations`     | Captures whose differing pixels exceed the Figma tolerance                                                                  |
| `baselineRegressions` | Captures whose differing pixels exceed the baseline tolerance                                                               |
| `captureFailures`     | A missing capture or environment record, a missing or altered reference, or a capture whose size differs from its reference |
| `incompleteCoverage`  | A capture with no reviewed reference or baseline yet, a baseline from another environment, or a device with no captures     |

`status` is `complete` only when the last two are empty. Comparisons never resize an image:
a capture that does not align with its reference fails instead.

## Tolerances

[pixelmatch](https://github.com/mapbox/pixelmatch) compares locally. It skips pixels it
detects as anti-aliasing, so native font smoothing does not count as a difference, and its
per-pixel `threshold` (0 to 1, in YIQ colour distance) absorbs colour rounding. Each
comparison then allows a share of differing pixels, `maxDiffRatio`. Both are set per kind in
the manifest with their reason; there is no exact pixel match against Figma and no mask over
app content.

- **Figma**: threshold 0.1 and 1% of pixels. Figma draws text with its own rasterizer and
  Liquid Glass as a static blur, where iOS samples the content behind it; system controls
  such as the status bar, search field and toolbar glass are drawn by UIKit, not by the
  frame's component copies. Differences in content, layout, colour or type exceed it.
- **Baseline**: threshold 0.1 and 0.1% of pixels: the same app, fixture and toolchain draw
  the same pixels apart from glass sampling at the edges of the floating bars.

## Known differences

The fixture's Synthetic Test Messages are not the frame's sample messages, so the Figma
comparison flags every row's text; they carry no attachments, so the frames' attachment glyphs
are missing too. The frames also draw a More button, a List/Chat toggle and Mail View chips,
which the app has not built yet ([DESIGN.md](../DESIGN.md#known-frame-differences)). Record each approved difference and each
outstanding deviation in the capture's `figma.approvedDifferences` and
`figma.outstandingDeviations`. An approved difference documents a reviewed decision; it does
not change the computed status, so approval never hides a mismatch. Where a frame contradicts a product requirement, the frame wins
([AGENTS.md](../AGENTS.md#design)): the difference stays an outstanding deviation until the app
follows the frame and the requirement is corrected, or the owner decides otherwise. A difference caused by the capture's fixed inputs,
such as its locale, status bar or fixture, is approved with the input that causes it.

Open [#1057](https://github.com/unwired-dev/product/issues/1057) migrates the mobile controls
to native components; when it lands, the baselines need a reviewed refresh.

## Refresh a reference

Never replace an expected image because a comparison failed.

- **Native baseline**: when the app's appearance changes deliberately, take the report from
  the pull request's **Expo visual report** job artifact, have the design review compare the new `actual.png` with the pinned frame, the
  [design tokens](../DESIGN.md) and the product requirements, then copy `actual.png` to
  `apps/mobile/visual/baseline/<capture>.png` and its `baseline-candidate.json` into the
  capture's `baseline`, adding `capturedIn` (the run) and `reviewedIn` (the review). Record
  the approved differences and outstanding deviations in the same change.
- **Figma reference**: a changed frame first needs the owner's
  [design approval](agents/implementation-review.md#design-approval). Export the approved
  frame at the manifest's scale through the Figma MCP server's `download_assets` (file key,
  node ID, `defaultScale`), or with a Figma token through the REST API:
  `GET https://api.figma.com/v1/images/<file>?ids=<node>&scale=<scale>&format=png&version=<id>`,
  whose `version` comes from `GET https://api.figma.com/v1/files/<file>/versions`. Download
  the returned URL at once, since it expires, commit the PNG and update `figma` with its
  SHA-256, export time and, when known, the version ID.
