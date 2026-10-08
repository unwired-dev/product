# Interface translations

The Expo iOS/iPadOS and React Native Mac clients ship English. The **Language**
control below the Inbox and at the end of the welcome and account pages offers
**System default** and **English**, so the language can be chosen before signing in. System default
matches the device's preferred languages against the shipped catalogs, including
regional variants, and falls back to English. An explicit selection overrides the
device language, persists across launches, and applies to every open Mac window.
Returning to System default removes the override.

The preference lives in the app's local `NSUserDefaults` domain as
`interfaceLanguage`. It is not part of mailbox storage or Product Sync. Locale
notifications and foreground activation refresh system settings. The override is
loaded before the first React render. Mac menus and window titles use the same
catalog and saved preference, including before JavaScript starts.

Dates and attachment sizes use the device's regional format under System default,
including explicit calendar, numbering-system, and 12/24-hour preferences, and the
selected language's format under an override. Message dates keep their existing UTC
time zone. Message senders, subjects, previews, bodies, attachment names, Gmail label
names, mailbox addresses, device names, and Draft subjects, recipients and bodies are
content and are never treated as translation keys.

## Catalog conventions

Use [`@private-email/localization`](../packages/localization/src/index.ts) for typed
keys, interpolation, plurals and English fallback. Each host uses react-i18next
with its own React version. Resources ship with the application; translation does
not make a network request. Regenerate the native projects after changing
[`catalogs.bundle`](../packages/localization/catalogs.bundle). Native menu labels
use the catalog's `native` section with per-key English fallback; `windowTitle`
uses `{{number}}`, while other native labels are plain text.

Shared copy that depends on state, such as the registration, private sync,
sign-in method and Gmail action messages in `@private-email/mail-core`, takes the
host's `Translate` function as its first argument and returns finished text; fixed
copy is looked up with `t` in the host. `mail-core` never imports React or
react-i18next. Link warnings are returned as kinds (`linkWarnings`), which the
hosts describe through `linkWarnings.<kind>`.

Use complete messages with named interpolation values, such as
`t('inbox.unreadRow', { sender, subject })`. Do not concatenate translated sentence
fragments. A message that differs by Gmail action uses an i18next context, such as
`gmailActions.done_archive`. React Native renders text directly, so interpolation does not HTML-escape
message content. For counts, use i18next's `_one`, `_other`, and other plural
categories required by the target locale, and pass `{ count }`.

## Add a language

1. Add `<BCP-47-code>.json` alongside `en.json`. Preserve key names and interpolation
   names. Translate visible labels, accessibility copy, error text, and the native
   menu section. Missing keys fall back to English.
2. Add its code and native language name to `languages.json`. Keep English first
   as the native fallback. Import the new JSON file and register its translation
   resource in `packages/localization/src/index.ts`. The selector reads the
   manifest automatically; never register a language whose catalog is not shipped.
3. Add the code to `CFBundleLocalizations` in
   `apps/macos/macos/UnwiredMail/Info.plist`. Expo generates this list from the
   manifest. Regenerate both native projects so their resource bundles are current.
4. Run the shared and host checks, production bundle checks, and native journeys.
   Verify device-language matching, explicit override, System default, relaunch,
   Mac menus/windows, longer labels, accessibility, plurals, and date formatting.
   Right-to-left languages require layout and native direction qualification
   before adding them to the shipped manifest; this English-only slice does not
   claim RTL support.

Translation resources and language names are shipped application assets. Do not
put message content, credentials, or server responses in catalogs. The retired
SwiftUI prototype and server diagnostic text are outside this client migration.

## Verify

```sh
mise exec -- pnpm lint
mise exec -- pnpm format
mise exec -- pnpm exec turbo run check-types test \
  --filter=@private-email/mobile... --filter=@private-email/macos...
mise exec -- node --test native/localization/test/native.test.mjs
```

The Node integration test requires macOS/Xcode. It compiles the real Foundation
adapter into an isolated temporary app, tests a temporary French catalog and
regional matching and language changes within one process, and launches separate
processes to verify preference persistence and removal. It removes its preferences domain and temporary bundle.
French exists only in tests; it is not shipped.

Follow [Expo native validation](expo-client.md#validate) for the packaged iPhone
and iPad journey, which also checks language selection across relaunch. The
focused Mac language journey checks that repeated preference changes keep one
Window menu entry per open window and remove closed windows. Build with
`UNWIRED_MOCK_SCENARIO=open-read-relaunch` so the preview Inbox opens:

```sh
UNWIRED_MOCK_SCENARIO=open-read-relaunch \
  mise exec -- pnpm --filter @private-email/macos native:build Testing
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testLanguagePreferenceAcrossWindowsAndRelaunch
```

Without a test name the runner selects the mailbox lifecycle journey. Every Mac
journey runs in the runner's disposable signed identity, so both require the
signing/provisioning setup described in the [Mac client guide](macos-client.md#verification).
