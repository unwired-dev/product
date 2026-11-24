---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

Writing tools can now say when a rewrite needs clarification. A `needs-clarification` rejection from the native model reads as a text-free `{ kind: 'clarification' }` Draft assistance state for Rewrite, Expand Text, Shorten Text, Make More Friendly and Make More Neutral, and as `failed` for every other operation. On Mac, iPhone and iPad the composer shows the approved card: "Couldn’t rewrite this. Your Draft is unchanged — edit your original to make it clearer, then try again." It offers Try Again and Close and leaves the Draft and its Undo history unchanged. The native binding does not emit the code yet (#2776).
