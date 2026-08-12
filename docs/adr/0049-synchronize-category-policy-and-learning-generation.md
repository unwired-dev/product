# Synchronize category policy and learning generation

## Status

Accepted.

## Context

Category controls must behave consistently across trusted devices while keeping category names,
configuration, and learning state opaque to the backend. Disabling automatic categorization or a
single category must affect future work without deleting existing message assignments. Resetting
learned senders must also prevent a classification already in flight, or a stale background cache,
from restoring an older learning result.

Historical categorization can be expensive, so Settings must bound each run to an explicit provider
connection, mailbox collection, date range, and optional set of category targets.

## Decision

Store one encrypted, Mail Profile-scoped category-configuration record alongside the existing
encrypted Custom Category records. The configuration contains the global automatic-categorization
switch, disabled System Category identifiers, and a monotonic learning generation with its most
recent reset time. The Default Profile retains the deployed Product Account record scope; other
Profiles use their opaque Profile scope.

Classification reads the configuration before it starts, excludes disabled categories and learning
signals older than the reset time, and verifies the captured learning generation before persisting an
automatic result. Background categorization caches the encrypted configuration snapshot with the
categories and learning signals, and a configuration update invalidates that cache.

Historical categorization accepts the bounded scope through the provider-neutral mailbox capability.
Providers filter the locally observed messages to that scope before classification. Cancellation
stops future work but does not roll back assignments already persisted.

## Consequences

- Policy changes synchronize end to end without exposing plaintext category configuration to Convex.
- Turning categorization or a category off affects future assignments while preserving existing
  Message Categories.
- A learning reset fences stale and in-flight work without deleting category definitions.
- Mailbox providers that do not advertise historical categorization expose no historical controls.
- The configuration record can evolve independently from Custom Category definitions, while both
  retain the same Mail Profile ownership boundary.
