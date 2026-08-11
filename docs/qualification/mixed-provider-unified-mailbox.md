# Mixed-provider Unified Mailbox qualification

Issue [#71](https://github.com/unwired-dev/product/issues/71) is enforced by the deterministic
`MailboxConnectionAdapterTests.testProviderRolloutMixedConnectionScenario` fixture. It composes one
authorized connection from each supported provider family under one Product Account:

- Gmail with native labels and the full Provider Mail Action set.
- Standards-based IMAP and SMTP with explicit canonical role mappings.
- Microsoft Graph with its provider-declared capabilities.
- Legacy POP3 and SMTP with product-owned organization and no server-synchronized actions.
- On-premises Exchange Web Services with native folders and roles.

The fixture verifies that Unified Inbox Threads interleave by date without crossing connection
identity, every row retains its source and reply identity, provider folders remain scoped to their
own connection, and Pins and Outbox counts aggregate product-owned state. A selection spanning the
four full-capability connections exposes only their common read actions; adding reduced POP3 makes
the Provider Mail Action intersection empty. A forced Graph failure proves successful connection
batches remain successful and the failure stays attributed to Graph.

The same scenario verifies that Default Sending Connection selection retains reduced POP3 when it
can send, synchronization status remains connection-scoped, synchronized connection definitions
contain no credentials, tokens, passwords, or body fields, and body-cache and Outbox cleanup for
one connection preserves every other provider's data. Provider-specific suites remain responsible
for transport, authentication, incremental synchronization, role discovery, and delivery behavior.
The shared fixture uses deterministic local metadata and never requires provider credentials or
private mail.

Run the scenario on the required iPhone 17 Simulator target:

```sh
mise exec -- xcodebuild test \
  -project apps/unwired-mail/unwired-mail.xcodeproj \
  -scheme unwired-mail \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -parallel-testing-enabled NO \
  '-only-testing:unwired-mailTests/MailboxConnectionAdapterTests/testProviderRolloutMixedConnectionScenario()'
```

The Release-only performance fixture adds 50 local Inbox Threads for each of these five provider
families. Its mixed-provider aggregation p95 must remain below the accepted 200 millisecond cached
switch budget, and the aggregation loop must not produce a main-thread stall of 100 milliseconds.
See [ADR 0018](../adr/0018-local-mail-performance-budget.md) for the reference-device and hosted-CI
contracts. JMAP remains explicitly deferred.
