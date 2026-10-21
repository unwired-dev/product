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

## The qualification build

The `assistance-qualification` [Mock Mail Session](mock-mail-sessions.md) build shows
the synthetic `open-read-relaunch` mailbox, but its native binding runs Apple's
system language model and Translation instead of the fixed synthetic answers every
other mock build compiles. Like other mock builds it refuses remote content and
contacts no provider. Only this build contains the corpus run and its evidence
recorder; `verify:bundle` rejects the run in any other bundle, and TestFlight
uploads refuse mock builds.

Each interactive launch runs version 1 of the synthetic corpus once, through the
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
  preview, each with its late result, and a newer request replacing an older one.

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
the run stops, or it times out after 30 minutes
(`UNWIRED_QUALIFICATION_TIMEOUT` seconds).

## Run on iPhone and iPad

Physical iPhone and iPad runs are owner-operated, with local Xcode signing, in the
session agreed in [#1106](https://github.com/unwired-dev/product/issues/1106).
Install the build under its own bundle identifier so it never replaces an
installed Unwired Mail or reads its data:

```sh
UNWIRED_MOCK_SCENARIO=assistance-qualification \
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
xcrun devicectl device process launch --device <device> dev.unwired.mock.assistance
```

Keep the app in the foreground until the run completes, then copy the evidence and
remove the app with its data:

```sh
xcrun devicectl device copy from --device <device> \
  --domain-type appDataContainer --domain-identifier dev.unwired.mock.assistance \
  --source tmp/assistance-qualification.jsonl \
  --destination artifacts/assistance-qualification/<hardware>.jsonl
xcrun devicectl device uninstall app --device <device> dev.unwired.mock.assistance
```

Repeat the copy until its last line is `complete`. Each launch starts a new
evidence file, so copy it before relaunching.

## Checks the corpus does not automate

On each device, in the same build after the corpus completes:

1. Open a message, choose **Summarize**, then **Cancel** while it works; summarize
   again and **Dismiss** the result.
2. In a reply, choose **Suggest reply** and accept it, then **Undo**; choose
   **Rewrite**, replace the text, then **Undo**. Each Undo restores the Draft
   exactly as it was.
3. Translate a message and a Draft selection. A missing language is reported,
   and the app never offers to download it.
4. Turn Apple Intelligence off in Settings and relaunch: the first evidence line
   reports `assistance-disabled`, the reader explains why assistance is
   unavailable and the mailbox and messages remain fully usable.
5. With networking off, a relaunch completes the corpus as before, showing that
   generation and translation stay on the device.

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
