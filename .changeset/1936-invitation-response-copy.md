---
'@private-email/mail-core': patch
---

Invitation responses word their own subject and text: `respond` and `respondAgain`
take the person's translation instead of a prepared copy. `invitationResponding`
gives an invitation card its Responding status and whether an offline device or a
refused sign-in blocks responding, in place of `invitationBlockedBy`.
