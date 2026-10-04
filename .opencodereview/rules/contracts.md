Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to `packages/contracts`.

`packages/contracts` defines the shapes that cross between the backend and independently released clients: Convex validators, their inferred types and the JSON fixtures native clients decode in tests. A released client keeps sending and expecting the old shape after the backend deploys.

#### Compatibility

- A field removed, renamed, retyped or changed from optional to required in a response validator, or a new required argument, while a deployed client still depends on the old shape. Additive optional fields are the compatible change; anything else needs a stated migration.
- A literal added to a union that existing clients decode exhaustively (an error code, a status, a provider) with no handling for clients that do not know it.
- An error `code` value changed or reused for a different meaning. Clients choose recovery from the code.
- An affected wire fixture or native decoder left on the old shape after its validator changes, or a fixture edited only to pass while the validator and its consumers still disagree. Read both JSON fixtures under `fixtures/` and inline fixtures in `src/`; not every validator has a separate JSON fixture.
- An incompatible contract change deployed without a compatible backend/client rollout or stated migration. Consumers live in `packages/convex` and native or shared client code; a compatible additive change need not edit every consumer.

#### Identity and privacy in the shape

- Distinct identities collapsed into one field or a plain `string` passed between roles: Product Account, Trusted Device, Mailbox Connection, provider mailbox, thread and message identities stay separate so one cannot be supplied where another is required.
- A response that exposes a field the caller does not need, especially a credential, token, email address, another device's identifier or an internal document. `trustedDeviceCredential` is returned only to the device it was issued to.
- A field that would carry mail content, Product Sync plaintext or a classification through the backend. Payload bodies are opaque ciphertext.

#### Package boundary

- Runtime logic beyond validators, inferred types, fixtures and small derived helpers. Behavior belongs in the backend function or the shared core.
- A dependency other than `convex` validators added to this package, or an import from `packages/convex`, `packages/mail-core` or an app. Every consumer bundles this package.
- A new module without a subpath in `package.json` `exports`.
- A type declared by hand beside a validator rather than inferred from it with `Infer`; the two drift.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- A new or changed wire validator with no meaningful test through its public decoding or backend boundary that accepts the supported shape and rejects the malformed case introduced by the change; inspect `packages/contracts/test`, Convex integration tests and native fixture decoding. State it as a finding only after reading the existing tests.
- An exported type or validator change with no changeset.

#### Leave to tooling

Formatting, import order, unused exports and type errors.
