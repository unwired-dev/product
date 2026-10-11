---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Gate every explicit On-Device Mail Assistance action, Summarize, Draft Rewrite and
Suggest reply, and Translate, behind Mail Assistance Enablement. It defaults off
on every device, is turned on or off from **On-device assistance** on the account
page for the Product Account's Default Profile, and is stored only in this
device's Keychain; sign-out, deletion and device removal purge it. While it is
off the actions are hidden and nothing reaches Apple's model or Translation;
turning it off cancels in-flight assistance and forgets shown previews.

`@private-email/mail-core/assistance-enablement` exports the enablement store, and
Mock Mail Sessions gain an `assistance-disabled` scenario and a `mailAssistance`
provider. The hosts' `AssistanceContext` and `TranslationContext` now default to
no assistance.

The account page offers an explicit Apple Intelligence availability check only
while assistance is enabled. It explains unavailable states without generating
text and discards checks and status when assistance or the account changes.
Unsaved device choices show saving or failure status and offer a save retry;
turning assistance off closes the gate even if persistence fails.
