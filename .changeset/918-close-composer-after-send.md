---
'@private-email/mobile': patch
'@private-email/macos': patch
---

A successful Send now always closes the composer on iPhone, iPad and Mac, even when
the sent Draft leaves Drafts before Send finishes. The composer no longer stays open
on "This Draft is not available." A refused Send still keeps the composer open with
its reason.
