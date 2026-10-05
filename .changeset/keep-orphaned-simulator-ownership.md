---
'@private-email/mail-test-harness': patch
---

Keep a Mail Test Run's ownership record when Simulator cleanup fails, so `doctor` reports the orphan and a later cleanup can still prove ownership.
