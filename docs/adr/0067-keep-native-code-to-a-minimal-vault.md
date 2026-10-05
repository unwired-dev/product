---
status: accepted
---

# Keep native code to a minimal vault

`native/private-inbox` has grown to about 2,350 lines of Swift. Besides holding
keys, it runs the registration flow, Convex transport, Product Sync coordination,
and the synthetic registration scenarios. Contract shapes are duplicated as Swift
`Decodable` types. Flow behavior can only be tested in the hosted Swift suite, and
mocked journeys need a native build. Both hosts already share the same Swift
sources, so keeping this logic native saves no duplication.

## Decision

The native layer stays minimal. It owns only what needs Apple platform APIs or
must never enter JavaScript. Everything else lives in TypeScript workspace
packages. New native code must meet one of the criteria below; otherwise it
belongs in TypeScript.

Native code owns:

- **Keychain and file storage**: every Keychain item and its accessibility,
  synchronization and Data Protection Keychain policy, file protection, backup
  exclusion, and the encrypted Inbox store with its database key.
- **Key material**: generating, storing and using the Product Sync key ring,
  deriving keys from the Recovery Key, enrollment key agreement, and sealing and
  opening every envelope and record. Turning an entered Recovery Key or
  Enrollment Code into key bytes stays native too.
- **Provider SDKs and credentials**: Google Sign-In, Gmail authorization and
  Sign in with Apple. Provider tokens never leave native code.
- **Credentialed backend calls**: one generic primitive that attaches the Product
  identity credential and the Trusted Device Credential to a Convex call.
  TypeScript chooses the function and arguments and decodes the response. Neither
  credential crosses the bridge.
- **Persist-then-return steps**: operations that must store keys durably before
  anything is acknowledged complete that storage before they return.

TypeScript packages own, as Effect programs in `packages/mail-core` following
[ADR 0065](0065-scope-effect-adoption.md), with shapes from
`packages/contracts`:

- the registration flow: restore, sign-in, linking, reconfirmation, mailbox
  selection, Gmail authorization sequencing, the statuses shown to the user, and
  retry and resume;
- choosing Convex functions, building their arguments and decoding their responses
  with `Schema`;
- Product Sync coordination: pagination, compare-and-set retries, sequencing of
  initialization, enrollment, recovery, rotation and revocation, and mailbox
  descriptor reconciliation;
- synthetic providers and the mock backend, as test layers.

Shared packages keep no React Native or native-module imports, as
[ADR 0064](0064-isolate-mobile-and-macos-native-dependencies.md) requires. Each
host passes its native module to the shared program as an adapter.

The native interface exposes operations named by purpose, such as "create the key
ring and return its recovery envelope" or "open this recovery envelope with the
entered Recovery Key and store the ring". It never exposes raw encrypt, decrypt or
read-key primitives. Values crossing the bridge are ciphertext, opaque
identifiers, presentation data or fixed error codes. Keys, credentials and
foreign error descriptions never cross.

## Why

Logic that both hosts run belongs in one language with typed contracts, and its
tests should run in the workspace without a native build. A smaller native
surface is easier to audit and to qualify on devices. Custody of keys and
credentials stays exactly where [ADR 0001](0001-end-to-end-encrypted-product-sync.md),
[ADR 0002](0002-device-held-mail-provider-tokens-with-push-relay.md) and
[ADR 0005](0005-app-level-encryption-for-sensitive-local-cache.md) put it.

## Considered options

- **Keep the flows native.** Rejected: contract types are duplicated, flow tests
  need the hosted suite, and mocked journeys need native builds, with no sharing
  benefit in return.
- **Move encryption to TypeScript** with a JavaScript crypto library. Rejected:
  key material would sit in the JavaScript heap, Hermes offers no platform
  cryptography, and it adds a production dependency.
- **Give TypeScript the Product identity and Trusted Device credentials** so it
  can call Convex directly. Rejected: JavaScript logs can leave the device, and
  the native call primitive that keeps the credentials native is small.

## Consequences

- Splitting a flow across the bridge creates new failure points, for example the
  app being killed between storing a key and acknowledging it. Vault operations
  must store before they return, TypeScript acknowledges only after they succeed,
  and the interruption and resume tests move along with each flow.
- Decrypted mailbox descriptors reach JavaScript as presentation data, as
  mailbox addresses already do.
- The hosted Swift suite narrows to the vault, Keychain and file protection.
  Mocked TypeScript journeys still need real native integration evidence, as
  [ADR 0060](0060-pair-mocked-mail-journeys-with-real-integration-evidence.md)
  requires.
- The migration moves one flow at a time. Architecture documents that describe
  native ownership of a flow, such as
  [private Product Sync](../architecture/private-product-sync.md) and
  [Mock Mail Sessions](../architecture/mock-mail-sessions.md), change when that
  flow moves.
