Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the Convex backend in `packages/convex`.

The backend is an opaque store and relay. It authenticates Product Accounts and Trusted Devices, stores ciphertext and the operational metadata the owning decisions allow, and never reads mail or Product Sync plaintext. Every public function is reachable from the public Internet, including by the deployed Swift prototype.

Before reviewing, read `packages/convex/convex/_generated/ai/guidelines.md`; it overrides general Convex knowledge.

#### Authentication and authorization

- A public `query`, `mutation`, `action` or `httpAction` that reads or writes account data without establishing the caller and the authorization required by that operation. Trace `convex/productAccountAuth.ts` helpers (`requireProductAccount`, `requireAuthenticatedTrustedDevice`, `requireTrustedDeviceProof`, `requireTrustedDevice`) or the owning equivalent boundary. Account bootstrap in `productAccount.connect` derives verified `ctx.auth` identity and checks deletion before creating the account; it cannot require an existing account. Provider HTTP routes use their owning verifier. Follow the handler through authentication and each ownership check before protected data is returned or changed.
- A Product Account, token or user identifier accepted as an argument and used for authorization. Identity is derived from `ctx.auth.getUserIdentity()` and `tokenIdentifier`; never `subject` alone, and never an email address.
- A read or write reached by document `_id` or by an index that does not include the owning `productAccountId`, without an ownership comparison afterwards. One account must never observe another's devices, payloads, routes or requests.
- A new path that skips the deleted-account check (`requireProductAccountNotDeleted`), the Trusted Device revocation or reconnect checks, or the Product Sync key-epoch fence (`requireCurrentProductSyncKeyEpoch`) that its sibling functions apply.
- A function called only by other Convex functions registered as public rather than `internalQuery`/`internalMutation`/`internalAction`.
- An HTTP route that trusts a header, a body field or a provider push before verifying its signature, issuer, audience, expiry and binding to the stored connection. A client-side check never replaces this.
- Accounts merged or matched by email, or mailbox consent inferred from a Product Sign-In.

#### Privacy and opacity

- Code that decodes, inspects, logs, indexes or branches on the content of `encryptedPayload` or any enrollment or recovery envelope. The backend compares ciphertext only for equality.
- A new stored field, log line, push payload or error message holding mail content, a subject or sender, a provider token, an ID token, an email address or a classification. APNs wakeups carry only the provider name, an opaque route identifier and the documented history marker.
- A credential or proof kept longer than verification needs: stored where a digest suffices (`trustedDeviceCredentialDigest`), persisted when it should be held only for the call, or returned to a client other than the one that owns it.
- A log that prints a foreign error, a response body or request arguments. Log the allow-listed diagnostic from `failureDiagnostic` in `convex/effectRuntime.ts`.

#### Writes, conflicts and atomicity

- A Product Sync payload write that is unconditional or write-if-absent. Writes are compare-and-set on `expectedUpdatedAt`; the atomic mutation checks every revision before any write or delete.
- An ordinary Product Sync record write before the account's recovery envelope is published (`requireRecoveryEnvelope`), or initialization that publishes its initialized marker separately from the recovery envelope. `initialize`/`publishFirstRecoveryEnvelope` atomically create the first envelope and marker; they cannot require a pre-existing envelope.
- An ownership claim, admission, enrollment adoption or rotation split across several `ctx.runMutation` calls from an action. Each mutation is its own transaction, so a concurrent caller interleaves between them; the invariant belongs in one mutation.
- Destructive cleanup (old key material, routes, credentials, enrollment requests) ordered before the replacement is durably adopted, or with no recovery for a crash between the two.
- A scheduled function, cron or retry that is not idempotent, or a provider submission retried automatically after an uncertain outcome.
- A removal replay check keyed only by a replaceable row ID when retained aliases identify the same account-owned entity. In `productAccount.revokeTrustedDevice`, resolve the selected live or retained target and check the account-scoped installation `deviceIdentifier` before changing rotation state; sign-out and reconnect can give that installation another Trusted Device ID. Removing an already-tombstoned installation through any retained ID must return the existing rotation status without replacing recovery material or inserting another tombstone, or retries can rotate the Recovery Key again and break unique tombstone lookups.
- A self-target prohibition checked only against the caller-supplied row ID before alias resolution. In `productAccount.revokeTrustedDevice`, compare the authenticated live device's installation `deviceIdentifier` with the resolved account-owned target before installation-level completion or rotation. A retained ID of the caller's own installation must receive the existing sign-out refusal; otherwise `deleteRevocationTargetDevicesAndRoutes` removes the authenticated row too and can leave no device able to adopt the rotation. Preserve the separate already-tombstoned installation replay guarantee above.
- A reserved payload identifier or prefix made writable by clients (`requireUnreservedPayloadIdentifier`).

- `productSyncEnrollment.complete` accepting the epoch of the current approval or recovery grant without matching the epoch the caller actually stored. A saved older ring from an interrupted admission must not acknowledge a newer grant; otherwise the new Trusted Device misses the transition it needs.
- `productAccount.unregisterPendingDevice` treating an absent pending row as proof that sign-out is complete. Admission may already have carried that credential into a Trusted Device whose reply was lost; authenticate and remove that installation with the same rotation cleanup, or sign-out leaves live access and an orphan that can hold rotation pending.

#### Bounded work

- `.collect()` or an unpaginated loop over a table that grows with accounts, devices, payloads or routes; a `.filter` scan where an index exists or should; a list argument with no maximum length (see `requireValidAtomicMutationCount`).
- A deletion or migration that processes an unbounded set in one transaction rather than in batches that reschedule themselves, as `productAccountDeletionData.ts` does.
- `productAccountDeletionData.prepareDeletion` requiring a still-live Trusted Device to resume an authenticated account's already-authorized `deleting-data` request. Cleanup removes those device rows before completion, so that requirement strands interrupted deletion; retain account ownership and device proof for initial authorization and revocation-pending work.
- A new table holding account-owned rows that account deletion in `productAccountDeletion.ts` and `productAccountDeletionData.ts` does not remove. Deletion guarantees are enumerated by hand there.
- An unbounded array stored inside a document, or high-churn fields added to a document that many queries read.

#### Schema and deployed clients

- A field in `convex/schema.ts` removed, made required or retyped while existing documents or deployed clients still use the old shape, with no migration or compatibility path.
- A function's arguments, return shape or `ConvexError` `code` changed without the matching change in `packages/contracts` and its fixture. Clients decode these codes to choose recovery; a renamed code turns a recoverable state into an unknown failure.
- A wire validator defined inline in a function when `@private-email/contracts` already owns that shape.
- A public function missing an argument validator, or one returning a whole document where the client contract lists specific fields.

#### Effect in actions

- An action or HTTP handler that calls an external service outside an Effect program, runs more than one program per handler, or calls `Effect.run*` directly rather than `runConvexProgram`.
- `fetch` without an abort deadline, or called outside `call`/`Effect.tryPromise` so the failure is untyped.
- Configuration read from `process.env` rather than the provider `runConvexProgram` supplies; Convex's environment cannot be enumerated.
- Effect introduced into a deterministic query or mutation. Those stay plain TypeScript with Convex validators, using `Schema` only for embedded unknown payloads.
- A response from a provider (Google, Apple, Microsoft, APNs) used before a `Schema` decode, or a decode failure treated as success.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- Changed runtime behavior with no test in `packages/convex/test` that calls the public function against the test database and identity context and covers the unauthorized caller, the malformed input and the conflict or retry the change introduces. State it as a finding only after reading the existing tests.
- A runtime change with no changeset.

#### Leave to tooling

The Convex ESLint plugin, validator syntax, `_id`/`_creationTime` naming, mutable generated types, and everything under `convex/_generated/`. Effect import style and globals inside Effect code are lint errors.
