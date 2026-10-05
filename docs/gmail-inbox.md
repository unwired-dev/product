# Gmail Inbox synchronization

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/gmail-inbox.md).

[#604](https://github.com/unwired-dev/product/issues/604) shows the connected
Gmail mailbox's Inbox on iPhone, iPad and Mac. After [registration](google-registration.md)
connects a mailbox and account setup needs nothing more from the person, launch
opens the Inbox. The **Account** button opens the account page, and **Open Inbox**
returns. The account page opens instead while a Recovery Key needs confirming or
entering, a device approval is waiting on either side, the mailbox is not yet
saved to private sync, or a sign-out or deletion is unfinished.

An explicit choice of **Account** stays through status updates. Choosing **Open
Inbox** can leave already-pending setup for later, but different pending setup
that appears afterward, including a renewed device approval code, opens the
account page again. Sign-out, pending removal,
loss of mailbox access or a different Product Account forgets the earlier choice.

## Behavior

The Inbox lists **Durable Message Metadata** for Gmail's `INBOX` label: sender,
address, subject, Gmail's snippet, received time and unread state. Message content
is not downloaded. The detail view shows the snippet and offers no read toggle,
because read state belongs to Gmail and organizing mail is a later slice.

A first synchronization reads the mailbox's current history ID, then lists the
Inbox newest first, 50 messages per page. Each page is shown as soon as it is
committed, so the newest 50 are usable before the rest arrive (**Initial Mailbox
Availability**). The device keeps the newest 200 Inbox messages; older ones stay
in Gmail. **Historical Metadata Backfill** of the complete mailbox is not part of
this slice.

Later synchronizations read Gmail history from the committed history ID and apply
arrivals, deletions, archiving and read changes. If Gmail no longer has that
history, the Inbox is listed again; the cached messages stay visible meanwhile,
and messages that left the Inbox are removed when the new listing completes.
Synchronization runs when the Inbox opens and whenever the app becomes active.
Push and background refresh are later slices.

A rejected saved listing token starts a fresh listing. When a full cache loses an
entry, a fresh listing admits the next older Inbox message. Unreadable cache
documents are preserved and reported as unavailable rather than replaced.

Every step commits its messages together with the checkpoint that resumes after
them. An interruption repeats at most the uncommitted step, and changes are
applied by Gmail message ID, so nothing is lost or duplicated. Two windows or
store instances cannot overwrite each other's newer commit; the later one starts
again from the committed cache.

## Mailbox Sync Status

The cached list stays visible while Gmail work proceeds. A known network outage
during relaunch opens only the last verified mailbox's saved Inbox. No provider
read or cache update runs until registration verifies again. The account page
calls this **Saved Gmail Inbox**, rather than claiming verified Gmail access.
**Try again** verifies registration before resuming synchronization. Rejected
grants, identity mismatches, unknown failures and pending removals cannot use
this cache-only path.

The Inbox reports:

- **Checking Gmail…** while synchronizing. An empty cache shows a progress
  indicator instead of an empty Inbox.
- **Gmail needs your permission again** after Gmail refuses the mailbox's grant.
  **Allow Gmail access** runs Gmail authorization for the same mailbox and
  synchronizes again.
- **Gmail could not be reached** after a network failure, rate limit, server
  error or malformed Gmail response. **Try again** resumes from the last commit;
  so does the next activation.

Locked or unreadable storage hides the cached mail, as the
[preview Inbox](private-inbox-storage.md#failure-behavior) does, and offers
**Try again**. Without a connected mailbox, nothing is cached or shown.

## Boundaries

Reselecting a mailbox invalidates synchronization work already in progress,
including when another Google account reuses the same address. Stale work cannot
read from the new mailbox or repopulate its cache.

Gmail tokens and refresh credentials never enter JavaScript or Convex. Message
metadata stays on the device and is never uploaded. Logs carry only allow-listed
codes, HTTP statuses and failing decode paths, never mail content or addresses.

Choosing another mailbox, or another Google account that reuses the same address,
removes the previous mailbox's cache and hides its in-memory list while the
selected mailbox opens. A synchronization that loses mailbox ownership stops and
clears its displayed mail. Sign-out, deletion and a removal by another device
remove the cache with the rest of the account's data. Mail held in memory is
forgotten as soon as the open Inbox changes Product Account, Google account or
address, or closes, so another account never renders it, even from a
synchronization that was still running.

Gmail reads do not ask Convex about this device. The removal check runs when a
synchronization opens or commits the cache, so the backend learns nothing about
per-message mail activity.

## Deterministic evidence

The shared integration tests drive the real synchronization through a controlled
Gmail API and mailbox cache (`@private-email/mail-core/testing/gmail-mailbox`).
They cover pagination, relaunch with history only, interrupted pages and commits,
expired history, authorization and retry classification, competing stores,
mailbox reselection and log privacy. Rendered host tests cover the Inbox states,
the account page round trip and two Mac windows over one store.

The hosted native storage suite checks the Gmail path allow-list, query encoding,
cache revision and address rules, ciphertext and removal on reselection and
purge. Registration Mock Mail Sessions answer Gmail reads from a fixed synthetic
mailbox of three Inbox messages over two pages, compiled only into the selected
test build. Their journeys confirm setup, open the synchronized Inbox, relaunch
from the encrypted cache and return to the account page.

```sh
mise exec -- pnpm exec turbo run lint format check-types test --filter=// \
  --filter=@private-email/mobile... --filter=@private-email/macos...
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

For packaged journeys, select `registration-declined` with the
[native Mock Mail Session commands](mock-mail-sessions.md).

## Protected Gmail qualification

These checks are deterministic application evidence, not real Gmail evidence. With
the [protected Gmail test tenant](gmail-provider-test-tenant.md) and signed hosts,
verify on iPhone, iPad and Mac before release:

- the first listing of a large Inbox, with the newest 50 usable first;
- arrival, archive, delete and read changes made in Gmail after relaunch;
- recovery after Gmail expires the stored history ID;
- a revoked grant reaching **Gmail needs your permission again**, then recovering;
- offline launch from the encrypted cache, and rate-limit handling;
- non-ASCII senders and subjects, as Gmail returns them in metadata headers.

Do not record mailbox content, addresses or tokens in screenshots, logs or test
artifacts. No real Gmail synchronization pass is claimed until this protected
path has actually run.
