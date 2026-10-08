---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Summarize an opened message on device on iPhone, iPad and Mac (#620).

- **Explicit and local:** the reader offers Summarize once a message body is on the device. The summary reads only its subject and readable text, cut at 6,000 characters with a notice when the message was longer, through Apple's on-device system language model. It makes no Gmail request and has no cloud fallback.
- **States:** the reader shows progress with Cancel, the summary as an unsaved preview beside the unchanged message, and why a summary is unavailable: an ineligible device, Apple Intelligence turned off, a model still getting ready, or an unsupported language. Refusals and failures have their own messages, and the message stays readable in every case.
- **Stale results:** opening another message, switching mailbox or account, or a changed body cancels the request and drops its result. Nothing is stored or written to mail.
- **Mock Mail Sessions:** their assistance provider follows the native contract with fixed outcomes, and every selected native mock build returns the same synthetic summary.
