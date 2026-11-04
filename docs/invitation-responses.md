# Invitation Responses

[#1640](https://github.com/unwired-dev/product/issues/1640), a slice of
[#1277](https://github.com/unwired-dev/product/issues/1277), lets the Mac reader
send an [Invitation Response](domain/organization.md) to a single Gmail meeting
invitation, and [#1815](https://github.com/unwired-dev/product/issues/1815) brings
the same card to the iPhone and iPad reader. Microsoft, IMAP, Add to Calendar
([#1280](https://github.com/unwired-dev/product/issues/1280)) and organizer
updates ([#1281](https://github.com/unwired-dev/product/issues/1281)) follow
separately.

## Behavior

- An opened Gmail message whose `text/calendar` part (or, without one, its
  `application/ics` part; up to 256 KiB) is an
  iCalendar `METHOD:REQUEST` with exactly one meeting shows an invitation card
  above the message body: the organizer, title, **When** in this device's time zone,
  **Where**, **Organizer** and **Invited**. The end comes from `DTEND` or
  `DURATION`. The calendar attachment stays listed
  below the body.
- The card offers **Accept**, **Maybe** and **Decline** only when the invitation
  names the opened mailbox's address as an attendee. Nothing is sent until the
  person chooses. For any other attendee list it says **You can’t respond from
  here** and names the invited addresses.
- Choosing a response sends one iCalendar `METHOD:REPLY` from the invited
  address to the organizer, in the invitation's Gmail thread, as a reply to the
  invitation message, with the invitation's subject prefixed `Re:` so Gmail keeps
  it in that conversation. The reply carries the event's UID, SEQUENCE and organizer,
  and the attendee line with only its participation status changed. A second
  press while sending, or the same choice after Gmail confirmed it, sends
  nothing. Choosing another response sends that one.
- After Gmail confirms, the card says **Accepted**, **Tentatively accepted** or
  **Declined** with the confirmation time, and the chosen button shows a check.
- When Gmail refuses the message the card says **Not sent** and the buttons
  stay available. Offline, it says **You’re offline** and keeps nothing to send
  later. When Gmail needs a new sign-in it says so with **Sign In…**.
- When Gmail may have sent the response but did not confirm it, the card says
  **Delivery unknown** and never sends it again on its own. **Check Again** looks
  for the message in Gmail's Sent; **Respond Again…** asks first, because a second
  response could reach the organizer.
- Responses survive relaunch
  ([#1642](https://github.com/unwired-dev/product/issues/1642)). Before sending,
  the response is recorded in the mailbox's encrypted cache, which the Apple host
  stores and removes on this device: the invitation's UID and SEQUENCE, the choice,
  and the MIME boundary that finds it in Sent, plus the confirmation time once
  Gmail confirms. After relaunch a confirmed response shows its choice and time,
  and choosing it again sends nothing. A response the app quit while sending shows
  **Delivery unknown**, as above. When the record cannot be saved, nothing is sent
  and the card says **Not sent**, or keeps **Delivery unknown** after **Respond
  Again…**. The host removes records with the mailbox when
  it is removed, on sign-out and with the account; a refused or offline response
  leaves the earlier record. If saving Gmail's confirmation fails, relaunch
  restores **Delivery unknown**; **Check Again** can confirm it without sending
  another response.
- Recurring meetings, cancellations, floating or unknown time zones, a timed
  meeting whose `DURATION` counts days, and damaged calendar text show **Unwired can’t read this invitation**, with no response.

## Limitations

- Bodies cached before this change open without the card until the cache is
  refreshed.
- A missing or temporarily unavailable calendar part leaves the message readable
  without the card; a later open retries temporary failures. A rejected Gmail
  grant still asks for sign-in. A storage lock, removed mailbox or stale mailbox
  generation keeps that body unavailable.
- The card does not show the organizer's own time zone, and the chosen button
  does not show a spinner while sending; the status row does.

## iPhone and iPad

- The card follows the iPhone and iPad frames: Subheadline rows in a quiet card
  (18pt corners on iPhone, 10pt on iPad), and native capsule **Accept**, **Maybe** and **Decline** buttons in one row;
  the chosen one takes the accent fill. With larger text each value moves below its
  label, and from the first accessibility size the buttons stack at full width.
- **Respond Again…** asks in the system alert, with **Respond Again** and
  **Cancel**. Closing the message dismisses the alert without sending.
- VoiceOver hears each status change once, since iOS ignores live regions.

## Validation

- `packages/mail-core/test/invitations.test.ts` parses invitations and drives
  responses through a synthetic Gmail mailbox, including lost and refused sends,
  a send the app quit during, and restore after relaunch and mailbox removal.
- `apps/macos/test/invitation.test.tsx` and `apps/mobile/test/invitation.test.tsx`
  render each reader with a synthetic Gmail mailbox; they are component tests, not
  native evidence.
- Native Mac, iPhone and iPad evidence and a real Gmail organizer receiving the
  response remain required before release.
