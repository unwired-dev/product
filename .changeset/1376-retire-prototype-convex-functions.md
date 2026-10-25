---
'@private-email/contracts': minor
'@private-email/convex': minor
---

Convex no longer serves the functions only the retired Swift prototype called:
`productAccount.connectGmailProvider`, `listGmailProviderConnections`,
`removeGmailProviderConnection` and `markProductSyncMaterialInitialized`, and
`productSync.getEncryptedPayloadsForTrustedDevice`. The contracts package drops the
`gmailProviderConnectionStatusValidator` and
`productSyncMaterialInitializedResponseValidator` validators and their types. The
maintained clients never called them: they register Gmail through the opaque routing
actions, read Product Sync records one at a time or by page, and `productSync.initialize`
records the initialized marker together with the first recovery envelope.
