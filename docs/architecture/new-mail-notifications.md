# New Mail Notifications: architecture notes

Reviewer-only companion to [the operational guide](../new-mail-notifications.md),
under the [implementation and review workflow](../agents/implementation-review.md).
Issue #619 implements ADR 0063's Gmail slice. IMAP/Microsoft expansion remains
#1094, Quiet/Profile Lock #648, filtering #853 and presentation expansion #908.

## Policy and execution

The Mail Profile program lists a separate `mailbox-notifications.` family beside
definitions and ownership. Native code derives its immutable opaque address from
the mailbox descriptor's record identifier and seals account, identifier, schema
and key-epoch bindings through the existing ring. The authenticated value retains
the descriptor record, connection epoch, write version and enabled boolean.
TypeScript owns compare-and-set, merging and saved version floors. Recreation
does not inherit an earlier incarnation's enablement. The capability fence still
applies to Profile definitions/ownership; adding this preference does not expose
multiple-Profile creation or introduce a second fence.

Gmail history supplies unread Inbox `messagesAdded` candidates. The encrypted
mailbox document retains `notificationHistoryId` independently of the shared
checkpoint, which interrupted label listings may rewind. History considers only
additions beyond that boundary and commits its maximum with the metadata before
reporting arrivals. Rebase retains the greater saved boundary. Older caches seed
it before opening a view. Listing, backfill, expired-history relisting and moved
messages produce no arrival. Notifications remain best effort; this does not add
a transactional notification-center delivery journal.

The host awaits settings and posting before completing a synchronization/wake.
TypeScript rechecks the captured account/connection/address/epoch owner and switch
after settings. Native posting validates the explicit opaque Product Account and
connection epoch inside the registration gate. Prepared preview content additionally
requires the current device-local preview choice. Preview changes use that gate,
so an acknowledged opt-out fences queued previews and cannot interleave a batch.
The same notification identifier may alert again after delivery under Apple's
[request contract](<https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:)>);
the persisted history boundary supplies replay suppression.

## Routing and cleanup

The system payload contains opaque account, connection, epoch and message IDs.
The shared tap coordinator checks that scope, awaits the existing composer leave
guard and checks scope again. Native readers have per-follow identities, so
cleanup cannot cancel a newer reader for the same window. A tap delivered to a
retired reader returns to the native queue. Mac targeted entry resolves the
connection's current Profile and remounts its existing Profile scope with the
target selection; this adds no Profile creation or restoration preference.

The native registration store invokes a host-supplied withdrawal callback at
account purge, session end and connection removal, including revocation found
inside mailbox preflight. Cleanup therefore does not depend on an exported
bridge wrapper being the entry point. The callback defaults to no-op in package
tests; both production and synthetic host stores install the system adapter.

Builds, deterministic core/host tests and real native delivery are separate
evidence. Notification permission, preview withdrawal, cold taps, revoked-account
cleanup and Draft exit interaction on all three version-27 hosts remain required
native release qualification.
