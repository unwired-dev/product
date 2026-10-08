# Translation: architecture notes

Reviewer-only companion to [on-device translation](../message-translation.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).

## Native boundary

Both hosts compile `UnwiredAssistance`. Translation remains separate from the
Foundation Models summary operation. The adapter identifies a source using
`NLLanguageRecognizer`, lists `LanguageAvailability().supportedLanguages` with
localized names, and checks `LanguageAvailability.status(from:to:)`.
Only an installed pair enters `TranslationSession(installedSource:target:)`;
this initializer cannot request downloads. The supported-but-uninstalled state
is reported as `not-installed`, leaving the person to install languages through
system settings. Cancelling the request task invokes the session's cancellation.
No provider or backend participates and mail content is never downloaded by
translation.

The shared store decodes results with Effect Schema. Each mounted host owner
retires the store during layout cleanup. Reader ownership includes the native
provider, mailbox store, message identifier and full readable input. Draft review
checks the current ready result at acceptance, while the composer synchronously
invalidates its captured selection when its body changes or review closes.
Undo returning to the same body object cannot restore that invalidated capture.

## Decisions and evidence

[ADR 0052](../adr/0052-keep-mail-assistance-on-device-and-input-bound.md),
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
and [ADR 0060](../adr/0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)
own the privacy, replacement and qualification boundaries. This slice exposes
explicit target-language selection and installed-only translation. It provides no
source-language override or in-app language-download presentation;
[#622](https://github.com/unwired-dev/product/issues/622) specifies explicit target
selection and available on-device capabilities. Device-local assistance enablement
is tracked separately by [#788](https://github.com/unwired-dev/product/issues/788).
The broader prototype behavior notes are not passing evidence
for this slice. Live Apple Translation and physical-device qualification remain
required before release, separately from deterministic host journeys and build
compilation.
