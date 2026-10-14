# Mail Commitments

Status: confirmed post-launch requirements from the interview started 2026-10-13.
The user confirmed the complete feature brief. This note records agreed product
requirements, not implementation or release qualification. The confirmed
[power-user launch scope](power-user-launch.md) remains unchanged.

[Vocabulary](../domain/organization.md) · [Domain index](../../GLOSSARY.md)

## Purpose

Help an individual managing personal and work mail keep track of commitments
that get lost across conversations. The feature tracks both actions the user
owes and outcomes the user is waiting for, including obligations beyond replying.
For example, a response saying "Thanks" does not establish that a requested
contract was delivered.

A Mail Commitment is distinct from a Follow-Up Nudge. The existing nudge revisits
a sent Thread and is cancelled by an eligible newly observed reply; a commitment
represents the outstanding action or outcome.

## Ownership and availability

- Each Mail Commitment belongs to one Mail Profile. Its commitment list spans
  that Profile's Mailbox Connections; Work and Personal remain separate.
- Commitments synchronize through encrypted Private Sync across trusted devices.
  Already-synchronized commitments remain usable offline.
- The mail app owns the initial commitment list and completion controls.
  Apple Reminders and other external task-manager integrations are later work.
- Acceptance and dismissal decisions synchronize privately across trusted devices.
  Unaccepted model suggestions remain device-local. Scans respect prior decisions
  and propose updating or linking existing commitments instead of repeatedly
  asking about the same obligation.

Commitment acceptance and state changes are private product actions. They do not
send mail, communicate agreement to a sender, or change provider mail state.

Apple native code owns keys, credentials, encrypted storage and physical purge.
Shared TypeScript owns scan/review orchestration, owner/revision checks, in-memory
invalidation and Private Sync reconciliation, without replacing native checks.
Keep the existing [storage](../private-inbox-storage.md) and
[Private Sync](../private-product-sync.md#keys-and-envelopes) ownership boundaries.

## Record and lifecycle

- Each commitment has an editable title, an I owe or Waiting for direction, an
  optional due date, and one or more source-message links. Manual creation starts
  from mail.
- States are Open, Done and Cancelled. Completion, cancellation and reopening
  require an explicit user action.
- New mail may suggest completion, a changed deadline or linking an existing
  commitment. It never silently changes accepted state or user edits. Any reply
  alone is insufficient evidence that the outstanding obligation was fulfilled.
- Independent edits from different devices combine. Competing edits to the same
  value are preserved and surfaced for review; a stale device or scan cannot
  silently reopen a completed commitment.
- If offline devices accept the same matching creation proposal before learning
  each other's decisions, synchronization converges deterministically to one
  logical commitment within its owning Profile, regardless of delivery order or
  retries. Combine independent authored edits and preserve competing values for
  review; do not silently discard either device's work. Existing routes resolve
  to that logical item, and completion and deletion authority remain intact.
  Distinct obligations, fresh update proposals and separately authored manual
  commitments do not coalesce merely because they share correspondence.
  Routes and reminder references created before convergence use the logical
  item's current state and owning Profile. Reconcile known obsolete reminders;
  convergence cannot silently reopen Done/Cancelled state or keep a duplicate
  or conflict copy alive after explicit Delete.
- Done and Cancelled retain history. Explicit Delete removes the record's content
  and reminders across trusted devices through synchronization. Deletion wins
  over concurrent or stale edits to that record: edits, scans and retries cannot
  restore it or materialize its deleted content as a conflict copy when devices
  synchronize. Only a minimal
  encrypted review decision remains to prevent repeated suggestions from the
  same reviewed source; Profile/account deletion removes that decision too.

## Date recognition

- On-device AI recognizes natural-language date phrases such as "tomorrow" and
  "next week". Mail phrases use their source message's date and time zone when
  known; manually typed phrases use today's date in the user's selected zone.
  Missing source-zone assumptions are shown for confirmation.
- For a new manual deadline, the editor initially proposes this device's current time zone,
  shown and editable before confirmation. Store the confirmed zone with that
  commitment's deadline and synchronize it privately; it is not a Profile or
  device preference. Use that zone for subsequent interpretation and date-only
  overdue evaluation. Travel or another device never changes it automatically;
  changing it requires an explicit deadline edit.
- Clear phrases propose an absolute date directly. Vague phrases show a range or
  possible interpretations, letting the user choose a deadline or leave it unset.
- Acceptance resolves a relative phrase to a fixed calendar date or precise
  instant. "Tomorrow" never rolls forward on reopening. Travel does not silently
  change the intended deadline; timed values show their zone, and date-only
  deadlines use a visible chosen zone for overdue evaluation.

Recognition stays within the feature's on-device privacy and review requirements.

## Reminders

Reminders are optional per commitment at a user-chosen time. They use the Profile's
[Return-to-Attention](../domain/privacy-and-sync.md) preference and respect Quiet
State, Quiet Hours, Profile Lock, system notification authorization and device-local
lock-screen content policy. Content is generic and private by default. Detecting a
suggestion does not itself create an interruption.

Confirm each reminder as a fixed absolute instant with a visible interpretation
and display zone. A new reminder initially proposes the creating device's current
zone, editable before confirmation. Keep the confirmed instant and zone with that
reminder through encrypted Private Sync; they are independent of the deadline's
zone and are not a Profile or device preference. Travel, a different notification
owner, a Profile move or Reopen never automatically shifts or rebases the chosen
instant or zone. Changing that intent requires an explicit reminder edit; a
deadline edit does not silently recalculate it.

Reminders use the Profile's notification-owning Trusted Device to avoid duplicate
interruptions. Missed or suppressed reminders remain visible in the app; exact-time
delivery is not promised. A commitment is overdue because its deadline passed,
not because an earlier reminder was missed.

Locally scheduled reminders may work offline. Completion or cancellation on
another device reaches the reminder owner only after synchronization, so an
outdated alert may still appear. Opening it shows current available state and
never reopens a completed commitment.

When a device observes Done or Cancelled, retire its known scheduled reminder
work and fence late delivery for that closed state. Retain the chosen reminder
time as history. Explicit Reopen restores only a still-current configured chosen
reminder whose time remains future, under
current ownership and interruption/privacy controls with a current revision;
it never revives obsolete closed-state work, a removed reminder or a superseded
historical time. Explicit reminder edits/removal and Delete remain authoritative
when they race with close/reopen. A past reminder time remains visible
as missed/history without an immediate catch-up alert; another interruption then
requires a new user-chosen time. The same rule applies when reopening arrives
through synchronization, including after the old time has passed.

## Automatic scanning

- Scanning starts automatically when informed On-Device Mail Assistance consent
  and the commitment scan switch are both on.
  Assistance retains its default-off, device-local consent. A separate
  device-local, per-Profile Settings switch disables commitment scanning without
  making saved commitments unavailable.
- The first informed assistance enablement explains automatic analysis of new
  local received and sent mail; confirming that scope initializes the scan switch
  to On unless an explicit scan-Off choice is already saved. An already-enabled
  Profile whose earlier consent did not cover this
  feature keeps its existing assistance usable, but its commitment scan switch
  starts Off. It requires a one-time, explicit confirmation of the new scope on
  that device and Profile before scanning starts. Declining keeps commitment
  scanning off. Preserve an explicit scan-Off choice across upgrades instead of
  resetting it to the initial default. Turning all assistance off cancels active
  commitment scans, rejects their late results and clears proposals, not the saved
  scan choice. Turning assistance back on preserves that choice. With saved scan
  On and current informed consent, scanning starts with new eligible mail from
  that re-enable boundary; mail received during master Off requires an explicit
  bounded historical scan and is never silently backfilled. Saved scan Off keeps
  commitment scanning disabled. This deliberate Off interval is distinct from
  system/model interruptions that permit eligible catch-up.
- Confirmation starts scanning with new mail from then. Mail received before
  confirmation requires a bounded explicit historical scan; upgrading or
  confirming consent never silently backfills that interval.
- New received and sent mail is scanned automatically from enablement onward.
  Scanning older correspondence is a separate explicit request bounded by a
  user-selected date range or mailbox.
- Eligible mail spans normal folders and connections of the Profile, excluding
  Spam, Trash and unsent Drafts/Outbox. Newly downloaded historical mail does not
  become new mail merely because it reached the device. Receipts and automated
  confirmations may provide evidence that an awaited outcome occurred.
- Analysis uses already-downloaded message text on the device. It does not fetch
  missing message bodies or analyze attachments solely for this scan. The app
  discloses incomplete coverage.
- Detection produces source-linked Mail Commitment Suggestions. The user accepts,
  edits or dismisses each suggestion before it can enter the active commitment
  list. A request in received mail does not itself establish an accepted obligation.
- Scanning catches up eligible mail after system/model interruptions when the
  client can run. Catch-up cannot cross a later deliberate Off boundary or revive
  cleared proposals or cancelled pre-Off work. Deliberately disabling the automatic scan cancels active scans
  and rejects late results. Re-enabling starts with new mail from then; the
  disabled period requires an explicit historical scan.

This planned scan is a separately accepted exception to per-Thread invocation.
It does not authorize broader inputs for existing
[assistance operations](assistance.md).

## Manual creation

Users can add and edit Mail Commitments directly when scanning is disabled,
unavailable or misses an item. Inference is not required to use the commitment list.

## Review queue

- A separate review queue within Mail Commitments shows editable proposals,
  original date phrases, interpreted dates and source links. Suggestions remain
  outside the active commitment list until accepted.
- Open commitments form the main list. Done and Cancelled remain accessible in
  history.
- Minimal unaccepted proposals survive relaunch in encrypted device-local storage,
  with source links rather than copied message bodies. Disabling automatic
  scanning keeps the existing queue; disabling all assistance clears unaccepted
  suggestions. Profile Lock preserves and hides the encrypted saved queue, cancels
  active scans and rejects their late results, including results arriving after
  unlock. Unlock does not resume pre-lock work; any new scan requires current
  consent, scan enablement and source ownership.
- Known source-text changes or source deletion retire unaccepted suggestions.
  Ordinary body-cache eviction marks evidence unavailable rather than deleting
  accepted commitments. Locally available evidence is required before accepting
  a model suggestion; manual creation remains available from mail.
- Applying a synchronized acceptance, dismissal or deletion decision retires any
  matching proposal already queued on this device, including an open review.
  Acceptance retires the proposal instead of permitting another record. Availability
  covers the accepted creation or update outcome, not merely the target record's
  existence. If its accepted revision or changes have not arrived, show synchronization
  as pending even when an earlier target revision is already available; do not
  present older title, deadline, reminder or other values as the accepted current
  changes. Available last-known state may remain visible with that pending status.
  Link to the accepted outcome only when it is available in this Profile.
  Current authoritative state may incorporate, supersede or resolve those accepted
  changes; availability does not require restoring a superseded revision. Pending
  synchronization preserves an existing usable target and never overrides known
  Delete or owner loss, current lifecycle state, conflicting edits or reminder
  revision authority.
  Never expose content or a link to a commitment owned by another Profile. If the
  corresponding record for this Profile has
  not arrived yet, show its synchronization as pending; do not keep the proposal
  actionable while waiting. Dismissal or deletion removes the matching proposal
  without creating another commitment. Unrelated proposals remain usable.
- Match the reviewed obligation and proposal through its reviewed source identities
  and, for an update or link, its target commitment. Sharing a Thread, source
  message or target alone does not make a different obligation or proposed change
  a matching copy. Acceptance of creation does not suppress a fresh proposal to
  update or link that commitment; the fresh proposal still requires review and
  current source/target evidence. Deletion suppression and Profile-move decision
  ownership retain their separate lifecycle rules.
- Before showing, accepting or publishing a proposal, reconcile all locally known
  review decisions and current target state. A concurrent decision invalidates
  stale acceptance and late inference results; they cannot restore the retired
  proposal or overwrite accepted work. Offline devices can act only on known
  state and apply the same retirement when synchronization delivers the decision.

## Source removal and Profile moves

- Accepted commitments survive source-message deletion and Mailbox Connection
  removal. Their reviewed title, direction, state, dates and configured reminders remain, with unavailable source
  links. Suggestions and cached source content belonging to the removed
  connection are purged. Mailbox removal alone therefore does not erase accepted
  commitment text.
- Before confirming Mailbox Connection removal, disclose that any reviewed
  commitment title, direction, state, dates and configured reminders remain in the mail app
  and Private Sync, while the connection's suggestions and cached source content
  are purged and its source links become unavailable. Use wording that honors
  Profile Lock without revealing protected titles or other retained content. Explain the existing
  explicit Delete action for commitment content/reminders and its minimal retained
  review decision; owning Profile/account deletion also removes review decisions.
- Removing the owning Mail Profile or Product Account deletes its commitments
  and minimal review decisions. Each observing device also cancels affected
  scans, rejects late results and purges that owner's encrypted review queue,
  unaccepted proposal text/source links and device-local scan state. Deletion
  applies when a device observes it; retries, relaunch or later unlock cannot restore the
  removed owner's proposals or scan work. Profile deletion applies only to that
  Profile; Product Account deletion applies to every Profile owned by that account.
  Unrelated Profiles and accounts retain their state. Recreating an owner does not
  restore its deleted queue, scan state or earlier scanning permission.
- Commitments belonging solely to a moving connection follow it to the target
  Profile. Mixed-source commitments require the user to choose one owning Profile
  and review affected links. Preserve one record, without cross-Profile source
  access or silent copies.
- When a commitment changes owning Profile, preserve its configured reminder
  time and reassign reminder work to the new Profile's notification-owning Trusted
  Device. Reconcile known obsolete source-Profile alerts before admitting target
  delivery, which uses the target Profile's Return-to-Attention, Quiet State,
  Quiet Hours, Profile Lock and other reminder controls. This applies to both
  sole-source moves and reviewed mixed-source ownership changes; a cancelled move
  retains its prior reminder ownership and schedule. Devices reconcile when they
  observe the move, subject to the existing offline reminder limitation.
- When a move takes effect, retire every unaccepted proposal involving the moving
  connection, including mixed-source proposals. Fence its old-Profile scans and
  reject late results; do not transfer model output to the target queue.
- Minimal encrypted acceptance, dismissal and deletion decisions follow their
  reviewed source identities to the connection's current Profile. Partition
  mixed-source suppression decisions by current ownership, retaining no foreign
  source links or authored content. Preserve authoritative deletion fences and
  the reviewed accepted-record ownership; suppression never exposes a commitment
  retained in another Profile.
- Publish ownership, queue invalidation, decision reassignment and reminder
  ownership/schedule reconciliation as one move
  outcome before admitting target scans or proposal acceptance. Each device
  applies that outcome when it observes the move; interruption, retry or stale
  work cannot expose old-Profile sources, lose suppression or resurrect deleted
  records. A cancelled move retains its prior ownership and queue.
- Target scans require that device and Profile's informed assistance consent and
  enabled scan switch. Moving mail neither enables consent nor turns existing
  history into new mail; reconsidering retired proposals requires an explicit
  bounded historical scan under target consent.

## Delivery and qualification

Deliver verifiable slices after the confirmed launch:

1. Manual records, lifecycle and Private Sync.
2. Automatic suggestions and on-device date recognition.
3. Reminders and full lifecycle integration.

A manual-only milestone does not complete the agreed automatic feature. The full
feature needs evidence on iPhone, iPad and Mac for the accepted workflows,
including offline edits, conflicting changes, source removal, Profile moves and
consent controls. Validate real on-device recognition on eligible hardware;
manual fallback remains available elsewhere. Documentation, synthetic results
and compiled bindings do not establish that qualification.

Representative acceptance scenarios:

- Confirm a reminder in a visible chosen zone, then synchronize to a different-zone
  owner, travel, move Profiles and close/reopen before or after its instant. Preserve
  the confirmed instant and zone, apply current ownership/controls and past-time
  rules, and change reminder intent only through an explicit edit. Include clock
  and daylight-saving boundaries without promising exact-time delivery.

- Accept an update while another device already has its earlier target revision.
  Deliver the review decision before or after the accepted changes. The receiving
  device retires its matching proposal and shows pending synchronization until
  the accepted outcome arrives, without presenting older values as that outcome.
  Repeat with concurrent local edits, completion/Delete, retry and reordered sync;
  preserve authored work and lifecycle authority.

- With informed consent and saved scan On, turn master Assistance Off while mail
  arrives, then re-enable it. Start automatic scanning with new eligible mail
  from re-enable, require explicit bounded review of the Off interval and reject
  pre-Off late results; repeat with saved scan Off and involuntary interruptions.
- Retain both I owe and Waiting for commitments after source deletion and mailbox
  removal. Preserve their directions separately from lifecycle state and include
  direction in generic pre-removal disclosure without exposing locked content.

- Track both an owed action and an awaited outcome across two Mailbox Connections
  in one Profile. Review/accept on one device and respect that decision on another.
- Queue matching proposals on two devices before either is reviewed. Acceptance,
  dismissal or deletion on one device retires the other's matching queue entry
  when its decision arrives, including during an open review or pending scan;
  delayed accepted-record delivery never makes the stale proposal actionable.
- Accept the same matching creation proposal on two offline devices and edit each
  resulting record. Reconnect in either order and retry synchronization: retain
  one logical commitment, combine independent changes, preserve competing values
  for review, and retain completion/deletion authority and stable routing.
  Repeat with one record Done, Cancelled or deleted before reconnect, and with
  old reminder/route references; enforce current state, ownership and deletion
  without duplicate interruptions or resurrection.
- Remove a Mailbox Connection with accepted commitments. The confirmation explains
  retained authored state and how to delete it, while protected content remains
  hidden under Profile Lock; completed removal preserves the disclosed records
  and makes their source links unavailable.
- Move a commitment with a configured reminder between Profiles with different
  notification owners and privacy controls. Observing devices retire obsolete
  source-Profile alerts and reconcile target delivery under its controls, retaining
  the chosen reminder time. Repeat for a reviewed mixed-source move, cancelled
  move, offline owner, retry and interruption; taps use current available ownership
  without duplicate known alerts or protected-content exposure.
- Close a commitment before its reminder time and observe the change on its
  notification owner. Retire known scheduled work and fence late delivery; then
  explicitly reopen before or after the chosen time, including delayed sync.
  Restore only a still-future reminder under current controls, keep past times
  visible without an immediate catch-up alert and never revive obsolete work.
- A Tuesday message saying "tomorrow" scanned on Friday proposes Wednesday in
  the reviewed source zone. "Next week" shows its ambiguity. Accepted dates remain
  fixed after relaunch or travel.
- A reply saying "Thanks" never silently completes "Send the contract". A changed
  deadline remains a proposal until accepted.
- Combine independent offline edits, surface competing edits, and prevent stale
  work from reopening a Done item.
- Stop scans and reject late results after disablement; preserve accepted records,
  enforce queue-clearing/locking rules and disclose unavailable local evidence.
- Preserve reviewed records after mailbox removal while purging its suggestions
  and source content; enforce chosen ownership and source isolation on Profile
  moves; remove all related records and review decisions on Profile/account deletion.
  With a saved queue and active or interrupted scan, verify that observing owner
  deletion purges proposals and local scan state and rejects late results,
  including after relaunch, unlock, retry or owner recreation. Apply Profile-only
  versus all-account-Profile scope, reject prior scanning permission and preserve
  owners outside the deleted scope.
- Show missed reminders and handle an offline stale alert without changing the
  commitment's accepted state or exposing private content against notification
  preferences.
