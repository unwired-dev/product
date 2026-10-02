---
'@private-email/convex': patch
---

Run the Apple, Google and APNs actions as Effect programs with tagged retryable and terminal failures, keeping the same responses, errors and retry persistence. APNs failure logs now carry only the status and a documented rejection reason. A Gmail identity token with a malformed signature segment now fails with the ownership proof rejection instead of a raw decoding error.
