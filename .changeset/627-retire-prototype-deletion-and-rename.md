---
'@private-email/convex': minor
---

Convex no longer serves two more functions no maintained client calls:
`productAccountDeletion.deleteProductAccount`, the retired Swift prototype's
deletion action, and `productAccount.renameTrustedDevice`. Hosts delete a Product
Account through `POST /product-account/delete`, which first verifies a recent
Product Sign-In.
