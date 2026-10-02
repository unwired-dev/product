# Private inbox storage: architecture notes

Reviewer-only companion to [docs/private-inbox-storage.md](../private-inbox-storage.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Ownership and failure behavior

`native/private-inbox` owns a versioned AES-256-GCM encrypted snapshot, using
CryptoKit and Security without a third-party database dependency. This small
fixture store is not a general mail database or the future 500 MB body cache.
The complete fixture, including metadata and bodies, is encrypted in `inbox.enc`
under the host's Application Support directory. The directory is excluded from
backup; iOS writes also use complete file protection. Atomic ciphertext replacement
and file synchronization finish before an update resolves. Temporary writes
contain ciphertext, not fixture plaintext.

The native Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable: false`, and the Data Protection Keychain on macOS. Apple documents the [device-local accessibility policy](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
and [Mac Data Protection Keychain selection](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain). The native module uses
React Native's legacy-module interoperability in both hosts.

On iOS, protected-data availability is checked before filesystem access and again
before first-run seeding.

A native file lock covers each read-modify-write operation, including first
initialization. Each mutation reloads the latest ciphertext and changes only the
requested message. The shared store
serializes operations with an Effect semaphore and publishes updates to all mounted views.

`SyntheticCredential` owns a separate Keychain service and lifecycle. It creates
a random synthetic secret, uses it natively for a fixed local HMAC challenge,
and removes it idempotently.
