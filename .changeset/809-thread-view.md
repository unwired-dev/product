---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Add a Thread view to the Expo app at `/thread/[id]?mailbox=`. It stacks every
locally cached message of the opened message's Gmail thread, newest at the top,
opens scrolled to the opened message and highlights it. Quoted history in each
message starts collapsed behind Show quoted text. Gmail's quote container, Apple
Mail's and Thunderbird's cited blockquotes, an "Original Message" marker and a
trailing run of `>` lines count as quoted history. The single-message reader still
shows full bodies.

Bodies currently load in newest-first mount order within the existing concurrency
limits. Viewport priority and off-screen distance ordering remain follow-up work
in [#862](https://github.com/unwired-dev/product/issues/862);
an older opened message can wait behind off-screen bodies. This slice does not
qualify full conversation loading or native scroll anchoring.
