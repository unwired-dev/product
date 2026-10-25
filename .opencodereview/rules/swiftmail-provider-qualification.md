Apply every section of `.opencodereview/rules/common.md` to this file first; read it now if it is not in context. The rules below add the defects specific to the retained provider qualification tool in `tools/swiftmail-provider-qualification`.

#### Scope

- A newer API used without an availability guard for the Swift package's actual deployment target.
- A SwiftMail qualification result presented as evidence for the maintained clients' provider implementations.

#### Privacy and isolation

- A credential, token, mail body, subject or sender written to a log or exported report. Provider credentials and qualification fixtures never enter ordinary pull-request CI.
- A qualification run that can mutate a personal or production mailbox rather than its dedicated Provider Test Mailbox.
- Diagnostics or exported reports that include fields outside the existing allow-list.

#### Delivery and provider actions

- A provider submission retried automatically after an uncertain outcome. Ambiguous outcomes reconcile; they do not resend.
- TLS, certificate or hostname verification weakened for a mail transport.

#### Concurrency and lifecycle

- Cancellation ignored during a qualification run, so a cancelled operation continues mutating its mailbox.

#### Tests in the same change

Apply `docs/agents/testing.md`'s admission and proportionate-verification policy: existing meaningful coverage may suffice; document unavailable automation or protected/native evidence with its required follow-up. The cases below identify missing evidence for a named risk, not a requirement to add a test for every edit.

- Changed behavior or a failure path with no Swift Testing coverage. XCTest is for APIs that require it, such as UI automation.
- A test that waits on a sleep or on scheduler ordering rather than on an observable state change.

#### Leave to tooling

swift-format and SwiftLint findings and compiler diagnostics. Legacy Swift CI is not a maintained merge gate; report which checks were actually run.
