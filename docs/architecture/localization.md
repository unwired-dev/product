# Interface localization: architecture notes

Reviewer-only companion to [interface translations](../localization.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).

Both hosts use the shared message-date formatter with explicit components. Apple's
[Hermes implementation](https://github.com/facebook/hermes/blob/main/lib/Platform/Intl/PlatformIntlApple.mm)
applies hour cycles when an hour component is requested; its date/time-style path
bypasses that handling.

## Shared and native boundaries

[`@private-email/localization`](../../packages/localization/src/index.ts) owns an
[i18next](https://www.i18next.com/overview/configuration-options) instance, English
fallback, typed keys, interpolation, and serialized preference changes. Each
native host owns its [react-i18next](https://react.i18next.com/) hooks, keeping the
mobile and Mac React versions isolated. Bundled resources initialize synchronously;
there is no translation network request or Babel extraction step. i18next fits
both native hosts without adding a compiler pipeline.

[`catalogs.bundle`](../../packages/localization/catalogs.bundle) is copied into each
native app and also imported by JavaScript. Apple locale matching and preference
persistence live in [`native/localization`](../../native/localization). Mac menu
labels use the catalog's `native` section with per-key English fallback. The
native window title substitutes `{{number}}`; other native labels are plain text.
Native catalogs are parsed once per resource and cached for the process lifetime;
language selection and per-key fallback still refresh on each lookup.
