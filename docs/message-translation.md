# On-device translation

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/message-translation.md).

[#622](https://github.com/unwired-dev/product/issues/622) adds
[Translation Assistance](domain/assistance.md) on iPhone, iPad and Mac: an
explicitly requested translation of an opened message, or of selected Draft text,
through Apple's on-device Translation framework. There is no remote translation
fallback and nothing is downloaded by the app.

## Behavior

- The reader shows **Translate** once the message body is on this device, next to
  **Summarize**. Opening a message never translates it.
- Choosing **Translate** lists the target languages the device's Translation
  supports. Nothing runs until the person picks one; picking another language
  replaces the pending or shown translation.
- A reader translation reads only the readable text already shown: the plain-text
  presentation of a Gmail body from the encrypted cache, or the preview fixture's
  body. It never fetches a missing body, attachments, Inline Images or remote
  content, and makes no Gmail request. The body is read only up to the input limit, so
  rendering a long message never joins its whole text. Input is cut at 6,000 characters (never
  inside a surrogate pair), and a cut translation says so.
- A reader translation is a read-only preview beside the unchanged message, naming
  the identified source language and the target and saying it was made on this
  device, may be inaccurate and is not saved. **Dismiss** forgets it. It is never
  stored, synchronized or written into mail.
- In a Draft, **Translate** in the formatting toolbar is enabled while body text is
  selected. It captures the selected text without list markers and opens a review
  panel. The Draft is unchanged until **Replace selection**, which replaces exactly
  the captured selection as one edit that one **Undo** reverts. **Keep original**
  closes the panel. When the translation retains the selected line breaks, those
  lines keep their list and block formatting. The inserted text takes the formatting of the text
  before it. The selection's own leading and trailing whitespace is kept around the
  translation, so neighbouring words stay separated. Recipients, the subject,
  attachments and delivery state are never changed.
- A Draft selection containing an Inline Image is refused with guidance to select
  text without images. Text selected before or after an image still translates;
  the image and its stored bytes stay unchanged.
- A Draft selection longer than 6,000 characters is not cut, because applying the
  translation replaces the whole selection; the panel asks for a shorter selection.
- Dismissed reader controls cannot restart translation or affect a later preview.
  Cancel and Retry controls from an earlier request cannot affect its replacement.
- While Translation works, the panel shows progress and **Cancel**. Cancelling
  stops the native request; a result that still arrives is dropped.
- A result belongs to the input it was requested for. Opening another message,
  switching mailbox or account, or changing the bounded reader input cancels a
  reader translation and forgets its preview before the next render. Changes only
  beyond the captured prefix keep the translation valid: that text was not translated.
  Any edit to the Draft body cancels a
  pending Draft translation and closes its review, so a stale result is never
  offered or applied.
- When Translation cannot run, mail and the Draft stay unchanged and the panel says
  why: the languages are supported but not downloaded (the person downloads them in
  the system Translate settings; the app never starts a download), the pair is
  unsupported, the source language could not be identified, or the text is already
  in the target language. Other failures have their own message. **Try again** is
  offered except for an unsupported pair or the same language. A device that
  reports no languages says that translation is unavailable.

Mail Assistance Enablement, the per-Profile opt-in, is not part of this slice; see
[#788](https://github.com/unwired-dev/product/issues/788).

## Native binding

The methods are on the `UnwiredAssistance` module in
`native/private-inbox/bridge/UnwiredAssistance.swift`, which both hosts compile, so
no setup step is needed. `cancel(request)` stops a summary or a translation.

| Method                              | Result                                                                                                                                               |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `translationLanguages()`            | Supported target languages as `{ code, name }`, with `name` in the device language                                                                   |
| `translate(request, input, target)` | `{ source, text }`, or a rejection coded `not-installed`, `unsupported-pair`, `unidentified-language`, `same-language`, `cancelled` or `unavailable` |

The native host identifies the source language and accepts only installed pairs;
it never requests a language download. Cancellation stops its translation session.
The shared store must validate every returned language and translation: BCP 47-shaped
codes, names up to 100 characters, at most 500 languages and translations up to
24,000 characters. Invalid results leave the source unchanged. Failure logs carry
only an allow-listed native code or decode path, never mail or translated text.

## Deterministic evidence

- `packages/mail-core/test/translation.test.ts` covers the input bounds, every
  unavailable outcome, malformed, oversized and empty results, log privacy,
  cancellation with a late result, replacing a pending language, the language list,
  Mock Mail Session outcomes, and the Draft selection capture and replacement as one
  undoable edit that keeps list items and surrounding formatting.
- `apps/mobile/test/translation.test.tsx` and `apps/macos/test/translation.test.tsx`
  drive the real reader with the real Gmail store and a synthetic Gmail mailbox:
  translating reads only the local text and makes no Gmail request, an uninstalled
  language leaves the message readable, cancellation, and switching message,
  mailbox store or account drops a late or shown result.
- The composer tests in both hosts select Draft text, review a translation, apply
  it as one undoable edit without touching recipients, keep the original, and drop
  a pending translation when the body is edited.
- [Mock Mail Sessions](mock-mail-sessions.md#boundaries-and-scenarios) supply fixed
  translation outcomes, and every selected native mock build answers with the same
  fixed synthetic translation and language list instead of running Translation.

These are mocked journeys. They do not show that Apple's Translation runs or what
it produces.

## Deferred native checks

Running the binding on iOS, iPadOS and macOS 27 with installed, downloadable and
unsupported language pairs is deferred until that environment is available, and
remains required before release. Compilation of the bridge in the host builds is
not evidence of translation behavior.
