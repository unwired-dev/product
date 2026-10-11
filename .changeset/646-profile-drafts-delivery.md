---
'@private-email/mail-core': minor
---

Keep Drafts and their delivery within one Mail Profile. `profileOf` gives a
connection's Profile, and `sendingMailboxes` now requires the Profile whose
senders it lists. The Draft store refuses a sender change into another Profile
and a received attachment from another Profile, **Attach to New Message** never
falls back to another Profile's sender, and `startResponse` leaves only the
sending Profile's addresses out of **Reply All**, so its mailboxes must carry
`profile`. Storage, Product Sync records and Outbox delivery are unchanged, and
creating another Profile remains unavailable.
