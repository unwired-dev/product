Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the retained Swift code: the SwiftUI and Mac Catalyst prototype in `apps/unwired-mail` and the provider qualification tool in `tools/swiftmail-provider-qualification`.

The prototype stays in use until cutover removes it. Review it against its own decisions and deployment targets, never against the replacement's version-27 floor or planned replacement behavior, and do not carry its architecture into the replacement.

#### Scope

- A change that rebuilds the prototype toward the replacement's design, or that adds a feature the replacement has deferred. Prototype work is maintenance.
- A newer API used without an availability guard for the Xcode project's actual deployment target.
- A prototype result (Catalyst behavior, SwiftMail qualification) presented as evidence for the replacement hosts.

#### Privacy and isolation

- A credential, token, mail body, subject, sender or decrypted Product Sync value written to a log, to analytics, to storage outside the approved device-local stores, or sent to the backend. Provider credentials and protocol decisions never enter Product Sync or Convex.
- State, cache or credentials from one Product Account or Mailbox Connection readable from another: a cache key, SwiftData predicate or Keychain account that omits the owning identifiers.
- A Keychain item with weakened accessibility or made synchronizable.
- HTML rendered without sanitization, with JavaScript enabled, with a persistent data store, or remote content loaded without the user's choice.
- Diagnostics or exported reports that include fields outside the existing allow-list.

#### Delivery and provider actions

- A provider submission retried automatically after an uncertain outcome, or a queued action replayed after its authorization generation changed. Ambiguous outcomes reconcile; they do not resend.
- A Pending Provider Action attempted before it is persisted, or a failure attributed to a different action on the same connection.
- Product Sync written through an unconditional or write-if-absent path, or a record caller that creates key material. Use the typed record boundary described in `.patterns/product-sync-records.md`.
- TLS, certificate or hostname verification weakened for a mail transport.

#### Concurrency and lifecycle

- UI-owned observable state mutated off the main actor; a task started from a view or service with no owner that cancels it; work that continues after sign-out, account switch or connection removal and writes into the next session's state.
- Cancellation ignored in a sync, backfill or send path, so a cancelled operation still commits.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- Changed behavior or a failure path with no Swift Testing coverage. XCTest is for APIs that require it, such as UI automation.
- A test that waits on a sleep or on scheduler ordering rather than on an observable state change.

#### Leave to tooling

swift-format and SwiftLint findings and compiler diagnostics. Legacy Swift CI is not a maintained merge gate; report which checks were actually run.
