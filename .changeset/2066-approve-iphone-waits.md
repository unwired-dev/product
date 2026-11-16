---
'@private-email/localization': patch
'@private-email/mail-core': minor
'@private-email/mobile': minor
---

iPhone's Approve this device step waits for approval by itself: under the code, "Waiting for approval…" replaces the Check for approval button, and the device checks every 10 seconds while the step is on screen, without showing progress. A check that cannot finish, such as offline, leaves the step as it was. An Apple sign-in from before launch cannot check silently, so that step keeps Check for approval. "Use Recovery Key Instead", a text button, opens the Recovery Key as its own step, and "Wait for Approval Instead" returns. The registration store adds `checkForApproval`, and a Pending Device's status reports `approvalSignIn` when its check needs an interactive sign-in (#2066).
