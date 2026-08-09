# Scheduled Send and Send Reminder implementation plan

Status: planned

## Goal

Let a person choose a future time from any new-message, reply, reply-all, or forward composer and either commit the message for automatic delivery or keep it as a Draft with a reminder. Automatic delivery remains private, works across compatible trusted devices, prevents duplicate provider submissions, and makes only a best-effort at-or-after timing promise.

## Product contract

| Choice | Domain state | Delivery authority | Offline creation | Completion |
| --- | --- | --- | --- | --- |
| Send automatically | Scheduled Send in Outbox | Exactly one eligible trusted device | No; admission fails closed | Sent, cancelled to Draft, or Needs Attention |
| Remind me to send | Send Reminder attached to Draft | None | Yes; cross-device sync may remain pending | Opened, rescheduled, sent, or discarded |

Both choices ship together and support every send-capable Mailbox Connection through product-owned scheduling. Receive-only connections do not offer automatic scheduling. The product never delegates selectively to provider-native scheduling and never changes the selected sending connection without explicit user action.

Scheduled Send means delivery at or after one absolute future instant, not exact-time delivery. The allowed range is one minute through one year. A delivery that cannot begin within 24 hours becomes Needs Attention and requires Send Now, reschedule, edit, or cancel.

## Architecture

```text
Composer
  ├─ Remind me to send
  │    └─ encrypted Draft + reminder revision
  │         ├─ local notification when created offline
  │         └─ one routed notification after synchronization
  └─ Send automatically
       └─ encrypted Outbox manifest + payload/assets
            ├─ Product Sync: content, connection, schedule, idempotency
            └─ operational schedule: opaque id, due time, revision, claim
                 └─ eligible trusted device
                      └─ Undo Send → provider handoff → reconciliation
```

The Apple client owns content validation, encryption, local storage, provider credentials, MIME delivery, provider reconciliation, and visible state. Product Sync carries opaque encrypted manifests and chunks. The backend owns only due-time wake routing, compatible-device authorization, revision fencing, claim transitions, notification ownership, and bounded cleanup.

### Encrypted synchronized record

Add a versioned Scheduled Send record family and chunk families through the existing Product Sync boundary. The encrypted manifest contains:

- opaque Scheduled Send identity and current revision;
- absolute delivery instant plus the originally selected time-zone identifier for display;
- selected Stable Provider Connection Key and Mailbox Connection identity;
- exact validated recipients, subject, headers, rendered HTML and plain-text alternatives, deterministic RFC Message-ID, and delivery idempotency key;
- ordered references, byte counts, hashes, and encryption metadata for rendered MIME and authored assets;
- creation and last-edit instants;
- user-visible state needed by Outbox;
- the Draft tombstone or restoration transition associated with admission, cancellation, or conversion.

No value in this manifest is readable by the backend. Encoded chunks remain below Convex's 1 MB value limit. Asset chunks are content-addressed within the encrypted record family so Draft, reminder, and scheduled transitions retain references instead of copying bytes.

### Operational schedule record

Add a backend-readable operational record containing only:

- Product Account and opaque schedule identity;
- absolute due time and 24-hour automatic-delivery deadline;
- expected encrypted-record revision;
- scheduled wake identifier;
- inactive or active admission state;
- claim owner, claim generation, claim phase, and timestamps;
- compatible device-authorization generation;
- terminal or cleanup state without message outcome details.

The record must not contain the sending connection, provider, sender, recipients, subject, body, asset metadata, message size, or provider result. It is removed after confirmed delivery, cancellation, conversion to reminder, or Product Account deletion. Bounded tombstone data may remain only as long as necessary to reject a stale claim or replayed mutation.

Send Reminder uses a separate backend-readable notification schedule containing only the Product Account, opaque reminder identity, due time, expected encrypted reminder revision, notification owner and ownership generation, delivery phase, and ownership timestamps. It excludes Draft content, assets, the selected Mailbox Connection, and provider credentials. Synchronization prepares this record and assigns notification ownership before the originating device cancels its redundant local notification. The owner then durably records that cancellation and activates the prepared schedule through compare-and-swap against the same reminder revision and ownership generation. A crash before cancellation leaves local delivery authoritative; a crash after cancellation resumes activation from the durable handoff state. Retries first read both states and may only cancel or activate the recorded generation, so they converge to one active owner. Opening, cancelling, rescheduling, or deleting the reminder advances its revision and clears stale notification ownership. Signing out, device revocation, or loss of notification capability also invalidates that owner's prepared or active generation; another compatible device may then claim ownership through compare-and-swap with a higher generation.

### Scheduled Delivery Authorization

Introduce a revocable device-bound authorization layered on the existing Trusted Device Credential. It permits a compatible device to:

- register its scheduling capability and notification route;
- read opaque due work for its Product Account;
- acquire or release a pre-handoff claim;
- advance a claim to provider-handoff fencing;
- report only opaque completion or Needs Attention state;
- revalidate device trust without interactive Sign in with Apple.

It never contains or grants access to a Mailbox Authorization. The Apple client separately proves that it holds local authorization for the encrypted selected Mailbox Connection before claiming. Device revocation invalidates this authorization and every unstarted claim owned by that device.

## Admission protocol

Automatic scheduling is an idempotent, crash-recoverable admission protocol rather than one cross-system transaction:

1. Validate recipients, selected sending connection, message content, complete assets, transfer-encoded size, schedule range, and local storage.
2. Resolve the selected wall-clock value and time zone to one valid absolute instant. Reject nonexistent DST values and distinguish repeated values by time-zone abbreviation or UTC offset.
3. Reserve the necessary bytes in the Outgoing Content Store and render the exact outgoing payload.
4. Write encrypted chunks, then commit the encrypted manifest through Product Sync compare-and-swap.
5. Register the opaque operational schedule in the inactive admission state with the same identity, due time, and expected revision. Inactive schedules cannot be claimed or wake a device for delivery.
6. Re-read both records to prove that their identities and revisions agree.
7. Only then write the synchronized Draft tombstone.
8. Activate the operational schedule through compare-and-swap against that tombstone and expected revision, then dismiss the composer and present the Scheduled state.

Until step 7 commits, the Draft remains authoritative and the schedule is unclaimable. Until step 8 commits, the schedule is not presented as accepted. A failure or uncertain response triggers reconciliation by idempotency key. A proven orphaned operational record is cancelled; a proven tombstoned Draft with matching complete records resumes activation. The client must never guess that admission completed.

Send Reminder admission is local-first: save the Draft and reminder revision atomically, schedule a local notification, and mark Product Sync as pending. Synchronization prepares the opaque reminder notification schedule for one owner generation without making it deliverable. The originating device then cancels its local notification, durably records that cancellation, and activates backend notification ownership through compare-and-swap for that exact revision and generation. Recovery retries the incomplete prepare, cancellation, or activation step from the durable handoff state; it never activates a new generation while an earlier local notification remains authoritative. Offline creation remains visibly pending for cross-device availability.

## Claim and delivery protocol

1. The backend schedules an opaque background wake at the due time and rejects claims before that instant or after the 24-hour deadline.
2. A woken or foreground-compatible device decrypts the record, verifies complete local bytes, confirms the exact revision, and checks local Mailbox Authorization.
3. The device acquires the Scheduled Send Claim using the expected revision and its Scheduled Delivery Authorization.
4. The claim enters a pre-handoff phase. The ordinary configured Undo Send Window begins, and cancellation, edit, reschedule, or Send Now may still win through compare-and-swap.
5. Immediately before provider access, the device rechecks Product Account state, connection generation, Scheduled Delivery Authorization generation, Trusted Device Credential revocation state, record revision, payload hashes, deadline, and claim ownership. A revoked credential or stale authorization generation rejects the claim before provider access.
6. Advancing the claim to handing-off creates a durable fence. No timeout or second device may cross that fence until the provider outcome is reconciled.
7. Existing provider delivery and Outgoing Delivery Attempt reconciliation rules execute with the stored idempotency key and deterministic Message-ID. Every credential-bearing provider request requires HTTPS, and every redirect is accepted only after revalidating an HTTPS same-origin destination; credentials are withheld from the redirected hop until that validation succeeds. EWS retains its explicit endpoint and redirect checks, while Graph and Gmail must use redirect-aware sessions that enforce the same rule instead of shared-session default redirect handling. Connections remain serialized; different Mailbox Connections may deliver concurrently.
8. Confirmed success removes the operational schedule and synchronized Outbox commitment while provider synchronization supplies the Sent message. A transient failure follows the existing retry policy. An ambiguous SMTP response requires explicit reconciliation or user resolution and never automatic cross-device takeover.

An abandoned pre-handoff claim may expire and be claimed by another eligible device. Due work is ordered per Mailbox Connection by delivery instant, commitment instant, then stable opaque identity.

## Editing and state transitions

- Scheduled items remain editable and cancellable until handoff fencing begins.
- Opening an item for editing first acquires a synchronized edit fence through compare-and-swap against the current revision and pre-handoff claim state. Editable UI appears only after the fence commits; a handing-off item or losing editor remains read-only. Saving retains the delivery instant when it remains in the future.
- If the instant passes while the composer is open, the user must choose Send Now or a new future time.
- Every edit, reschedule, sender change, or Send Now action creates a new encrypted revision and delivery idempotency key.
- The first valid edit, reschedule, cancellation, conversion, or claim wins. A losing editor reloads and may preserve its unsaved content only as a new Draft.
- Cancel Scheduled Send removes the commitment and restores an editable Draft. Discard is a separate destructive action.
- Scheduled Send to Send Reminder restores a Draft and attaches one reminder. Send Reminder to Scheduled Send requires the full online admission protocol.
- Send Now makes the new revision immediately eligible and still honors Undo Send.
- No transition silently changes the selected Mailbox Connection.

## User experience

Tapping Send continues to send immediately. Pressing and holding Send opens the shared Send Later sheet. VoiceOver exposes Send Later as an explicit action, and hardware keyboards receive a documented shortcut.

The sheet offers:

- Later today: three hours ahead, rounded up to the next half-hour, hidden after 21:00 or whenever that result is not on the current local calendar day;
- Tomorrow morning: 08:00 in the current local time zone;
- Next Monday morning: 08:00 on the next Monday in the current local time zone;
- Pick Date & Time;
- Send automatically;
- Remind me to send.

The selected local value is saved as an absolute instant and does not move after travel or a later time-zone change. The UI retains the original zone for explanatory display when useful.

The conditional Outbox groups items as Scheduled, Sending, and Needs Attention. Scheduled rows show the intended instant and selected sending connection. If Background App Refresh is disabled, authorization is missing, or no compatible sending device exists, scheduling remains available only when admission can complete and the UI explains that delivery may wait until the app runs.

Send Reminder routes one visible notification to the most recently active notification-capable compatible device. Opening it marks that reminder revision complete, clears its notification everywhere, and presents the Draft. The user may send, edit, discard, or choose a new reminder time. If notification delivery is unavailable, Drafts still shows the reminder as overdue. Device-local lock-screen content preferences control how much message information a notification reveals.

Notify when a Scheduled Send is delayed, becomes Needs Attention, or permanently fails. Do not notify on successful delivery by default; the Sent Mailbox is authoritative confirmation.

## Storage

Replace the Draft-only storage boundary with one separately encrypted, non-evicting 100 MB Outgoing Content Store per device. Drafts, Send Reminders, Scheduled Sends, semantic documents, rendered payloads, attachments, and inline images share that limit and remain separate from the Bounded Encrypted Body Cache.

A state transition retains shared chunks and releases them only after no Draft, reminder, Scheduled Send, conflicted Draft, or deferred provider cleanup references them. A device that cannot admit a synchronized payload may show encrypted metadata-derived availability state but cannot acquire its delivery claim. Admission requires at least one compatible authorized device with a complete verified payload.

## Account and connection lifecycle

- Remove Device Authorization clears local bytes, local notifications, capability registration, and unstarted claims for that device without cancelling synchronized items.
- Device revocation rejects future claims and releases only pre-handoff claims. A handing-off claim remains fenced for reconciliation.
- Removing a Mailbox Connection everywhere lists and confirms cancellation of its Scheduled Sends before deleting their operational schedules. It retains the durable encrypted connection-removal tombstone and authorization-generation floor across later re-creation so stale credentials and legacy writes remain fenced.
- Deleting the Product Account lists and confirms cancellation of every Scheduled Send and Send Reminder, drains claim cleanup, and includes operational schedules in bounded backend deletion.
- Signing out one device preserves synchronized items. If it is the last eligible sending device, affected Scheduled Sends become or remain visibly at risk and eventually Needs Attention.
- Connection merging transfers scheduled commitments under the existing winning Stable Provider Connection Key and fences loser revisions before delivery resumes.

## Compatibility

Scheduled Send uses additive encrypted record families. Older clients ignore them and cannot display, edit, cancel, claim, or notify for their items. A new client may create a schedule when at least one compatible trusted device has the selected Mailbox Authorization and a complete payload; upgrading every trusted device is not required.

Draft admission and cancellation tombstones remain authoritative to older clients. An older client's offline edit may become a conflicted Draft but must never recreate a cancelled or delivered Scheduled Send. New clients show which trusted devices are compatible and eligible without exposing provider identities to the backend.

## Delivery phases

### 1. Durable outgoing-content foundation

- Implement the currently planned persistent Draft store and Semantic Message Document path.
- Generalize its quota and asset ownership into the Outgoing Content Store.
- Add chunk reuse, reservations, reference counting, integrity verification, and crash recovery.
- Verify with Swift Testing that Draft save, conflict copies, quota exhaustion, transitions, and restart recovery never lose authored content.

### 2. Synchronized Scheduled Send model

- Add encrypted manifest, payload, asset, reminder, and tombstone record families.
- Add revisioned admission, edit, cancel, conversion, and restore-to-Draft operations.
- Materialize Scheduled, Sending, and Needs Attention views locally.
- Verify Product Sync compare-and-swap conflicts, missing chunks, old-client edits, connection merging, and key rotation.

### 3. Operational scheduling and authorization

- Add the minimal operational schedule schema, scheduled wake actions, cleanup, and Product Account deletion coverage.
- Add Scheduled Delivery Authorization issuance, capability registration, revocation, and compatibility checks.
- Add pre-handoff claims, handing-off fences, deadlines, notification ownership, and idempotent reconciliation APIs.
- Verify that backend storage and logs never contain message content, provider identity, sending connection, or provider credentials.

### 4. Apple background coordinator

- Integrate Outbox work with background task registration and opaque remote wakes instead of only foreground AccountView resume.
- Extract delivery construction from UI/session state so a background entry point can build the provider adapter safely.
- Implement nearest-due scheduling, claim acquisition, Undo Send, handoff fencing, provider reconciliation, late-work handling, and resubmission.
- Verify force-quit, disabled Background App Refresh, first-unlock key availability, expired foreground identity, offline provider, device revocation, and ambiguous SMTP outcomes.

### 5. Composer, Outbox, and reminders

- Add the Send Later interaction, accessible actions, presets, date/time picker, and two modes to every composer flow.
- Add Outbox grouping, editing, cancellation, conversion, Send Now, warnings, and Needs Attention recovery.
- Add local-first reminders, notification routing, overdue Draft presentation, and rescheduling.
- Verify VoiceOver, hardware keyboard, compact and regular layouts, macOS behavior, DST boundaries, travel, notification permissions, and lock-screen privacy.

### 6. Lifecycle, compatibility, and end-to-end evidence

- Integrate account deletion, sign-out, device authorization removal, device revocation, connection removal, and connection merge.
- Add old-client fixtures and stale-revision/replayed-claim attacks.
- Extend the Local Mail Test Environment with scheduled success, late wake, cancellation race, transient retry, permanent failure, and ambiguous SMTP scenarios.
- Run Apple lint, focused Swift Testing suites, Convex lint/typecheck/tests, Core Mail Loop coverage, and provider compatibility checks for every send-capable adapter.

## Acceptance criteria

- No provider handoff occurs before the selected instant or before the configured Undo Send Window ends.
- Exactly one provider submission can cross the handoff fence for one revision.
- A restart, wake on another device, edit, cancel, conversion, or Send Now cannot duplicate or lose the commitment.
- Automatic scheduling is not acknowledged while its encrypted payload or operational registration is incomplete or uncertain.
- The backend cannot read message content, recipients, subject, provider identity, selected connection, or credentials.
- A compatible authorized device can deliver without interactive sign-in when Apple grants execution.
- Delivery more than 24 hours late requires user action.
- Cancelling restores a Draft; reminders never deliver automatically.
- Every composer flow and send-capable Mailbox Connection follows the same behavior.
- Account, device, and connection lifecycle operations leave no orphaned claim, wake, notification, encrypted payload, or provider draft.
- Older clients cannot resurrect a cancelled or delivered commitment.
- All required lint, format, typecheck, unit, integration, mail-harness, and provider-compatibility checks pass.

## Non-goals

- Exact-time delivery guarantees
- Recurring schedules
- AI-selected or recipient-availability send times
- Provider-native scheduled-send delegation
- Backend-held mailbox credentials or backend mail delivery
- Provider recall after handoff

## Decisions

- [ADR 0001: End-to-end encrypted Product Sync](adr/0001-end-to-end-encrypted-product-sync.md)
- [ADR 0002: Device-held provider tokens with a push relay](adr/0002-device-held-mail-provider-tokens-with-push-relay.md)
- [ADR 0010: Device-local Mailbox Authorization](adr/0010-device-local-mailbox-authorization.md)
- [ADR 0013: Best-effort device-side mail freshness](adr/0013-best-effort-device-side-mail-freshness.md)
- [ADR 0016: Durable Outbox delivery attempts](adr/0016-durable-outbox-delivery-attempts.md)
- [ADR 0025: Semantic rich-text Drafts with encrypted assets](adr/0025-use-semantic-rich-text-drafts-with-encrypted-assets.md)
- [ADR 0046: Coordinate private Scheduled Send on trusted devices](adr/0046-coordinate-private-scheduled-send-on-trusted-devices.md)
