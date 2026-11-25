---
'@private-email/mail-core': minor
---

Add `createUnsubscribe`, the host's `unsubscribe`: a one-click request that ends `sent` is recorded on this device, sealed for the Product Account, for the Mail Profile that owns the receiving connection, with the list's Mailing List Identity, name and date but no URI, header or request body. `sentRequest` reads it for 14 days after the request, so the list's messages read as sent on that date and offer Unsubscribe again afterwards. Unsubscribe offers now carry the list's `identity` when their `List-Id` conveys a valid RFC 2919 identifier; an offer without one records nothing (#2823, part of #654).
