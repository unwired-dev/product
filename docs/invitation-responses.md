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
- When the invitation also names another mailbox address of the same Mail
  Profile, **Invited** lists each of the Profile's invited addresses with its
  provider, the opened mailbox first. Until a response is chosen the status
  reads **Responding as {address}**: **You’re invited at two of your addresses.
  This copy responds only for {address}.** At three or more addresses the
  detail gives the count, such as **You’re invited at 3 of your addresses.**
  Each copy responds only from its own mailbox, and another Profile's addresses
  are never listed.
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
  the meeting's start and end, the Gmail message that carried the revision
  ([#1852](https://github.com/unwired-dev/product/issues/1852)), and the MIME
  boundary that finds it in Sent, plus the confirmation time once
  Gmail confirms. After relaunch a confirmed response shows its choice and time,
  and choosing it again sends nothing. A response the app quit while sending shows
  **Delivery unknown**, as above. When the record cannot be saved, nothing is sent
  and the card says **Not sent**, or keeps **Delivery unknown** after **Respond
  Again…**. The host removes records with the mailbox when
  it is removed, on sign-out and with the account; a refused or offline response
  leaves the earlier record. If saving Gmail's confirmation fails, relaunch
  restores **Delivery unknown**; **Check Again** can confirm it without sending
  another response.
- A revision that moved the meeting after a confirmed response
  ([#1834](https://github.com/unwired-dev/product/issues/1834)) shows an
  **Updated** badge, **Was** and the earlier time under **When**, and
  **{organizer} changed the time** with **You accepted the earlier time. Respond
  to the new time.** (or tentatively accepted, declined). No choice is selected,
  since the earlier answer was for the old time; after a response the card shows
  it and keeps the badge and the earlier time. This status takes the place of
  **Responding as**; **Invited** still lists every invited address. The card takes the highest earlier
  SEQUENCE this device answered for the opened address and shows the update only
  when that answer was confirmed and its start or end differs. An unknown delivery
  there, or a record saved before #1834 without a time, shows the plain unanswered
  card rather than an older answer that may no longer stand. A revision that
  changes only other details is unchanged.
- An older revision ([#1851](https://github.com/unwired-dev/product/issues/1851)),
  opened after this device recorded a response (confirmed or delivery unknown) to a
  higher SEQUENCE of the same meeting for the opened address, shows an **Older
  version** badge, **When** and **Organizer** without **Invited**, and **There’s a
  newer version of this invitation** with **Respond from the latest invitation so
  your answer matches it.** It offers no response, and a choice made on a card
  shown before the newer response was recorded sends nothing. A newer revision
  this device never answered does not mark the opened one as older.
- **Show Latest** ([#1852](https://github.com/unwired-dev/product/issues/1852)) on
  an older revision opens the message carrying the newest revision this device
  answered in the reader, in the same mailbox; an open Mac composer stays open
  over it. The button is absent when the reader cannot show that message, because
  Gmail deleted it or it left the Inbox and every opened view and search result,
  or when the response was recorded before #1852 without its message.
- A `METHOD:CANCEL` for one meeting
  ([#1826](https://github.com/unwired-dev/product/issues/1826)) shows the same
  details under **Cancelled by** the organizer, with a **Cancelled** badge, the
  title struck through and **This meeting was cancelled**. It offers no response,
  so it shows whether or not it names the opened mailbox as an attendee. Its
  `STATUS`, when present, must be `CANCELLED`.
- A weekly series ([#1836](https://github.com/unwired-dev/product/issues/1836))
  shows **When** as the weekday and times, such as **Fridays, 14:00–15:00**, then
  **Every week from 6 Nov to 18 Dec 2026**. If the meetings span local days or a
  clock change makes their local weekdays, start times or end times differ,
  **When** names the first meeting's date and times instead, retaining the series
  line. The unanswered card says **Your
  response applies to every meeting in the series.** The response is the same single
  `METHOD:REPLY` without a `RECURRENCE-ID`, so it answers every meeting. A cancellation
  of the whole series shows the same lines. The series must be a timed meeting with
  one `RRULE` of `FREQ=WEEKLY`, an `INTERVAL` of 1 if any, a `BYDAY` naming only the
  start's weekday if any, an optional `WKST`, and exactly one of a UTC `UNTIL` or a
  `COUNT`, and at most 9999 meetings. The last meeting is counted in the meeting's time zone, so it
  keeps its local time across daylight-saving changes.
- One meeting of a series ([#1847](https://github.com/unwired-dev/product/issues/1847)),
  sent alone with its `RECURRENCE-ID`, reads **Invitation from {organizer} · one
  meeting**, shows that meeting's date and times with **One meeting in a series**
  below, and the unanswered card says **Your response applies only to {date}.**
  The reply repeats the `RECURRENCE-ID`, in UTC for a timed meeting so it needs no
  `VTIMEZONE`, so it answers that meeting only, and its
  response is recorded apart from the series' and other meetings'. A cancellation or
  an invitation for another address of that meeting shows the same line. The
  invitation carries no rule, so the card does not say how the series repeats. The
  `RECURRENCE-ID` must be the only one, without a `RANGE`, the same timed or all-day
  type as the start and in a readable time zone, with no `RRULE`, `RDATE` or `EXDATE`.
- Other recurring meetings, a range of a series' meetings (`RANGE`), series
  with `RDATE` or `EXDATE`, all-day series, floating or unknown time zones,
  a timed meeting whose `DURATION` counts days, and damaged calendar text show
  **Unwired can’t read this invitation**, with no response.

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
  a send the app quit during, restore after relaunch and mailbox removal, a
  revision that moved the meeting after an earlier answer, and the message an
  older revision's **Show Latest** opens.
- `apps/macos/test/invitation.test.tsx` and `apps/mobile/test/invitation.test.tsx`
  render each reader with a synthetic Gmail mailbox; they are component tests, not
  native evidence.
- Native Mac, iPhone and iPad evidence and a real Gmail organizer receiving the
  response remain required before release.
