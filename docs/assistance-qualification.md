# On-device assistance qualification

Setup, commands and recording rules for qualifying
[On-Device Mail Assistance](domain/assistance.md) on physical hardware remain in
this file.

[#625](https://github.com/unwired-dev/product/issues/625) runs the actual native
bindings behind [summaries](message-summaries.md), [Draft rewrites and reply
suggestions](draft-assistance.md) and [translation](message-translation.md) on
eligible version-27 hardware. The nominated configurations are the owner's iPhone
17 Pro Max, iPad Pro 13-inch with Apple M4 and the Mac mini with Apple M4 and
16 GB memory ([#1106](https://github.com/unwired-dev/product/issues/1106)).
Results apply only to the configurations tested. Hardware eligibility and OS
version alone do not show that the model, a locale or a Translation language is
ready, so every run records what the device actually reports.

The binding selects `SystemLanguageModel.default`. It does not expose a separate
model-build identifier; the OS build and recorded answers bound this evidence,
and do not identify model updates independently of the OS.

## The qualification build

The `assistance-qualification` [Mock Mail Session](mock-mail-sessions.md) build shows
the synthetic `open-read-relaunch` mailbox, but its native binding runs Apple's
system language model and Translation instead of the fixed synthetic answers every
other mock build compiles. Like other mock builds it refuses remote content and
contacts no provider. Only this build contains the corpus run and its evidence
recorder; `verify:bundle` rejects the run in any other bundle, and TestFlight
uploads refuse mock builds.

Each interactive launch runs version 3 of the synthetic corpus once, through the
same shared stores the reader and composer use and the real native module:

- summaries of English, Czech and German messages, a message that tells the model
  to answer with JSON, and a message beyond the 6,000-character input limit;
- rewrites of English and Czech notes, and of authored text just inside the input
  limit, to show whether the model's context window holds it;
- reply suggestions with authored text, without authored text for a German
  message, and with a quoted message cut at the limit;
- translations between installed or missing language pairs, and the same-language
  and unidentified-language refusals;
- cancellation of a native generation, of a summary preview and of a translation
  preview, each with its late result, and a newer request replacing an older one
  that is already generating.

The corpus contains no real mail. Change `corpusVersion` in
`packages/mail-core/src/testing/assistance-qualification.ts` with any change to
its cases, so runs on different corpora are never compared as one.

The app writes one JSON line per check to `tmp/assistance-qualification.jsonl` in
its container. The first line describes the device: its public hardware
identifier, OS version and build, locale, preferred languages, the build's commit
when stamped, the model's availability and the Translation target languages. Each
check records its result, state, elapsed time and the model's text, with the
expected facts it found. The last line is `complete` with the counts, or `stopped`
with an allow-listed diagnostic when the run could not continue.

| Result    | Meaning                                                                                                                |
| --------- | ---------------------------------------------------------------------------------------------------------------------- |
| `pass`    | The binding behaved as the shared core requires                                                                        |
| `limited` | The device or model lacked the capability (an unavailable reason, a refusal or a missing language); mail is unaffected |
| `fail`    | Anything else, such as a malformed or empty result, a cut input not disclosed or a cancellation not honored            |

Facts are recorded, never scored: live model output is not deterministic, and a
run makes no claim about another run's text. Review the recorded text for material
output limitations, such as invented details or an answer in the wrong language.

## Run on the Mac

Build the `Testing` configuration with the [Mac signing](mock-mail-sessions.md#native-mac-entry-point)
prerequisites, then run the corpus from a disposable copy:

```sh
UNWIRED_MOCK_SCENARIO=assistance-qualification \
mise exec -- pnpm --filter @private-email/macos native:build Testing
UNWIRED_SIGNING_IDENTITY='Apple Development' \
UNWIRED_MOCK_PROFILE='/absolute/path/to/mock-only.provisionprofile' \
mise exec -- pnpm --filter @private-email/macos qualify:assistance \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app"
```

The runner signs the copy for a random `dev.unwired.mock.<run>` identity, opens it,
waits for the `complete` line and keeps the evidence under
`artifacts/assistance-qualification/macos.*`. It then quits the copy and removes
its Keychain items, container and app, as the [native runner](mock-mail-sessions.md#ownership-evidence-and-cleanup)
does. It fails when any check fails, the evidence is incomplete or malformed,
the run stops, or it times out: after 30 minutes by default, or after
`UNWIRED_QUALIFICATION_TIMEOUT` seconds when that is set.

## Run on iPhone and iPad

Physical iPhone and iPad runs are owner-operated, with local Xcode signing, in the
session agreed in [#1106](https://github.com/unwired-dev/product/issues/1106).
Install the build under its own bundle identifier so it never replaces an
installed Unwired Mail or reads its data:

```sh
UNWIRED_MOCK_SCENARIO=assistance-qualification UNWIRED_COMMIT="$(git rev-parse HEAD)" \
mise exec -- pnpm --filter @private-email/mobile native:generate --no-install
(cd apps/mobile/ios && pod install)
xcodebuild build -workspace apps/mobile/ios/UnwiredMail.xcworkspace \
  -scheme UnwiredMail -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath artifacts/assistance-qualification/DerivedData \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$UNWIRED_DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER=dev.unwired.mock.assistance
app=artifacts/assistance-qualification/DerivedData/Build/Products/Release-iphoneos/UnwiredMail.app
xcrun devicectl list devices
xcrun devicectl device install app --device <device> "$app"
xcrun devicectl device process launch --terminate-existing --device <device> dev.unwired.mock.assistance
```

The device needs Developer Mode on (Settings → Privacy & Security). A device the
team has not registered refuses the app because its provisioning profile cannot
be installed. Build once with
`-destination 'platform=iOS,id=<device>' -allowProvisioningDeviceRegistration` in
place of the generic destination to register it, then install again.

Keep the app in the foreground until the run completes, then copy the evidence
and check it, as the Mac runner does:

```sh
xcrun devicectl device copy from --device <device> \
  --domain-type appDataContainer --domain-identifier dev.unwired.mock.assistance \
  --source tmp/assistance-qualification.jsonl \
  --destination artifacts/assistance-qualification/<hardware>.jsonl
python3 scripts/verify-assistance-evidence.py artifacts/assistance-qualification/<hardware>.jsonl
```

Repeat the copy until its last line is `complete`. Only a fresh launch runs the
corpus; an app resumed from the background does not, so relaunch with
`--terminate-existing`. Each run starts a new evidence file, so copy it to a new
destination before every relaunch. Keep the
app installed for the checks below, then remove it with its data:

```sh
xcrun devicectl device uninstall app --device <device> dev.unwired.mock.assistance
```

## Checks the corpus does not automate

On each device, use the qualification build after the corpus completes for the
reader and evidence checks. For check 2 and the Draft selection in check 3, use an
ordinary build signed in with an account, with **Mail Assistance** turned on in
that device's Settings. The synthetic preview mailbox offers no Reply or New
Message.

1. Open a message, choose **Summarize**, then **Cancel** while it works; summarize
   again and **Dismiss** the result.
2. In a reply, choose **Suggest reply** and accept it, then **Undo**; choose
   **Rewrite**, replace the text, then **Undo**. Each Undo restores the Draft
   exactly as it was.
3. Translate a message and a Draft selection. A missing language is reported,
   and the app never offers to download it.
4. Turn Apple Intelligence off in Settings and relaunch. Record what the first
   evidence line reports. When it is `assistance-disabled`, the reader explains
   why assistance is unavailable and the mailbox and messages remain fully
   usable. On iOS 27.2 (`iPhone18,2`) and iPadOS 27.0.1 (`iPad16,5`) the model
   stayed `available`, and the owner confirmed that Summarize still worked with
   the switch off. The owner [accepted this with no follow-up](https://github.com/unwired-dev/product/issues/625#issuecomment-6335027314).
   The app's device-local [Mail Assistance Enablement](message-summaries.md#mail-assistance-enablement)
   remains required.
5. Turn Apple Intelligence back on and wait for an available-model run, preserving
   its evidence. Then turn networking off and relaunch. Compare the saved answers
   and capability limits with that run to verify generation and translation still
   work on the device; unavailable results alone do not prove offline inference.

Copy the evidence after each relaunch in steps 4 and 5. On the Mac, set
`UNWIRED_QUALIFICATION_HOLD=1` for `qualify:assistance`: it keeps the checked copy
open, prints where each relaunch writes its evidence, and removes the copy only
after you press Return.

The `stale-result` check records `nativeStarts` and `inFlight`. A pass requires
the older request to have reached the native binding and still be summarizing
immediately before replacement, both requests to reach the binding, and only the
newer result to remain ready. Corpus v1 replaced the older request before it
reached the binding. Corpus v2 counted both starts but did not check whether the
older request had already finished. Those results do not establish the v3
in-flight precondition. The [physical v3 reruns on all three nominated devices](https://github.com/unwired-dev/product/issues/625#issuecomment-6337498114)
passed with `nativeStarts: 2` and `inFlight: true`, so in-flight replacement is
qualified for those configurations.

## Record the results

Report each run in [#625](https://github.com/unwired-dev/product/issues/625): the
source revision and root lockfile hash, build configuration and toolchain, the
device record (hardware, OS build, locale and languages), the counts, every
`limited` or `fail` check with its reason, and the manual checks above. Attach
only the evidence file; it holds synthetic corpus text and the model's answers to
it. Keep device serial numbers, UDIDs, local filesystem paths and accounts out of
the issue. Older evidence containing an `evidence` path must have that field
removed before attachment. The review
agent carries the results into the platform qualification record. A missing
configuration remains a required release check.
