---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Check Mac Writing tools results for the details they change. Before a rewrite
is applied, the review panel compares links (including where linked words go),
email addresses, amounts, numbers, dates, times and quotes with the original,
lists each changed, uncertain, removed or added detail beside the original value and the
kept ones, and offers **Use rewrite with changes** instead of Replace text when
anything differs, with Keep original as the Return-key default. Every result notes that the checks compare details only. The
assistance core exports `checkDetails`, and the semantic document exports
`selectedLinks`.
