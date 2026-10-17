# Separate encrypted Mail Profile ownership from legacy records

## Status

Accepted.

## Replacement staging amendment — 2026-10-11

The foundation in [#644](https://github.com/unwired-dev/product/issues/644)
adds explicit ownership only to the decoded TypeScript `MailboxConnection`.
An absent `profile` decodes as `defaultProfile = 'default'`, unique within one
Product Account. It leaves native registration storage, synchronized mailbox
descriptors, credentials, encrypted records and all existing identifiers intact.
The Default Profile uses the existing Product Account record scope.

The implementation decision panel (`claude-fable-5-1`, `gpt-6.1-sol`,
`gpt-6-astra`) unanimously chose this staged projection over adding an optional
ownership field to native connections and synchronized descriptors now. With
multiple-Profile creation unavailable, ownership is deterministically Default;
changing descriptor epoch/removal reconciliation to persist that same answer
adds migration risk without useful behavior. The panel also unanimously chose
the account-local `default` sentinel over a Product Account digest.

Reading/search callers migrate in #645 and Drafts/delivery/notifications in #646.
Synchronized connection-to-Profile assignments and incompatible-client fencing
arrive with #647 before multiple-Profile creation is enabled. This amendment
supersedes the deterministic digest identity and first-load assignment write
below only for the replacement foundation. The dedicated encrypted ownership
record and lifecycle behavior below describe the retained Swift prototype; this
slice neither implements nor selects the replacement's multi-Profile protocol.

## Replacement connection-bound routing amendment — 2026-10-17

Issue [#921](https://github.com/unwired-dev/product/issues/921) applies the
synchronized connection ownership introduced by #920 to Draft presentation and
Mail Assistance. For connection-bound Drafts, assets, delivery claims, schedules
and push routes, retain the existing opaque transport address across a connection
transfer. Resolve their logical owner through the connection's current encrypted
assignment. This qualifies the new-Profile namespace rule below for these
connection-bound records; Profile-wide configuration keeps its separate scope.

The implementation decision panel (`claude-fable-5-1`, `gpt-6.1-sol`,
`gpt-6-astra`) unanimously chose immutable addresses over moving records and
aliasing claims. Readdressing a claim could authorize a second delivery, while
connection ownership can change without moving ciphertext or exposing readable
Profile state to Convex. Synchronization, delivery and content-free push wakes
remain account-wide, including inactive and temporarily quarantined connections.
Presentation hides quarantined connections' Drafts and Outbox entries.

The same panel unanimously selected one device-local Mail Assistance switch per
Profile in Account Settings, rather than tying the Profile-less Mac Settings
window to a mail window. A Draft uses its sender connection's current Profile
consent. Moving that connection retires captured assistance even when both
Profiles have consent. App creation, switching, restored-window and incompatible
client fences remain #922 work; this amendment is not native or live-provider
qualification. Additional Settings rows require the design workflow before app
enablement exposes them.

## Context

Mail Profiles must partition Mailbox Connections and product-owned state inside one Product Account. Existing Product Sync records were deployed before Profiles and use Product Account-scoped identifiers. Moving or copying those records during the foundation migration would create duplication, partial-migration, rollback, and mixed-version risks. Embedding Profile ownership in the existing Mailbox Connection payload would also let an older client erase ownership fields when it rewrites the legacy schema.

Provider credentials are device-local Mailbox Authorizations and must remain outside Product Sync.

## Decision

Store Profile definitions, explicit Mailbox Connection assignments, and Profile-field conflict copies in a dedicated `mail-profiles-primary` typed Product Sync singleton. The payload is encrypted through the existing record boundary; the backend sees only opaque ciphertext and the stable payload identifier.

Derive one opaque Default Profile identity deterministically from the Product Account identity. On first Profile-aware load, create that Profile and assign every active unassigned Mailbox Connection to it. Reconciliation is idempotent: it retains assignments while a connection is absent from the current payload, removes them only after an explicit connection-removal tombstone, rejects duplicate or dangling assignments, and assigns connections created by an older client to the Default Profile on the next load.

The Default Profile keeps a legacy Product Account record scope. Existing Categories, Mail Views, workflow preferences, notification rules, sending identities, product-owned organization, automation, and return-to-attention records therefore remain at their deployed encrypted identifiers and become Default Profile-owned without being copied or reset. New Profiles use an opaque Profile namespace for future Profile-owned records.

Profile-aware connection queries require a `MailProfileId` and fail closed for an unknown Profile. Profile edits compare each changed field with the caller's base value: non-overlapping changes merge, while a same-field divergence preserves the competing value as an explicit conflict copy. Wall clocks and upload order do not select a winner.

## Consequences

- A legacy client can continue updating Mailbox Connections without deleting Profile definitions or assignments because ownership is a separate encrypted record.
- The migration is rollback-safe: disabling the Profile feature leaves all legacy product-owned records and provider credentials in their original locations.
- A connection added by a legacy client is temporarily visible only through legacy paths; the next Profile reconciliation assigns it to the Default Profile before Profile-scoped presentation.
- A temporarily absent connection retains its prior Profile ownership when it returns. An explicit removal tombstone deletes that ownership, so a later recreation is assigned to the Default Profile.
- Retained ownership remains inside the encrypted Profile record; provider credentials remain device-local and outside the Profile privacy boundary.
- Profile lifecycle, atomic connection transfer, window selection, device-local Profile Lock, and complete Settings integration remain separate child work built on this ownership record.
- Product Sync exports can include the encrypted Profile record and ownership relationships without provider credentials or plaintext mail.
