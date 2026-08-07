---
'unwired-mail': patch
---

Revalidate the current Trusted Device immediately before deferred provider-action dispatches and retries, and let revocation cleanup finish without awaiting the action that triggered it.
