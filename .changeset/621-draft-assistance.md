---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Rewrite Draft text and suggest replies on device on iPhone, iPad and Mac (#621).

- **Rewrite:** the composer's Rewrite action rewrites the selected text, or the whole authored body when nothing is selected, through Apple's on-device system language model.
- **Suggest reply:** a Reply or Reply All Draft can ask for one suggested reply built from its authored text, its To and Cc display names and its already-local quoted message, cut so the input stays within 6,000 characters. It never reads recipient address fields or Bcc, drops any address in names or quoted text, makes no Gmail request and has no cloud fallback.
- **Review first:** the result is an unsaved preview. Replace text or Use reply replaces exactly the captured text as one edit that one Undo reverts, without changing recipients, the sender, the subject, quoted text, attachments or delivery state. Keep original closes it, and nothing is ever sent.
- **States:** progress with Cancel, refusal, failure and each unavailable reason leave the Draft unchanged. Text over 6,000 characters or with Inline Images is refused with guidance. Editing the body or admitted reply context, changing accounts or closing the Draft cancels the request and drops its result.
- **Mock Mail Sessions:** fixed synthetic rewrite and reply outcomes, matched by every selected native mock build.
