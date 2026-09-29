# Interface translations

The Expo iOS/iPadOS and React Native Mac clients ship English. The **Language**
control below the Inbox offers **System default** and **English**. System default
matches the device's preferred languages against the shipped catalogs, including
regional variants, and falls back to English. An explicit selection overrides the
device language, persists across launches, and applies to every open Mac window.
Returning to System default removes the override.

The preference lives in the app's local `NSUserDefaults` domain as
`interfaceLanguage`. It is not part of mailbox storage or Product Sync. Locale
notifications and foreground activation refresh system settings. The override is
loaded before the first React render. Mac menus and window titles use the same
catalog and saved preference, including before JavaScript starts.

Dates use the device's regional format under System default and the selected
language's format under an override. The preview Inbox retains its existing UTC
time zone. Message senders, subjects, previews, and bodies are content and are
never treated as translation keys.

## Implementation

[`@private-email/localization`](../packages/localization/src/index.ts) owns an
[i18next](https://www.i18next.com/overview/configuration-options) instance, English
fallback, typed keys, interpolation, and serialized preference changes. Each
native host owns its [react-i18next](https://react.i18next.com/) hooks, keeping the
mobile and Mac React versions isolated. Bundled resources initialize synchronously;
there is no translation network request or Babel extraction step. i18next fits
both native hosts without adding a compiler pipeline.

[`catalogs.bundle`](../packages/localization/catalogs.bundle) is copied into each
native app and also imported by JavaScript. Apple locale matching and preference
persistence live in [`native/localization`](../native/localization). Mac menu
labels use the catalog's `native` section with per-key English fallback. The
native window title substitutes `{{number}}`; other native labels are plain text.

Use complete messages with named interpolation values, such as
`t('inbox.unreadRow', { sender, subject })`. Do not concatenate translated sentence
fragments. React Native renders text directly, so interpolation does not HTML-escape
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
mise exec -- pnpm exec turbo run lint format check-types test \
  --filter=@private-email/mobile... --filter=@private-email/macos...
mise exec -- node --test native/localization/test/native.test.mjs
```

The Node integration test requires macOS/Xcode. It compiles the real Foundation
adapter into an isolated temporary app, tests a temporary French catalog and
regional matching, and launches separate processes to verify preference
persistence and removal. It removes its preferences domain and temporary bundle.
French exists only in tests; it is not shipped.

Follow [Expo native validation](expo-client.md#validate) for the packaged iPhone
and iPad journey, which also checks language selection across relaunch. The
focused Mac language journey does not require access to mailbox Keychain items:

```sh
mise exec -- pnpm --filter @private-email/macos native:build Testing
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app" \
  testLanguagePreferenceAcrossWindowsAndRelaunch
```

Omit the test name to run both Mac journeys. The mailbox journey still requires
the signing/provisioning setup described in [private storage](private-inbox-storage.md).
