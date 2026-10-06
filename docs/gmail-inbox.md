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
address, subject, Gmail's snippet, received time, unread state and Gmail's label
IDs. Message content is not downloaded. The detail view shows the snippet, the
message's own labels and the [organizing actions](#organizing-mail).

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

If a foreground account check interrupts synchronization and verifies the same
mailbox again, synchronization starts again from its committed cache, at most
twice. Its saved Inbox stays visible. Repeated interruptions make the Inbox
unavailable until **Try again** or the next activation.

## Organizing mail

[#607](https://github.com/unwired-dev/product/issues/607) organizes Gmail mail with
Gmail's label semantics. These are **Provider Mail Actions** for Gmail only; future
IMAP or Microsoft connections need their own actions rather than pretending to match
Gmail's labels.

| Action                            | Gmail change                                     |
| --------------------------------- | ------------------------------------------------ |
| **Mark as read** / **unread**     | Removes or adds `UNREAD`                         |
| **Star** / **Remove star**        | Adds or removes `STARRED`                        |
| **Archive**                       | Removes `INBOX`                                  |
| **Move to Trash**                 | Adds `TRASH`, removes `INBOX`                    |
| **Report spam**                   | Adds `SPAM`, removes `INBOX`                     |
| A label checkbox under **Labels** | Adds or removes that label                       |
| **Move to** a label               | Adds the label, removes `INBOX`, keeps others    |
| **Undo**                          | Reverses the latest archive, move, trash or spam |

The reader has keyboard-focusable action buttons and label checkboxes with visible
focus rings. After a removal, **Undo** appears in the Inbox. VoiceOver also offers read, star, archive, trash and spam as actions on each
Inbox row, and announces each outcome once, however many Mac windows show it. **Labels** lists the mailbox's own labels, read from Gmail once per
synchronization and kept with the cache. Restoring from Trash or Spam is the
**Undo** of the latest removal; browsing Trash, Spam or a label is not part of
this slice.

A change shows at once with **Saving the change on this device…** until local
storage confirms it. It then becomes a durable **Pending Provider Action** before
Gmail is asked. A current Gmail request may finish before the local save completes;
**Saving** remains visible until the change is durable. Gmail's answer replaces
the pending change. Changes are
sent one at a time, in the order they were made, each by Gmail message ID and only
to the mailbox they were made in. A message that leaves the Inbox, from the reader
or its row, closes the reader and shows **Undo** in the Inbox until the next
organizing action. The Inbox states the outcome of every action, such as
**Starred** or **Marked as read**, so it is announced even when the row does not
show it. A change saved while Gmail is still being checked does not
interrupt that check: the synchronization keeps the newly saved changes and goes on.
A change another window or store instance already settled is not sent again.

- **Offline or interrupted:** the change stays saved and is sent on the next
  synchronization, including after relaunch. The Inbox says how many changes wait
  for Gmail while it cannot be reached or needs permission again.
- **Lost response:** synchronization checks Gmail's current labels before another
  attempt. An already-applied change needs no second write. Otherwise the same
  requested labels are retried; repeating an action leaves the same labels.
- **Repeated failure:** automatic synchronization makes at most five dispatch
  attempts per change, with exponential delay and jitter between attempts.
  Unconfirmed changes and later intents stay saved. The status names the action
  and message awaiting confirmation. **Retry change** starts a new
  retry budget; **Discard change** restores Gmail's current state and lets later
  intents continue.
- **Refused:** when the message or label no longer exists in Gmail, the change is
  dropped, the Inbox shows the message as Gmail has it, and an alert names the
  refused change. Later changes still apply. The refusal is saved before Gmail's
  current labels are read, so an interrupted read settles it later without sending
  the refused change again.
- **Changed in Gmail:** label changes made elsewhere arrive through Gmail history.
  A waiting change shows on top of them until Gmail confirms it; Gmail keeps labels
  the change does not name.

While only the saved Inbox opens after a known network outage, nothing can be
saved, so the reader explains that organizing waits until Gmail can be checked.
A change still displaying **Saving…** has not been acknowledged durable; locked
or unavailable storage reports a failure. Unsaved changes are forgotten if the
Inbox changes owner. Same-mailbox verification can renew access without dropping
those changes. **Undo** preserves labels the message already had before a move. Reconnecting Gmail keeps the current mailbox; a different mailbox requires the
explicit account-page chooser. The account page explains that selecting a different mailbox discards changes
still waiting for Gmail. Choosing another mailbox removes the previous mailbox's cache, including
its waiting changes. A cache written before message labels were kept is listed again once, with its messages visible meanwhile; a message offers organizing actions once its labels are read. Previously saved changes still resume in order, including a change saved before those labels were known.

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
- **Gmail could not be reached** after a network failure, quota or rate limit, server
  error or malformed Gmail response. **Try again** resumes from the last commit;
  so does the next activation.

Locked or unreadable storage hides the cached mail, as the
[preview Inbox](private-inbox-storage.md#failure-behavior) does, and offers
**Try again**. Without a connected mailbox, nothing is cached or shown.

## Boundaries

Reselecting a mailbox invalidates synchronization work already in progress,
including when another Google account reuses the same address. Stale work cannot
read from the new mailbox or repopulate its cache.

Gmail tokens and refresh credentials never enter JavaScript or Convex. Each Gmail write changes only the selected message's labels. Message metadata stays on the device and is never uploaded. Logs carry only allow-listed
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
per-message read activity. Every provider mutation first revalidates the Trusted
Device. Unavailable validation sends nothing; a revoked device purges local mail
and credentials. Whether a provider mutation or opening or saving the cache finds
the removal, the Inbox hands over to the account page, which explains
**This device was removed**; it never claims the purged data was kept.
The explanation survives foreground verification while the device stays signed
out. Explicit sign-out clears it, and a concurrent account deletion keeps its own
explanation.

## Deterministic evidence

The shared integration tests drive the real synchronization through a controlled
Gmail API and mailbox cache (`@private-email/mail-core/testing/gmail-mailbox`).
They cover pagination, relaunch with history only, interrupted pages and commits,
expired history, authorization and retry classification, competing stores,
mailbox reselection and log privacy. Organizing tests cover every action's Gmail
labels, changes kept through an outage and relaunch, lost responses, refused and
repeated changes, Undo after Gmail confirmed a trash, labels changed in Gmail,
changes bound to their mailbox, intake during a blocked history read, lost local
save replies, changes saved under each step of a long listing and during action
preparation and settlement, mailbox changes during conflict reopening, preserving labels
on Undo, five-attempt stopping and resolution, revoked access, and the cache
upgrade. Rendered host tests cover the Inbox states, organizing from the reader
and a row with Undo, closing the reader after a row removes its message, a
device found removed reaching the account page's explanation, one announcement
across two Mac windows, the account page round trip and two Mac windows over one
store. Shared registration tests cover queued foreground verification, concurrent
sign-out and deletion after a mailbox removal hand-off.

The hosted native storage suite checks the Gmail path allow-list, the label
change's identifiers and body, query encoding,
cache revision and address rules, ciphertext and removal on reselection and
purge. Registration Mock Mail Sessions answer Gmail requests from a synthetic
mailbox of three Inbox messages over two pages and one label, compiled only into
the selected test build; label changes apply for the rest of that launch. Their
journeys confirm setup, open the synchronized Inbox, star and archive a message
and undo the archive, relaunch from the encrypted cache and return to the account
page.

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
- non-ASCII senders and subjects, as Gmail returns them in metadata headers;
- every organizing action and **Undo**, as seen in Gmail on the web;
- changes made offline, then sent after reconnecting or relaunching;
- a refused change after the label or message is deleted in Gmail.

Do not record mailbox content, addresses or tokens in screenshots, logs or test
artifacts. No real Gmail synchronization pass is claimed until this protected
path has actually run.
