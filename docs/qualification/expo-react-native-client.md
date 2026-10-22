# Expo and React Native platform qualification

Summary reviewed: 2026-10-04. Individual evidence entries below retain their own
dates, checked revisions and limitations; newer entries do not imply a fresh
review of the whole summary. Summary status: **Expo bootstrap builds and launches on
iOS/iPadOS 27 and the native Mac mock Inbox builds and launches on macOS 27;
full replacement qualification remains incomplete**.

The [mobile bootstrap](../expo-client.md) now uses Expo 57.0.25, React Native
0.86.3 and React 19.2.3 with Effect 4.0.0-rc.118. Xcode 27 and the iOS 27 runtime
are available on the development host. The maintainer's earlier native-validation
deferral still applies to unavailable release checks. Mac host evidence follows.

## Physical reference access update, 2026-10-21

The [native validation guide](../agents/native-validation.md#performance-qualification)
now records the nominated iPhone, iPad and Mac references. This supersedes the
pending iPad nomination in the 2026-10-20 entry below, preserving its measured
results and limitations. [#1106](https://github.com/unwired-dev/product/issues/1106)
owns the local Xcode access and weekend owner-operated dictation/VoiceOver handoff.
Hardware nomination and published Apple Intelligence eligibility do not prove
runtime API readiness or passing qualification. Measurements remain outstanding
under #625, #626, #822 and #830; this update records no test run.

## On-device assistance qualification, 2026-10-22

Issue [#625](https://github.com/unwired-dev/product/issues/625) adds the
[qualification build and recording procedure](../assistance-qualification.md).
The owner session arranged in [#1106](https://github.com/unwired-dev/product/issues/1106)
completed the physical iPhone/iPad runs and manual checks described below.
The owner accepted the results and waived the Mac manual checks; #625 closes
when [#1158](https://github.com/unwired-dev/product/pull/1158) merges.
This does not complete the replacement's release qualification.

The reviewer inspected the implementation-run corpus-v1 JSONL at
`artifacts/assistance-qualification/macos.lYUSeG/assistance-qualification.jsonl`.
It records `Mac16,10`, macOS 27.0.1 (`26A434`), locale `en_US@rg=czzzzz`, preferred
languages `en-US`/`cs-CZ`, available Foundation Models and the device's Translation
targets. Its 20 cases yielded **19 pass, one limited, zero fail**. Czech-to-English
translation reported `unsupported-pair`; German/English translation, generation
and cancellation completed. The disposable app and container were removed by the
runner, whose retained ownership record identifies only that run's resources.

The implementation's iOS 27.0 (`24A434`) simulator run at
`artifacts/assistance-qualification/ios-sim.BQoMJX/assistance-qualification.jsonl`
yielded **16 pass, four limited, zero fail**. Its three translation pairs and
translation cancellation were limited by unavailable pairs. It is simulator
binding evidence, not physical iPhone or iPad qualification. The task-owned
simulator was deleted.

Both earlier device records have an empty commit stamp. Their source attribution
comes from the implementation handoff, with the implementation committed as
`797c2d84f`, rather than from self-contained artifact provenance. Their obsolete
`evidence` metadata includes local filesystem paths; remove that field before
attaching either file to an issue. Review fixes omit paths both natively and in
the shared decoder, reject unexpected cancellation errors and make the Mac
runner fail for failed or incomplete matrices. The synthetic case inputs and
corpus version remain unchanged.

The reviewer independently rebuilt code commit
`0ea4ebabd7697d6f4027280a2cf09869b61a589b` with the same corpus and ran
`pnpm --filter @private-email/macos qualify:assistance` against the resulting
Testing app. Xcode 27.1 (`27A9275`), Swift 6.4, Node 24.21.0 and pnpm 11.5.2
used root lockfile SHA-256
`98d06dd1ca5033ca5aa7e9c8aad2a2ea532380edfa59aadf305487e1e04fd39a`.
The normal development-signed build first stopped for a missing
`dev.unwired.mail` profile. An ad-hoc source build succeeded; the runner then
signed its disposable copy with the authorized mock-only development profile.
The new evidence at
`artifacts/assistance-qualification/macos.PsmTIi/assistance-qualification.jsonl`
again records **19 pass, one limited, zero fail**, with Czech-to-English
`unsupported-pair`. It stamps the exact code commit and omits filesystem paths.
The helper completed Keychain cleanup; the reviewer independently verified that
the owned app, helper, container and process were absent. Later documentation
edits do not change that tested runtime code.

The recorded prose exposes material model limitations despite passing binding
contracts: Czech/German summaries and the Czech rewrite returned English; an
English rewrite added a subject line; replies with authored text echoed it; and
the German reply promised a response by Friday without authored intent. The
Czech committee-meeting summary also described a selection meeting. Recorded
facts are observations, not semantic correctness scores. These results neither
establish deterministic output nor authorize changes to prompts, assistance
scope or acceptance behavior.

The adapter selects `SystemLanguageModel.default` without a separate model-build
identifier. OS/build metadata and saved output cannot identify model updates
independently of the OS.

### Physical iPhone and iPad owner session

The [2026-10-22 corpus report](https://github.com/unwired-dev/product/issues/625#issuecomment-6334257229)
attributes both builds to PR head `f141778a3`, with corpus v1, root lockfile
SHA-256 `98d06dd1ca5033ca5aa7e9c8aad2a2ea532380edfa59aadf305487e1e04fd39a`
and Xcode 27.1 (`27A9275`). Both used Release, automatic Apple Development
signing, `UNWIRED_MOCK_SCENARIO=assistance-qualification` and bundle identifier
`dev.unwired.mock.assistance`. Their empty commit stamps reflect the missing
`UNWIRED_COMMIT` at prebuild; source attribution comes from the session report,
not the files themselves. The operational guide now sets it at `native:generate`.

| Device                           | OS and build             | Pass | Limited | Fail |
| -------------------------------- | ------------------------ | ---- | ------- | ---- |
| iPhone 17 Pro Max (`iPhone18,2`) | iOS 27.2 (`24B115`)      | 19   | 1       | 0    |
| iPad Pro M4 (`iPad16,5`)         | iPadOS 27.0.1 (`24A446`) | 19   | 1       | 0    |

Both recorded locale `en_US@rg=czzzzz`, preferred languages `en-US`/`cs-CZ`
and model availability `available`. The reviewer checked the retained
`iphone-run1.jsonl` and `ipad-run1.jsonl` under
`artifacts/assistance-qualification/` with the evidence checker. The one limited
case on each was Czech-to-English translation, `unsupported-pair`.
Czech/German messages produced English summaries on both. The iPhone rewrote
the Czech note into English; the iPad returned garbled Czech with a Polish word.
These observations join the Mac language and invented-content limitations in
[#1164](https://github.com/unwired-dev/product/issues/1164).

The iPad installation first failed with "This provisioning profile cannot be
installed on this device". Rebuilding with
`-destination 'platform=iOS,id=<iPad>' -allowProvisioningDeviceRegistration`,
alongside `-allowProvisioningUpdates`, registered it and allowed installation.
The guide also records Developer Mode and a fresh process launch, since resuming
the background app does not restart the module-scope corpus run.

The [manual-check report](https://github.com/unwired-dev/product/issues/625#issuecomment-6334849834)
records checks 1–3 passing on both devices: Summarize/Cancel/Dismiss, reader
Translate, and Rewrite/Suggest reply with acceptance and Undo. Draft Translate
passed on iPad; on iPhone it was blocked by
[#1165](https://github.com/unwired-dev/product/issues/1165), the format bar hidden
under the keyboard. Composer checks use an ordinary signed-in build with
device-local Mail Assistance enabled; the synthetic preview mailbox offers no
Reply or New Message.

For check 4, both devices still reported `available` after Apple Intelligence was
switched off and the app relaunched. Corpus runs again gave 19 pass, one limited,
zero fail; the owner also confirmed Summarize worked in the reader. This did not
exercise `assistance-disabled`. The app's Mail Assistance opt-in remains a
separate gate. For check 5, the owner [confirmed summaries and translations
worked in Airplane Mode](https://github.com/unwired-dev/product/issues/625#issuecomment-6335008428).
This is owner-observed UI evidence; no offline evidence file was captured because
the capture was interrupted.

The [owner decision of 2026-10-22](https://github.com/unwired-dev/product/issues/625#issuecomment-6335027314)
accepts all results and findings, accepts the Apple-Intelligence-off behavior
with no follow-up, and waives the Mac manual UI checks. The Mac automated corpus
result stands. Follow-ups remain #1164 and #1165. The waiver does not establish
passing Mac manual checks or cover unobserved unavailable reasons,
supported-but-uninstalled Translation pairs, or the separately deferred signed-in
enablement/sign-out checks. Those release checks remain required. This slice
retires no legacy tests.

The corpus-v1 `stale-result` case replaces the older request while availability
is pending; the shared store prevents that request from starting native
generation. Its passing `idle`/`ready` snapshots cover that request ordering,
not rejection of an older in-flight native result. Replacement after native
generation starts was therefore deferred in the earlier review. Corpus v2 at
`0d91ac2c5` counted both native starts after a 300 ms head start, but did not
establish that the older request was still pending at replacement. Its results
do not establish the v3 in-flight precondition.

### Corpus v3 in-flight replacement

The [physical v3 rerun report](https://github.com/unwired-dev/product/issues/625#issuecomment-6337498114)
and retained JSONL supersede v1 and v2 for this check. All three evidence files
stamp source commit `45aa8ad9761580f2b2a158925f01c047fb1f2abd` and corpus
version 3. The root lockfile SHA-256 remains
`98d06dd1ca5033ca5aa7e9c8aad2a2ea532380edfa59aadf305487e1e04fd39a`.
The reviewer inspected each file and reran the current evidence checker, which
exited 0 for each. These are retained physical-device results, not new device
runs performed during review.

| Evidence under `artifacts/assistance-qualification/` | Device       | OS and build             | Pass | Limited | Fail |
| ---------------------------------------------------- | ------------ | ------------------------ | ---- | ------- | ---- |
| `mac-v3.jsonl`                                       | `Mac16,10`   | macOS 27.0.1 (`26A434`)  | 19   | 1       | 0    |
| `ipad-v3.jsonl`                                      | `iPad16,5`   | iPadOS 27.0.1 (`24A446`) | 19   | 1       | 0    |
| `iphone-v3.jsonl`                                    | `iPhone18,2` | iOS 27.2 (`24B115`)      | 19   | 1       | 0    |

Each records model availability `available`, locale `en_US@rg=czzzzz`, preferred
languages `en-US`/`cs-CZ`, and one limitation, Czech-to-English translation with
`unsupported-pair`. Each `stale-result` row passes with `nativeStarts: 2` and
`inFlight: true`: the older summary reached the native binding and remained
pending immediately before replacement; both requests settled, the older input
was `idle`, and only the newer input was `ready`. In-flight replacement is now
qualified on all three nominated configurations and is no longer a deferred
release check. The separate unavailable-capability, uninstalled-language and
signed-in lifecycle checks above remain required; the manual-check waiver and
tracked output/UI limitations are unchanged.

## Native host qualification refresh, 2026-10-20

Issue [#623](https://github.com/unwired-dev/product/issues/623) remains incomplete.
This run qualifies the current packaged iPhone/iPad persistence journey and
hosted storage checks separately from the signed Mac build. It does not qualify
the current Mac lifecycle journey. The signed Mac journeys in the 2026-10-03
entry below came from an earlier host and revision; they remain historical
evidence and do not replace this run's unavailable Mac interaction checks.

The tested source tree is `02b105ffd`. Review head `b8b214438` adds the
TestFlight local-profile exclusion, its runner regression and documentation;
native generators, application sources, dependencies and journey inputs are
unchanged. Subsequent review edits document these results and the remaining
operational checks.

The host is a Mac mini, Apple M4, 16 GB (`Mac16,10`), running macOS 27.0.1
(`26A434`), Xcode 27.1 (`27A9275`), Swift 6.4, and the iOS 27.0 Simulator runtime
(`24A434`). Tooling is Node 24.21.0, pnpm 11.5.2 and mise Ruby 3.3.12. The root
`pnpm-lock.yaml` SHA-256 is
`26c8ba0d6318d7b12f9a50933d49055bb2dd16ebe80695676150ff506d25135e`.
Deployment floors remain iOS/iPadOS/macOS 27. The runs use the root lockfile and
its separate mobile and Mac native graphs.

The reviewer inspected the retained logs, generated probe inputs and runner
ownership/results. Native builds and journeys below were run by the implementer,
not rerun by the reviewer:

- Expo `native:generate`, Pod installation and the arm64 Release simulator build
  succeeded with packaged JavaScript, Hermes and native modules. The
  `open-read-relaunch` Mock Mail Session passed `testSelectAndReplaceMessage`
  through `pnpm --filter @private-email/mobile test:native` on fresh owned
  iPhone 18 Pro and iPad Pro 11-inch M5 simulators, one test and zero failures
  each. The journey selects messages, marks one read, terminates the process,
  relaunches the packaged app and observes the saved read state. Evidence:
  `artifacts/expo-bootstrap/native-ZUaAQs/`, including both device logs,
  `.xcresult` bundles, `ownership.json` and `result.json`; generation and app
  build log: `scratchpad/623/expo.log`.
- `mise exec -- zsh native/private-inbox/integration/test.zsh ios` passed its
  79-test, six-suite run with no skips. Evidence:
  `artifacts/private-inbox/integration.yjK2rM/test-1.log` and
  `result-1.xcresult`. This is real filesystem, CryptoKit and Keychain evidence,
  including encrypted reopen, wrong/missing-key refusal, preserved corrupt data,
  synthetic credential use/removal and native key isolation. Controlled provider
  fixtures and synthetic account/backend seams do not establish live-provider
  compatibility or physical-device lock behavior.
- The same hosted storage command for `macos`, with `Apple Development` signing,
  team `3P44B7QUTF` and `UNWIRED_STORAGE_PROFILE` selecting an installed profile,
  selected 79 tests across six suites: 76 passed, three skipped and none failed.
  The three IMAP/SMTP TLS-fixture tests run only on iOS. Evidence:
  `artifacts/private-inbox/integration.XaAzVF/test-1.log`, `result-1.xcresult`
  and the generated sandboxed host entitlements. Both platforms explicitly ran
  `accountPurgePreservesIndependentReportingDeletionCredential` and
  `accountPurgeWaitsForDurableReportingWithdrawalAndRetries`, previously gated by
  an unset `UNWIRED_KEYCHAIN_TESTS`. Storage reopen tests create new store
  instances; they do not establish Mac application process relaunch.
- `pnpm --filter @private-email/macos native:build Testing`, with
  `UNWIRED_MOCK_SCENARIO=open-read-relaunch`, `Apple Development` signing,
  team `3P44B7QUTF` and `UNWIRED_MAC_PROFILE`, succeeded. Its packaged bundle,
  renderer/autolinking checks and Hermes framework establish compilation and
  packaging. Evidence: `scratchpad/623/mac-build.log`. This is not a successful
  Mac launch or lifecycle result.
- `pnpm --filter @private-email/macos test:native` stopped before UI execution
  with `Timed out while enabling automation mode.` The host requires administrator
  authentication to enable Automation Mode. Evidence:
  `artifacts/macos-inbox/journey.2Yt1OZ/` records exit code 65, the isolated mock
  identity, XCTest result and an empty lifecycle log. Current Mac packaged launch,
  persistence across Quit/relaunch, menus, shortcuts, independent windows,
  last-window close/reopen and continued work versus explicit Quit remain deferred.

The runners recorded isolated mock identities and device IDs, removed their
disposable apps/devices and build directories, and retained logs/results. Local
formatting and lint passed; native-runner contracts passed 51/51 after the
TestFlight correction, tooling contracts passed 31/31, and both Ruby generators
passed syntax checks. These script contracts are separate from native evidence;
no TestFlight archive or upload was performed for this slice.

The [native validation guide](../agents/native-validation.md#performance-qualification)
nominates this Mac mini M4/16 GB as the Mac reference. The owner still needs to
nominate the iPad reference; neither performance baseline is established. The
remaining [release checks](../agents/native-validation.md#required-release-checks),
including current Mac interaction, physical-device storage/credential lifecycle,
accessibility and distribution qualification, remain required. No legacy coverage
is retired by #623.

## Independent Settings presentation, 2026-10-17

Issue [#911](https://github.com/unwired-dev/product/issues/911) adds the Mac
Settings window and mobile Settings ownership without finishing an open Draft.
Reviewer verification passed both full host Jest suites, localization tests,
lint, formatting, type checks, dependency boundaries, the Fallow new-only gate,
both production exports and bundle/native-dependency checks, and the Mac Release
build. The changed Mac and mobile XCTest probes also passed `build-for-testing`.
Those builds establish compilation, not interaction.

The native journeys now target the separate Mac Settings window and exercise
repeat Command-comma, close/return and an unfinished editor; the mobile editor
journey opens Settings through its palette and returns through iPhone edge-back
or iPad Open Inbox. Execution, Light/Dark captures, focus, VoiceOver, cancellation
and physical-device qualification remain deferred. This host reports Developer
Mode disabled for XCTest automation, and Xcode reports CoreSimulator 1171.7.0
older than its required 1174.9.2 with Simulator device support disabled. The
pre-existing first-launch process and its authentication prompt were left alone.
These checks remain required before release; component tests and probe compilation
do not qualify the native stack transition or real provider behavior.

## Recovery Key evidence, 2026-10-04

[#601](https://github.com/unwired-dev/product/issues/601) adds explicit recovery
with the user-held Recovery Key to both replacement hosts. Review covers the
uncommitted task diff from `35850faf`, including the new native recovery source
and changeset. No native builds or simulator journeys were rerun by the reviewer,
as instructed in the handoff.

Final-tree implementer evidence and retained records, using Node 24, Xcode 27
and fresh iOS 27 simulators after the reviewer corrections:

- `zsh native/private-inbox/integration/test.zsh ios` passed 19 tests in one suite,
  including `recoveryKeyUnlocksANewDeviceWithoutReplacingAccountKeys` and
  `recoveryAndEnrollmentEnvelopesOpenOnlyForTheirAccountAndRecipient` with the
  reviewer corrections. The reviewer inspected their passing entries and the
  suite result in `artifacts/private-inbox/integration.zR0adL/test-1.log`;
  `result-1.xcresult` is retained in that directory. This suite uses real Keychain,
  CryptoKit and filesystem storage with a synthetic Convex boundary.
- The packaged `registration-recovery` Release simulator build passed one XCTest
  journey each on fresh iPhone 18 Pro and iPad Pro 11-inch (M5) 27 simulators, with
  zero failures. Local evidence: `artifacts/expo-bootstrap/native-aToLs5/`.
- The packaged `registration-enrollment` journey with the changed fixture passed
  on both devices under the same conditions, one test each with zero failures.
  Local evidence: `artifacts/expo-bootstrap/native-Lt94WW/`. For both packaged
  journeys, the reviewer inspected passing XCTest logs, runner exit code zero
  and ownership records identifying the scenario and isolated mock bundle.
- The Mac recovery `Testing` build succeeded. Both journey attempts failed before
  UI testing began with "Timed out while enabling automation mode";
  `automationmodetool` reports that this device requires user authentication to
  enable Automation Mode. This is unavailable journey evidence, not a
  passing test or a demonstrated application failure.
- The Mac hosted storage build stopped because `StorageHost` needs a provisioning
  profile. Mac Keychain recovery remains unqualified.

Reviewer corrections require fresh interactive Apple authentication on every
recovery attempt, reject authenticated recovery rings with missing or incorrectly
sized keys, and correct failure copy that promised no changes despite enrollment
refresh or an interruption after verified keys are saved. The native regression
assertions were extended for invalid ring contents, renewed Apple identity
mismatch, cancellation and retry. The 19-test iOS storage run above executes these
assertions against the final native source. Earlier recovery passes preceded the
corrections; their unavailable raw storage results are superseded by this retained
final-tree run.

The shared mock backend also changed `registration-enrollment` seeding and approval
selection. The final-tree packaged enrollment run above covers that revision.
The new Mac wrong-key journey, Mac hosted storage, physical-device behavior
and protected recovery through real
Convex, Google and Apple remain required release qualification. Deterministic
Mock Mail Sessions and controlled native transport are distinct from real provider
evidence. Follow the [protected recovery procedure](../private-product-sync.md#protected-real-qualification)
without recording keys, tokens or mailbox addresses.

Available reviewer checks pass on Node 24.16.0 and pnpm 11.5.2: shared core 30
tests, mobile 16, Mac 14, and Convex 239; all six workspace lint, format and type
tasks; affected-document formatting and 102 local links; changeset validation;
both production JavaScript exports and renderer/autolinking checks; Fallow's exit
gate; Swift formatting and syntax parsing for the corrected files. SwiftLint exits
zero with existing warnings and the task's two additional length warnings in
`ProductSync.swift` and `UnwiredRegistration`; it is not a warning-free result.
The implementer reran `pnpm test:native-runner` outside the reviewer sandbox
against the final tree: 41 passed, zero failed, including the cleanup-helper
contract previously blocked by compiler-cache access. It also reconfirmed shared
core 30, mobile 16, Mac 14 and Convex 239 passing tests, plus lint, format, types
and changeset checks. Runner contracts do not qualify native application behavior;
the iOS storage suite and packaged journeys above supply their separate evidence.

PR #736 rejection-snapshot follow-up, reviewed against `9920fac7`: malformed keys
resolve with the current native status and `recoveryNotice: "rejected"` before
sign-in renewal. A well-formed key that cannot open the envelope returns the
post-renewal status with the same transient notice. The shared store removes the
notice and publishes the returned snapshot with `recoveryFailure: "rejected"`,
including a replacement Enrollment Code when the earlier request expired or was
cancelled. Native promise rejection code `recovery-key-rejected` is removed.

The implementer reran the iOS 27 storage suite after this fix: 19 tests passed.
The reviewer inspected `artifacts/private-inbox/integration.SVTyZz/test-1.log`,
including the recovery test and the suite result; `result-1.xcresult` is retained
there. The recovery assertions now check current-status rejection replies, a new
Enrollment Code after expiry, and no recovery notice on restore. This remains
real Keychain/CryptoKit evidence with a synthetic Convex boundary. Packaged
recovery/enrollment journeys were not rerun for this fix, so their results above
qualify the earlier tree. The iOS recovery journey enters only the correct key;
the Mac wrong-key journey still awaits automation access. The implementer reports
shared core 31, mobile 16, Mac 14 and Convex 239 passing tests, plus lint, format,
types and Swift formatting. No native build or journey was run by the reviewer
for this follow-up.

Independent follow-up reviewer checks passed: shared-core, mobile and Mac test
suites; shared-core lint and types; formatting for the affected documents; 38
local documentation paths and anchors; strict Swift formatting and syntax
parsing for all four changed Swift files; and `git diff --check`. The reviewer
changed only the architecture companion, this record and scratch review notes.

## Final host identity and sandbox readiness, 2026-10-03

[#723](https://github.com/unwired-dev/product/issues/723) changes both replacement
hosts to `dev.unwired.mail`, display name **Unwired Mail**, marketing version
`0.1.0` read from each host's package manifest, exempt-only encryption declarations
and the shared `native/app-icon/UnwiredMail.icon` document. The owner confirmed one
App Store Connect product with iOS and macOS platforms in
[#628](https://github.com/unwired-dev/product/issues/628#issuecomment-5970040414)
and [#669](https://github.com/unwired-dev/product/issues/669#issuecomment-5970040558).
Separate archive and upload work remains in
[#724](https://github.com/unwired-dev/product/issues/724); readiness changes do not
establish TestFlight acceptance or complete replacement qualification.

Review covered `2941e988..2719ba78` and the subsequent reviewer corrections.
Project generation now verifies App Sandbox and outgoing network access for
ad-hoc and profile-backed signing in Debug, Release and Testing. Profile-backed
builds additionally retain Apple sign-in and Keychain entitlements; ad-hoc builds
omit those profile-required capabilities. The hosted Mac storage integration
probe now includes App Sandbox, so its next successful run can qualify storage
and Keychain under that boundary. No incoming-network entitlement is added:
Debug's Metro and inspector connections are network clients.

Retained implementer logs show successful development-signed Mac Testing builds
and one successful XCTest journey each for `open-read-relaunch`,
`registration-apple` and `registration-enrollment`, with cleanup exit code zero.
The reviewer inspected the corresponding ownership, result, lifecycle and signing
input records:

| Scenario                  | Local evidence                          |
| ------------------------- | --------------------------------------- |
| `open-read-relaunch`      | `artifacts/macos-inbox/journey.2cu45x/` |
| `registration-apple`      | `artifacts/macos-inbox/journey.ricYi8/` |
| `registration-enrollment` | `artifacts/macos-inbox/journey.JisCAO/` |

Logs are `artifacts/mac-build-<scenario>.log` and
`artifacts/mac-journey-<scenario>.log`. Each disposable signing input enables
sandboxing and grants file access only to its runner-owned evidence directory.
The retained Mac source application's signature also decodes sandbox and outgoing
network entitlements with `codesign -d --entitlements -`. These retained runs
precede the reviewer fixes; they do not qualify the corrected ad-hoc build or
newly sandboxed hosted storage probe.

Available review checks passed on Node 24.16.0 and pnpm 11.5.2: all twelve host
lint, format, type and test tasks (mobile 15 tests, Mac 13, shared core 29), both
production JavaScript exports and renderer/autolinking boundary checks, Ruby
generator syntax, generated project/entitlement plist checks and affected
documentation formatting. The native-runner suite passed 20 of 21 contracts;
the real Mac cleanup-helper contract could not create its disposable fixture in
the host Application Support directory under the session's filesystem policy.
It is unavailable, not a passing suite. Changesets status remains blocked by the
unchanged non-workspace `unwired-mail` changesets tracked in
[#701](https://github.com/unwired-dev/product/issues/701).

Fresh reviewer native checks used Xcode 27.0 (27A266a) and writable temporary
compiler caches. The sandboxed hosted storage attempt stopped before test
execution because the session could not access the Mac Development signing
private key; Xcode also reported blocked distributed notifications. Evidence is
`artifacts/private-inbox/integration.KVaZCz/`. An ad-hoc Mac Release build stopped
before compilation when Xcode rejected the existing workspace, alongside denied
CoreSimulator service access; its log is
`/private/tmp/testflight-review-adhoc-build.log`. No permitted sandbox escape is
available. Fresh ad-hoc native builds, sandboxed hosted storage/Keychain tests,
and affected Mac journeys remain deferred. The implementer's earlier iPhone
Release build and Inbox journey predate the rebase; fresh iPhone/iPad native
checks remain required. Live sign-in, protected provider integration,
physical-device checks, distribution signing and archive/upload qualification
remain separate release gates.

## Signed Mac Mock Mail Session journeys, 2026-10-03

The implementer ran the packaged, development-signed Mac `Testing` builds on
macOS 27.0.1 with Xcode 27.0, Node 24.16.0 and pnpm 11.5.2, after installing a
development profile covering the runner's disposable `dev.unwired.mock.*` IDs.
The reviewer inspected each ownership record, runner result and XCTest log.
Each run executed one test with zero failures and returned exit code zero,
including cleanup:

| Scenario                   | Local evidence                          |
| -------------------------- | --------------------------------------- |
| `registration-apple`       | `artifacts/macos-inbox/journey.c5oVKk/` |
| `registration-link`        | `artifacts/macos-inbox/journey.56IyIe/` |
| `registration-interrupted` | `artifacts/macos-inbox/journey.CopRYz/` |
| `open-read-relaunch`       | `artifacts/macos-inbox/journey.g07ptY/` |

Build each selected scenario with
`UNWIRED_MOCK_SCENARIO=<scenario> pnpm --filter @private-email/macos native:build Testing`,
using the development signing setup in the [Mac guide](../macos-client.md#build-and-run).
Run `pnpm --filter @private-email/macos test:native <Testing-app-path>` with
`UNWIRED_SIGNING_IDENTITY="Apple Development"` and `UNWIRED_MOCK_PROFILE` exported.
The corresponding implementer logs are `/tmp/unwired-fix-journey-<scenario>.log`;
the result bundles and ownership records above are git-ignored local evidence.

The registration journeys exercise the actual AppKit accessibility tree and native
Keychain-backed setup across process relaunch. Apple and interrupted Google setup
retain and confirm the presented Recovery Key; linked sign-in retains both sign-in
methods. The Inbox journey verifies independent windows, read-state relaunch and
application lifetime. Registration text now uses accessible parent views because
plain nonselectable `Text` in React Native macOS 0.81.9 is absent from the native
accessibility tree. The selectable Recovery Key exposes its native text-view value.

These four runs predate the merge of trusted-device enrollment in
[#718](https://github.com/unwired-dev/product/pull/718). They supersede the
missing-profile deferral below only for these four Mac journeys. The enrollment
and earlier registration sections retain the conditions at the time of their runs.
This evidence does not qualify live Apple/Google/Convex integration, the complete encrypted-storage
contract, VoiceOver interaction, physical devices or distribution signing.
Mac `registration-cancelled`, `registration-declined` and `registration-no-gmail`
journeys remain unrun. Before the merge, the reviewer reran Mac lint, format,
types and component tests, with all 12 tests passing. SwiftLint, swift-format and
direct Swift typechecking of the journey also passed, using a writable temporary
module cache.
A reviewer native rerun stopped before test
execution when the sandbox denied Swift's module-cache write; it supplies no
additional native evidence.

After the merge, the enrollment UI uses the same accessible labels. Native journey
queries match selectable keys by their grouped text-view values: the Recovery Key
has 13 groups of four characters and the Enrollment Code has 14, including its
check digit. The implementer reports Mac lint, types and all 13 component tests
passing. The implementer reran packaged, development-signed Mac `Testing` builds
on the merged tree on macOS 27 with a profile covering `dev.unwired.mock.*`:

- `registration-enrollment` executed one test with zero failures. The log is
  `/tmp/unwired-fix-journey-registration-enrollment.log`.
- `registration-apple` initially failed while waiting for "Gmail connected" after
  relaunch, then passed an immediate rerun with no code change, executing one test
  with zero failures. The first failure remains unexplained; the implementer
  suspects desktop interference. The passing rerun log is
  `/tmp/unwired-fix-journey-registration-apple.log`.

The implementer also reports that the Mac hosted Private Inbox integration suite
passed on #718's tree after Xcode created a managed profile for
`dev.unwired.storage-probe.StorageHost`. The `registration-link`,
`registration-interrupted` and `open-read-relaunch` journeys were not rerun after
the merge; their evidence above remains from the pre-merge tree.

## Trusted-device enrollment evidence, 2026-10-03

[#600](https://github.com/unwired-dev/product/issues/600) adds
[trusted-device approval](../private-product-sync.md#approving-a-new-device).

Implementation evidence before review:

- Eighteen app-hosted tests passed on a fresh owned iOS 27 Simulator with real
  Keychain and CryptoKit. The new journey uses two separate Keychain installations,
  real HPKE and encrypted mailbox records with a controlled backend. It covers
  rejection and renewal, adoption of the existing ring without a Recovery Key,
  descriptors before Gmail consent and unchanged account material.
- The `registration-enrollment` Release simulator build compiled the real bridge,
  and the packaged journey passed on fresh iPhone 18 Pro and iPad Pro 11-inch
  iOS 27 Simulators. A synthetic trusted device reads the code from the run's
  Keychain in place of a person entering it on a second installation. This is
  deterministic mock evidence, not approval between two real devices.
- Workspace lint, format, types and tests, tooling and native-runner contracts
  passed. Evidence remains local under `artifacts/private-inbox/integration.IdWb9M`
  and `artifacts/expo-bootstrap/native-1Xn2g0`.

Review changed the Enrollment Code from 75 bits to 275 bits of entropy to meet
HPKE's PSK requirement, made expiry checks uncached server operations and added
collection-time approver/epoch fencing. Regression tests first reproduced four
invalid-collection cases and cross-account leakage in the shared mock transport,
then passed after fixes. Native checksum tests now alter the check digit so their
negative cases cannot randomly retain a valid checksum.

The review's native interaction rerun could not create a Simulator because the
session denied CoreSimulator service and log access. Earlier native results do
not qualify the corrected code length or bridge endpoint type; those interaction
checks remain required. Review verification:

- All 24 root workspace lint, format, type and test tasks passed. Convex has
  236 passing tests, mail-core 29, mobile 14 and Mac 12. Existing contracts and
  legacy harness coverage also passed and remains intact.
- Both normal production JavaScript builds and renderer/bundle boundary checks
  passed, as did Fallow's changed-code gate, all nine tooling tests, Swift
  formatting and affected documentation links.
- The two crypto-only SwiftPM tests passed with real CryptoKit on macOS. The
  Swift library and synthetic native backend type-checked against the iOS 27
  Simulator SDK. This establishes
  the corrected code format and cryptographic bindings, not Keychain behavior.
- Native-runner contracts passed 19 of 20 tests. The remaining cleanup-helper
  test could not create its disposable directory under the host Application
  Support folder in this session, so the full command did not pass.
- Selected native project generation and CocoaPods installation passed using a
  task-local `CP_CACHE_DIR`. The packaged build stopped before compilation when
  Xcode could not recognize the workspace in this restricted session, alongside
  CoreSimulator and file-event service failures. No corrected packaged build or
  native interaction pass is claimed.
- Additional strict SwiftLint on the four affected core/bridge/test files still
  reports five violations also present in the starting commit: the older seal's
  parameter count, bridge file/store size and two older Data-to-String conversions.
  This is separate from the passing maintained workspace lint lane.

Review logs and the unavailable packaged-build result are retained locally in
`artifacts/private-inbox/enrollment-review.EONAFv`. Task-owned probes, compiler and
CocoaPods caches were removed after verification.

Real Convex/JWT and protected Gmail two-device qualification, signed Mac
Keychain/E2E without matching disposable-app profiles, and physical-device checks
remain deferred before release. No legacy coverage is retired by this slice.

## Private Sync evidence, 2026-10-01

[#599](https://github.com/unwired-dev/product/issues/599) adds
[Private Sync initialization and the Recovery Key](../private-product-sync.md)
on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed, including
  221 Convex tests. Fallow audit passed on the changed files. Convex covers single
  initialization, idempotent retry, refusal for already initialized accounts, and
  epoch and device-proof enforcement. Shared and rendered host tests cover Recovery
  Key confirmation, mismatch, remount and the enrollment-needed state.
- Seventeen app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain and CryptoKit. They cover nonce freshness and tamper, account,
  identifier, schema and epoch rejection. They also cover recovery and enrollment
  envelope binding, one-time initialization, the encrypted descriptor round trip
  and relaunch without new keys. Interrupted publication and the losing device's
  enrollment state are covered too, as are a receipt without Private Sync state and
  an Apple relaunch. That relaunch shows the last decrypted mailbox list and saves a
  new mailbox only after signing in again. Convex and the providers are controlled
  boundaries here.
- The `registration-declined` and `registration-link` packaged journeys passed on
  fresh iPhone 18 Pro and iPad Pro 11-inch M5 iOS 27 Simulators from Release
  simulator builds. The Google journey keeps the same Recovery Key across relaunch
  and confirms it. After another relaunch it reads back the decrypted mailbox list.
- Paginated native record reads compile in CI's packaged build; no local journey
  exercises more than 100 records.
- The Mac `Testing` build with `registration-declined` compiled and passed its
  bundle check with ad-hoc signing. The cleanup helper type-checks. Native runner
  contracts (20 tests) passed.

Native Mac E2E, real Convex Private Sync and providers, and the deployment's JWT
gateway remain deferred. So do signed Mac Keychain behavior and physical devices.
The [protected qualification path](../private-product-sync.md#protected-real-qualification)
has not run. No installed Mac profile covers the disposable `dev.unwired.mock.*`
IDs. Uncommitted local evidence stays on the development host in the git-ignored
`artifacts/expo-bootstrap/native-VdNwBS`, `artifacts/expo-bootstrap/native-5QUCAH` and
`artifacts/private-inbox/integration.nBHQeR` directories.

## Linked sign-in evidence, 2026-10-01

[#598](https://github.com/unwired-dev/product/issues/598) adds
[explicit Google and Apple linking](../linked-sign-in.md) on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed, as did
  Fallow audit on the changed files. Convex integration covers alternate sign-in
  from a second installation and same-email non-linking. It also covers owned
  identities, superseded tickets and stale tokens on either side. Expired,
  wrong-provider and wrong-device tickets are rejected, a lost completion can be
  retried and deletion tombstones both identities. Shared and rendered host tests
  cover linking from account settings, remount and link failures.
- Eleven app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain. Two new scenarios cover interactive reverification, no hint for the
  linked identity, cancellation and alternate sign-in on another installation.
  They also cover recovery after Apple revocation, owned identities, stale
  sessions and unlinked switches. Apple, Google and the backend are controlled
  boundaries here.
- The `registration-link` packaged journey passed on fresh iPhone 18 Pro and
  iPad Pro 11-inch M5 iOS 27 Simulators. It uses a Release simulator build and
  relaunches with both sign-in methods.
- The Mac `Testing` build with `registration-link` compiled and passed its bundle
  check with ad-hoc signing. Normal mobile and Mac bundle checks and native runner
  contracts (20 tests) passed.

Real Apple and Google linking, the deployment's JWT gateway, signed Mac
Keychain/UI and physical devices remain deferred. The
[protected qualification path](../linked-sign-in.md#protected-real-qualification)
has not run either. No installed Mac profile covers the disposable
`dev.unwired.mock.*` IDs. Local evidence is in
`artifacts/expo-bootstrap/native-Ak0yAc` and
`artifacts/private-inbox/integration.dmkGTV`.

## Apple registration evidence, 2026-09-30

[#597](https://github.com/unwired-dev/product/issues/597) adds
[Sign in with Apple continuing into Gmail authorization](../apple-registration.md)
on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed. Shared
  application tests run every Gmail consent failure after Apple sign-in and
  cover Apple cancellation. Rendered host tests cover the Apple-specific copy,
  the relay contact address and a Gmail-derived connected address. Convex
  integration keeps same-relay-address Apple and Google identities in separate
  Product Accounts without storing the address.
- Nine app-hosted native tests passed on an owned iOS 27 Simulator with real
  Keychain. New scenarios cover Apple cancellation and Gmail decline/connection.
  They confirm no Google hint or identity is derived from the Apple account. They
  also cover cross-provider rejection, contact-address retention, revoked-credential
  recovery, interrupted registration and Apple-issuer claim checks. Apple, Google
  and Convex are controlled boundaries here, not live evidence.
- The `registration-apple` packaged journey passed on fresh iPhone 18 Pro and
  iPad Pro 11-inch M5 iOS 27 Simulators. It uses a Release simulator build carrying
  the Sign in with Apple entitlement, with pending setup and connected relaunch.
  The Google `registration-declined` journey passed again on both devices.
- The Mac `Testing` build with `registration-apple` compiled, bundled and
  passed its bundle check with ad-hoc signing. Native runner contracts (20 tests),
  Effect import-policy checks and Fallow on changed files passed.

Real Sign in with Apple, signed Mac Keychain/UI and physical devices remain
deferred, as does the [protected qualification path](../apple-registration.md#protected-real-qualification).
No installed Mac profile covers the disposable `dev.unwired.mock.*` IDs, and none
of the installed profiles was checked for the Sign in with Apple capability.
Local evidence is in `artifacts/expo-bootstrap/native-hT8jlu` (Apple),
`artifacts/expo-bootstrap/native-iCWlM6` (Google) and
`artifacts/private-inbox/integration.s7Okrv`.

## Google registration evidence, 2026-09-30

[#596](https://github.com/unwired-dev/product/issues/596) adds
[Google Product Sign-In and separate Gmail authorization](../google-registration.md)
with the approved GoogleSignIn 10.0.0 native SDK on both hosts.

- All 20 affected workspace lint, format, type and test tasks passed. Existing
  backend and Inbox coverage remains. New application and rendered-host tests
  cover pending setup, retry and mailbox reselection; Convex integration proves
  same-address Google and Apple identities stay separate without creating a
  mailbox connection or Private Sync key material.
- Seven app-hosted native tests passed on an owned iOS 27 Simulator against real
  Keychain, CryptoKit and filesystem operations. Added scenarios cover callback
  nonce/audience/subject/issuer/expiry rejection, missing Gmail grants, unavailable
  Gmail, interrupted registration, offline account retention, independent mailbox
  selection and preservation of existing Inbox ciphertext. Google authorization
  and Convex are controlled boundaries in these tests, not live OAuth evidence.
- Normal and selected registration JavaScript exports passed both host bundle
  checks. Root and host Fallow scans reported zero unused-code findings. Native
  runner contracts, Effect import-policy checks, Swift formatting and strict
  SwiftLint passed.
- Normal and selected Expo simulator Release and Mac packaged Testing builds
  passed with GoogleSignIn.
  Selected registration builds include a fixed native mock provider; normal builds
  exclude it. Release Mac configuration cannot inherit the Testing scenario marker.
- The native registration journey passed on fresh iPhone 18 Pro and iPad Pro
  11-inch M5 iOS 27 Simulators. It retains pending setup across process relaunch,
  authorizes a different synthetic mailbox and restores the connected status.

The native provider and backend substitutes above are distinct from the protected
[real OAuth qualification path](../google-registration.md#protected-real-oauth-qualification).
That path, signed Mac Keychain/UI checks, physical-device behavior and distribution
qualification remain deferred before release. No installed Mac provisioning
profile matches the disposable test app identifiers; no developer-portal resources
were created.

Local evidence is retained in `artifacts/mock-mail-registration`,
`artifacts/expo-bootstrap/native-0GNjv1` and
`artifacts/private-inbox/integration.0aqXIK`. A final mobile rerun failed during
Simulator installation before tests began; the retry on fresh owned devices
passed on both iPhone and iPad. Mac project regeneration required CocoaPods reintegration;
an initial pnpm-launched pod installation failed with a null-path error, and a
standalone installation succeeded. Failed attempts remain diagnostic evidence.
Hosted CI completion is separate from these local checks.

## Isolated Mock Mail Session evidence, 2026-09-30

[#595](https://github.com/unwired-dev/product/issues/595) adds
[external deterministic session runners](../mock-mail-sessions.md). On the local
Xcode 27.0/macOS 27.0.1 host:

- Mobile Release compilation passed. The same synthetic open, mark-read and
  relaunch journey passed on fresh iPhone 18 Pro and iPad Pro 11-inch M5 iOS 27
  simulators. Both used the real application runtime, presentation and native
  encrypted store. Exit evidence was zero, and the run-owned app copy,
  DerivedData and simulators were removed.
- Four separate app-hosted native storage tests passed against real CryptoKit,
  filesystem and Keychain, covering relaunch, unavailable keys, corrupt
  ciphertext, protected-data recovery, credential removal and competing writes.
- Mac packaged `Testing` compilation passed. Native E2E preflight failed closed
  because no configured profile covers disposable `dev.unwired.mock.*` IDs.
  This journey and its signed external Keychain cleanup remain deferred before
  release. An ad-hoc build does not establish Data Protection Keychain evidence.
- Shared synthetic-provider/application tests, both host component suites,
  retained backend tests, lint, format and types passed. Both external runner
  contracts passed with tool stubs. Those contracts prove orchestration and
  cleanup behavior, not Mac native execution.
- Normal and selected production JavaScript exports passed the host bundle
  checks. Normal exports exclude mock providers. Root and host Fallow checks
  report zero unused-code/dependency issues; health diagnostics remain
  advisory.

Local results are retained under `artifacts/mock-mail-595`,
`artifacts/expo-bootstrap/native-TAgsiX`, and
`artifacts/private-inbox/integration.wElIBS`. The first mobile run exposed an
invalid test query after navigation; after moving that assertion before
navigation, both native journeys passed. That failed run remains available as
diagnostic evidence. No real Gmail, sign-in, assistance engine, delivery or
physical-device qualification is claimed. Hosted CI results are separate from
this local evidence.

## Native Mac mock Inbox evidence — 2026-09-29

The [Mac host](../macos-client.md) adds AppKit windows around the shared synthetic
Inbox. The amended root-workspace boundary now includes a `macos` catalog with
React Native macOS 0.81.9, React Native 0.81.6 and React 19.1.4.

- Frozen strict-peer installation succeeds with both host graphs installed.
- All 20 workspace lint, format, type and test tasks pass for Mac, mobile,
  shared core/contracts and Convex. Two Mac component integration scenarios
  exercise independent selection, view closure and remounting against the real
  mock mailbox service. Three Effect import-policy checks pass.
- Both production bundle inventories pass. Mac autolinking finds no extra native
  modules and resolves the pinned Mac fork. Mobile autolinking resolves React
  Native 0.86.3 and its seven native modules, with no Mac dependency.
- Native `Testing` and `Release` arm64 builds succeed on macOS 27.0 (26A428) with
  Xcode 27.0 (27A266a), local ad-hoc signing and hardened runtime disabled for
  local dynamic-framework loading. Distribution signing is unqualified.
- The approved, pinned `fast-text-encoding@1.0.6` supplies the UTF-8 APIs missing
  from Mac Hermes before Effect loads. Packaged native launch renders the shared
  Inbox without Metro.
- The native XCTest journey passes on the packaged Testing app and exercises
  independent selection, menu focus, Command-N and
  Command-W, closing all windows, continued synthetic work, Launch Services
  reopen, reading another message and menu Quit in one process/session.
  Direct native UI automation also verifies Command-Q; XCTest keyboard injection
  after reopening did not reliably deliver that shortcut.
- The Release executable contains none of the Testing probe environment key,
  work-counter or session-property symbols.

The local XCTest runner uses an optimized, packaged Testing app, with a synthetic
application-scoped timer and content-free lifecycle records. Those records are
compiled out of Release. Bundle output and successful compilation do not prove
window lifetime, synchronization, delivery or real provider integration. No
legacy coverage is removed.

## Mobile bootstrap evidence — 2026-09-28

- Strict peer dependency installation passes with one root workspace and lockfile,
  shared catalog and named `mobile` catalog. Shared source uses `workspace:*`.
- Root workspace lint, formatting, TypeScript and tests pass after dependency
  updates. Mobile lint, formatting, TypeScript and three component tests pass;
  the shared Effect service has three passing contract tests.
- A deliberately discarded Effect value fails Oxlint with
  `effecttsgo/floating-effect`, confirming the patched compiler integration.
- Effect is available at the root for its installed agent guide and source.
  Both Oxlint configurations reject non-namespace Effect imports; the regression
  fixtures cover named, default, barrel, side-effect and type imports.
- The production Hermes export includes the mobile renderer, native Router split
  view, Effect and the current shared source. The verifier rejects stale shared
  source, other renderer versions, the Mac graph and backend imports.
- An arm64 Release simulator build succeeds with Xcode 27. Packaged launch
  without Metro succeeds on task-owned iPhone 18 Pro and iPad Pro 11-inch M5
  simulators running iOS 27.0 (24A434).
- One native XCTest journey passes on each device: open Maya's message, return
  through the native back button on iPhone, select Oliver, and confirm that the
  previous sender is no longer displayed. iPad shows the columns side by side.
  `pnpm test:native` retains this journey with owned-device cleanup and rejects
  zero-test success. It consumes an already-built simulator app.
  The Release build and both journeys were repeated after workspace consolidation.
- The first native launch exposed the iOS 27 scene-lifecycle requirement. The
  Expo build-properties plugin now generates scene support. The first iPad
  screenshot exposed an overlapping sidebar; explicit tiled split behavior
  and the detail pane's left safe-area inset correct it. The native journey
  checks that message text starts beyond the sidebar.

Hardware-keyboard activation, VoiceOver, resizable iPad windows, physical-device
behavior, persistence, credentials, native Mac, signing and App Store archives
are not established by this bootstrap. Keep those checks in the release gate.
The mock Inbox is in-memory; opening mail does not mark it read.

## Native E2E automation

The [Mobile workflow](../../.github/workflows/mobile.yml) now defines an
`Expo native build` job for ready pull requests and pushes to `main`. It builds
the packaged Release app once on the `xcode-27` arm64 image and uploads a tar
archive for the parallel `Expo native E2E (iPhone)` and `Expo native E2E (iPad)`
jobs. Independent `Expo native storage checks` retain the native runner contracts,
real storage integration and cleared-scenario project generation. Each job
uploads its own logs and XCTest results where produced. The runner rejects zero-test
success and avoids retrying assertion failures even when infrastructure messages
are also present. The app artifact retains its run ID across attempts so failed
journeys can reuse a successful build within its seven-day retention period.
The first hosted [run 37123765376](https://github.com/unwired-dev/product/actions/runs/37123765376)
took 18m10s. The build (8m40s), iPhone journey (9m07s), and iPad journey (7m16s)
passed. The storage step reached its former eight-minute limit during cleanup,
after all 17 tests reported success. Its total limit was then raised to 14 minutes, including
the single infrastructure retry and cleanup, within the 20-minute storage job.
The first run did not establish a passing workflow under that adjustment.

[PR #881](https://github.com/unwired-dev/product/pull/881) raises the storage step
limit to 26 minutes and its job limit to 34 minutes after
[run 38176311382](https://github.com/unwired-dev/product/actions/runs/38176311382) and
[run 38179436190](https://github.com/unwired-dev/product/actions/runs/38179436190)
exceeded the 14-minute step limit. Hosted validation of the new limits remains pending.

## Earlier dependency probe — 2026-09-09

The sections below preserve the original probe, package pins and machine state.
At that time no Mac with macOS 27 and Xcode 27 was available, and the maintainer
authorized implementation with native checks deferred. Those probe results are
historical and are not evidence for the current native app.

The deferred native work is tracked in
[GitHub issue #623](https://github.com/unwired-dev/product/issues/623). It is a
release prerequisite and does not block the approved feature-implementation tickets.

## Historical selected arrangement

The original probe used [independent native host installations](../adr/0064-isolate-mobile-and-macos-native-dependencies.md):

| Host        | Expo    | React Native | React Native macOS | React  |
| ----------- | ------- | ------------ | ------------------ | ------ |
| iPhone/iPad | 57.0.21 | 0.86.3       | None               | 19.2.3 |
| Mac         | None    | 0.81.6       | 0.81.9             | 19.1.4 |

The Expo pins came from the exact package's `bundledNativeModules.json`, rather
than the moving documentation alias. React Native macOS's exact package metadata
requires React Native 0.81.6 and React `^19.1.4`. Sources:
[Expo 57.0.21 metadata](https://registry.npmjs.org/expo/57.0.21),
[React Native macOS 0.81.9 metadata](https://registry.npmjs.org/react-native-macos/0.81.9),
[macOS setup guidance](https://microsoft.github.io/react-native-macos/docs/getting-started),
and [Expo's duplicate-native-package constraints](https://docs.expo.dev/guides/monorepos/#duplicate-native-packages-within-monorepos).

Two structural candidates were reviewed: one shared older renderer line, and
separate supported host installations. The parent and independent cross-judge
selected the latter. The cross-judge scored them 8/10 and 9/10 across host fit,
dependency evidence, isolation, implementation cost, and falsifiable verification.
Retain the other candidate's explicit renderer inventory and observable Mac
close-versus-Quit checks. Do not adopt its Expo version override or speculative
storage API. That decision originally required independent lockfiles and Metro
resolution. The 2026-09-28 amendment replaces the lockfile boundary with named
catalogs and verified per-host resolution.

## Executed checks

The disposable probe used sibling `mobile`, `macos`, and `shared` directories.
Both hosts declared `packageManager: pnpm@11.5.2` and their own
`pnpm-workspace.yaml` containing `packages: []`. Each consumed the same local
`@private-email/platform-probe-core` package through `file:../shared`. All probe
packages were development-only; no production dependencies or existing workspace
lockfiles were changed.

The shared package had no dependencies. Its fixed synthetic fixture contained
two messages, one unread, and a pure unread-count function. Both entry points
rendered the fixture identifier and count using their own React Native `Text`.
This is a shared-source bundling probe, not a mail journey or provider test.

The mobile entry used Expo's `registerRootComponent`. The Mac entry used
`AppRegistry.registerComponent`; its resolver mapped `react-native` and
`react-native/*` imports to `react-native-macos`. The Mac probe pinned
`@react-native/babel-preset` and `@react-native/metro-config` to 0.81.6 and Metro
to 0.83.8, with the `macos` platform selected explicitly.

| Check                                                                                                     | Result                                                 |
| --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Install each host with `pnpm install --ignore-scripts --strict-peer-dependencies`                         | Both passed; install scripts deliberately did not run. |
| Mobile `expo install --check`                                                                             | Passed: dependencies are up to date.                   |
| Mobile iOS JavaScript export                                                                              | Passed.                                                |
| Mac Metro JavaScript bundle                                                                               | Passed.                                                |
| Both source maps contain the exact current shared TypeScript source                                       | Passed; identical shared-source SHA-256.               |
| Each source map uses its intended React package and contains no source from the other host's native graph | Passed for the probe entry points.                     |
| Native app build, launch, Hermes execution, or UI automation                                              | Not run; deferred.                                     |

Commands were run through the repository's mise-managed Node 24.16.0 and
pnpm 11.5.2. From each disposable host directory:

```sh
mise exec -- pnpm install --ignore-scripts --strict-peer-dependencies
```

From the mobile directory:

```sh
CI=1 EXPO_NO_TELEMETRY=1 mise exec -- pnpm exec expo install --check
CI=1 EXPO_NO_TELEMETRY=1 mise exec -- pnpm exec expo export \
  --platform ios --output-dir dist --no-bytecode --no-minify \
  --source-maps --max-workers 2
```

The Mac runner used Metro's `loadConfig` and `runBuild` with:

```js
{
  entry: './index.ts',
  platform: 'macos',
  dev: false,
  minify: false,
  out: './dist/macos.jsbundle',
  sourceMap: true,
  sourceMapUrl: 'macos.jsbundle.map',
}
```

The initial Mac invocation reached bundle output but failed because `dist` did
not exist. Creating that output directory and rerunning passed. This was a probe
runner correction, not a package compatibility failure.

The exports were production-mode JavaScript without minification or Hermes
bytecode, inspected through their source maps. They were not native Release
archives. These hashes identify this disposable run; transitive dependency and
bundler changes can produce different output:

| Artifact          |     Bytes | SHA-256                                                            |
| ----------------- | --------: | ------------------------------------------------------------------ |
| Shared `index.ts` |         — | `5e28ae26dfc7ccd8b592f76908b5a68cadf464caa19eb803f357c12b31b80aea` |
| Mobile JavaScript | 2,100,704 | `10224f77372e9009e25a10642a2a1b9326ea5845a6eea4c4168a8deee0f65144` |
| Mac JavaScript    | 2,347,888 | `46403a725c2202fac0fc5715fb539f419fd50948333741252fe5d1863d7abe1e` |

The mobile map contained 587 sources and React 19.2.3. The Mac map contained 499
sources and React 19.1.4. Neither map included the other host's framework graph.
Future app entry points and native modules must preserve this isolation; a
successful minimal bundle does not establish that every future dependency will.

## Deferred native evidence

The inspected machine runs macOS 26.6.2, Xcode 26.6 (17F113), and SDKs through
26.5. Installed iOS simulators reach 26.5; there is no version-27 runtime.
CocoaPods was not installed. No simulator, native project, native module, app
archive, or database reset was created by this probe.

Continue implementation under the maintainer's explicit deferral. Before release,
record results for the actual replacement hosts and exact root dependency lockfile:

1. Build and launch iPhone/iPad and native Mac apps with deployment targets at 27,
   packaged JavaScript, and the selected native modules. Exercise Hermes and native
   autolinking; do not substitute an active Metro server for packaged launch.
2. Run the same deterministic visible mail journey on iPhone and iPad at compact
   and regular widths, including keyboard interaction and persistence after
   process termination and relaunch.
3. On Mac, verify menus, keyboard shortcuts, independently routed windows,
   reopening a window after all windows close, continued application-scoped work
   with no windows, and cessation of that work on explicit Quit.
4. Prove device-local Keychain accessibility, credential removal across relaunch,
   encrypted database contents, and inability to open private data without its
   native-held key. Synthetic in-memory storage cannot supply this evidence.
5. Run desktop UI automation against the actual AppKit accessibility tree. Treat
   zero selected tests as missing evidence. Use task-owned simulators and build
   directories for mobile checks under the repository's ownership policy.
6. Produce separate mobile and Mac App Store archives and TestFlight artifacts;
   verify signing, entitlements, sandbox behavior, and physical-device AI
   availability separately from JavaScript bundling.

No legacy tests have been retired by this dependency probe. Retire tests with
the implementation they protect, preserving or replacing the named risks in
[the testing policy](../agents/testing.md) and
[the mock-mode decision](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md).

## Private Inbox persistence, 2026-09-29

[#594](https://github.com/unwired-dev/product/issues/594) implements
[native encrypted fixture storage](../private-inbox-storage.md) for Expo and Mac.
Verification used Xcode 27.0, Swift 6.4, the iOS 27.0 Simulator runtime, Node
24.16.0 and pnpm 11.5.2.

Passed:

- Lint, formatting, types and tests for mobile, Mac, mail-core, contracts and
  Convex through `pnpm turbo run lint format check-types test` with those package
  filters. Focused tests were rerun after the final test-only edits.
- Both production bundles and renderer/native-boundary checks, Expo dependency
  compatibility, root and host Fallow scans, Effect import-policy tests and the
  existing native runner failure-handling suite. Fallow reported no unused-code
  findings; advisory health findings remain separate from its exit status.
- Swift formatting and strict SwiftLint for the new native store, bridge and
  integration tests; Ruby and zsh syntax checks; affected local documentation links.
- Ad-hoc signed Expo simulator Release build and the native iPhone 18 Pro and
  iPad Pro 11-inch M5 journeys. Both explicitly mark a fixture read, terminate
  the app, relaunch its packaged binary, and observe the restored read state.
  Local evidence: `artifacts/expo-bootstrap/native-pEBIF3/`.
- Three app-hosted Swift Testing integration scenarios on an owned iOS 27
  Simulator, using real Keychain, CryptoKit and filesystem operations. These
  prove encrypted persistence, no fixture plaintext in the encrypted file,
  rejection without the correct key, preservation of missing-key/corrupt data,
  synthetic credential use and deletion, database-key isolation, and competing
  native updates. Local evidence: `artifacts/private-inbox/integration.8tcd1d/`.
- Mac `Testing` build, including the shared native store and bridge, with ad-hoc
  signing and packaged JavaScript. This proves compilation and packaging only.

Deferred:

- Signed Mac Keychain integration and native read-state relaunch checks. The
  local Unwired development certificate is available, but matching Mac App
  Development provisioning profiles are absent for
  `dev.unwired.mail.macos.preview` and `dev.unwired.storage-probe.StorageHost`.
  Xcode rejected both signed builds before tests could run. Ad-hoc signing and
  a plain SwiftPM test executable do not qualify Data Protection Keychain access.
  The Mac checks remain required before release; the signing setup is documented
  in the storage guide. No developer-portal resources were created.
- Physical-device lock/unlock, backup/restore and distribution-signing behavior.
  Simulator tests do not prove these policies on a shipped app.

Mock Mail Session tests prove application behavior through a substituted native
boundary. They are distinct from the real storage tests and the packaged-app
journeys above. This slice retires no legacy coverage.

## Interface language foundation — 2026-10-08

Issue [#677](https://github.com/unwired-dev/product/issues/677) adds shared English
catalogs with i18next/react-i18next, device-language selection, and a saved local
override across the current registration, Inbox and reader surfaces. English is
the only production language; French resources exist only in tests.

This replaces the localization evidence cherry-picked from PR #678's September
branch. That branch's test counts and Mac journey do not qualify the current
runner or implementation.

Round-one evidence at `cd8c5698`, before merging the local Draft composer, on
macOS 27.0.1 with Xcode 27.0 and the mise Node 24 and pnpm toolchain:

- The independent review reran all eight scoped type and test tasks after its
  runtime fixes: mobile 51, Mac 46, mail-core 332 and shared localization 5 tests
  passed. Repository formatting and lint (excluding untracked task probes), all
  10 tooling checks, Expo dependency compatibility, frozen strict-peer installation
  and both production bundle/boundary checks passed. Fallow exited successfully
  with no findings outside the untracked task probes; health advisories remain
  separate from that check.
- The Foundation integration test passed native regional matching, missing-key
  English fallback, separate-process preference persistence/removal, and locale
  conversion. It uses an isolated preferences domain and temporary test catalogs.
- The packaged ad-hoc signed iOS Release app passed
  `testSelectAndReplaceMessage`, including language selection/relaunch, on owned
  iPhone and iPad simulators running iOS 27.0. Evidence:
  `artifacts/expo-bootstrap/native-P4Ddoo/` records the implementation run;
  `artifacts/expo-bootstrap/native-HBUk2A/` records both journeys passing again
  against the rebuilt app after the independent review's runtime fixes.
- Implementation-run Mac Testing and Release builds passed with ad-hoc signing
  and packaged catalogs. The independent review rebuilt production Release after
  its fixes and verified the packaged catalog against disk. An initial CocoaPods
  `pathname contains null byte` failure passed on one retry. This establishes
  compilation and packaging only.

Round-two evidence after merging the local Draft composer, with the reviewed
runtime fixes at `b622d637`, on the same macOS 27.0.1/Xcode 27.0 toolchain:

- All eight scoped type and test tasks passed: mobile 84, Mac 79, mail-core 379
  and shared localization 5 tests. The recipient-group regression uses real
  i18next templates with recipient-first wording and fails against the unfixed
  implementation; existing bounded-recipient and Unicode preview checks passed.
  Repository formatting, lint excluding the pre-existing untracked probes, and
  all 10 tooling checks passed. Fallow exited successfully with only the
  excluded probe's unused-file finding; existing health advisories remain
  separate.
- The native Foundation language integration passed again, including regional
  matching, fallback and preference persistence/removal across processes.
- Production bundle checks passed with 1,306 mobile and 671 Mac sources. The
  ad-hoc signed iOS Simulator and Mac Release builds passed with packaged
  JavaScript and catalogs.
- `testSelectAndReplaceMessage`, including language selection and relaunch,
  passed on fresh owned iPhone and iPad simulators running iOS 27.0, with one
  test and zero failures on each. Evidence:
  `artifacts/expo-bootstrap/native-MhGMZV/`. These are Inbox journeys, not native
  composer qualification; the Draft-specific deferred checks remain in the
  [Draft guide](../drafts.md#verification).

Deferred:

- Both current Mac XCTest journeys, including
  `testLanguagePreferenceAcrossWindowsAndRelaunch`: this host has no development
  signing identity or profile covering `dev.unwired.mock.*`. The current runner
  requires that isolated signed identity for every selected journey.
- Real VoiceOver, right-to-left layouts and physical devices, plus language-specific
  qualification before shipping any additional catalog.

Mocked host/store tests, native Foundation integration, packaged journeys and
build evidence remain distinct. Follow [the localization guide](../localization.md)
for commands and release checks. No legacy coverage is retired by this slice.
