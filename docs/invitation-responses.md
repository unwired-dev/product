# Invitation Responses

[#1640](https://github.com/unwired-dev/product/issues/1640), a slice of
[#1277](https://github.com/unwired-dev/product/issues/1277), lets the Mac reader
send an [Invitation Response](domain/organization.md) to a single Gmail meeting
invitation. iPhone, iPad, Microsoft, IMAP, Add to Calendar
([#1280](https://github.com/unwired-dev/product/issues/1280)) and organizer
updates ([#1281](https://github.com/unwired-dev/product/issues/1281)) follow
separately.

## Behavior

- An opened Gmail message whose `text/calendar` part (up to 256 KiB) is an
  iCalendar `METHOD:REQUEST` with exactly one meeting shows an invitation card
  above the message body: the organizer, title, **When** in this Mac's time zone,
  **Where**, **Organizer** and **Invited**. The calendar attachment stays listed
  below the body.
- The card offers **Accept**, **Maybe** and **Decline** only when the invitation
  names the opened mailbox's address as an attendee. Nothing is sent until the
  person chooses. For any other attendee list it says **You can’t respond from
  here** and names the invited addresses.
- Choosing a response sends one iCalendar `METHOD:REPLY` from the invited
  address to the organizer, in the invitation's Gmail thread, as a reply to the
  invitation message. The reply carries the event's UID, SEQUENCE and organizer,
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
- Recurring meetings, cancellations, floating or unknown time zones and damaged
  calendar text show **Unwired can’t read this invitation**, with no response.

## Limitations

- A response's state lasts while the app runs; after relaunch the card shows
  **Not answered yet** again. Gmail's Sent keeps the sent response.
- Bodies cached before this change open without the card until the cache is
  refreshed.
- If the calendar part cannot be fetched, the message stays readable without
  the card. A rejected Gmail grant still asks for sign-in.
- The card does not show the organizer's own time zone, and the chosen button
  does not show a spinner while sending; the status row does.

## Validation

- `packages/mail-core/test/invitations.test.ts` parses invitations and drives
  responses through a synthetic Gmail mailbox, including lost and refused sends.
- `apps/macos/test/invitation.test.tsx` renders the reader with a synthetic Gmail
  mailbox; it is a component test, not native evidence.
- Native Mac evidence and a real Gmail organizer receiving the response remain
  required before release.
