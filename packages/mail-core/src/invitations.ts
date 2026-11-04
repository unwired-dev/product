import * as DateTime from 'effect/DateTime';
import * as Option from 'effect/Option';

import type { Draft, Recipient } from './draft-model.ts';
import type { GmailInbox, SendOutcome } from './gmail-inbox.ts';
import type { InvitationResponse } from './mailbox-document.ts';
import type { BodyDocument } from './message-body.ts';

import { listedMessage } from './gmail-inbox.ts';
import { boundaryOf, outgoingMessage } from './outgoing-message.ts';

// The response a person chooses for a meeting invitation, as its iCalendar participation status.
export type InvitationChoice = 'accepted' | 'tentative' | 'declined';

// An event time as an instant; an all-day date is its UTC midnight.
export type InvitationTime = Readonly<{ at: number; allDay: boolean }>;

export type InvitationDetails = Readonly<{
  summary?: string;
  start: InvitationTime;
  end?: InvitationTime;
  location?: string;
  organizer: Recipient;
}>;

// One iCalendar content line: its name, its raw parameters and its value.
type Line = Readonly<{
  name: string;
  parameters: readonly string[];
  value: string;
}>;

// A single-meeting invitation addressed to the owning mailbox, with what its reply repeats.
export type Invitation = Readonly<{
  kind: 'invited';
  details: InvitationDetails;
  // The owning mailbox's address, which the invitation names as an attendee.
  address: string;
  uid: string;
  sequence: number;
  // The received message it answers and its Message-ID header, for threading.
  message: string;
  messageId?: string;
  lines: Readonly<{ organizer: Line; attendee: Line; summary?: Line }>;
}>;

// What a received message's calendar part offers: nothing, a response the owning mailbox can
// send, a meeting that names only other addresses, or an invitation Unwired cannot read.
export type InvitationOffer =
  | Invitation
  | Readonly<{
      kind: 'elsewhere';
      details: InvitationDetails;
      invited: readonly string[];
    }>
  | Readonly<{ kind: 'unreadable' }>;

const unreadable = { kind: 'unreadable' } as const;

// Unfolded content lines; a parameter value may quote `;`, `:` and `,`. Parameter names are
// tokens and unquoted values hold no comma, so no alternatives overlap and a damaged line
// fails in linear time.
const contentLines = (text: string): readonly Line[] | undefined => {
  const lines: Line[] = [];
  for (const raw of text
    .replaceAll(/\r?\n[ \t]/gu, '')
    .trimEnd()
    .split(/\r?\n/u)) {
    const match =
      /^(?<name>[A-Za-z0-9-]+)(?<parameters>(?:;[A-Za-z0-9-]+=(?:"[^"]*"|[^:";,]*)(?:,(?:"[^"]*"|[^:";,]*))*)*):(?<value>.*)$/u.exec(
        raw,
      );
    if (match === null || raw.includes('\r') || raw.includes('\0')) {
      return undefined;
    }
    lines.push({
      name: (match[1] ?? '').toUpperCase(),
      parameters: Array.from(
        (match[2] ?? '').matchAll(/;(?<parameter>[^";]*(?:"[^"]*"[^";]*)*)/gu),
        (parameter) => parameter[1] ?? '',
      ),
      value: match[3] ?? '',
    });
  }
  return lines;
};

const parameterOf = (line: Line, name: string) => {
  const found = line.parameters.find((parameter) =>
    parameter.toUpperCase().startsWith(`${name}=`),
  );
  return found?.slice(name.length + 1).replaceAll(/^"|"$/gu, '');
};

const text = (value: string) =>
  value.replaceAll(/\\(?<escaped>[\\;,nN])/gu, (_, escaped: string) =>
    escaped.toLowerCase() === 'n' ? '\n' : escaped,
  );

const addressOf = (line: Line) => {
  const match =
    /^mailto:(?<address>[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+)$/iu.exec(
      line.value.trim(),
    );
  return match?.[1];
};

const recipientOf = (line: Line): Recipient | undefined => {
  const address = addressOf(line);
  const name = parameterOf(line, 'CN');
  if (address === undefined) {
    return undefined;
  }
  return name === undefined || name === '' ? { address } : { name, address };
};

// A DATE-TIME in the IANA zone `zone`, or undefined for a missing or unknown zone.
const zonedTime = (
  naive: number,
  zone: string | undefined,
): InvitationTime | undefined => {
  if (zone === undefined) {
    return undefined;
  }
  return DateTime.zoneMakeNamed(zone).pipe(
    Option.flatMap((timeZone) =>
      DateTime.makeZoned(naive, { timeZone, adjustForTimeZone: true }),
    ),
    Option.map((time) => ({ at: DateTime.toEpochMillis(time), allDay: false })),
    Option.getOrUndefined,
  );
};

const dateTime =
  /^(?<year>\d{4})(?<month>\d{2})(?<day>\d{2})(?:T(?<hour>\d{2})(?<minute>\d{2})(?<second>\d{2})(?<utc>Z?))?$/u;

const sameDate = (date: Date, parts: readonly number[]) =>
  [
    date.getUTCFullYear(),
    date.getUTCMonth(),
    date.getUTCDate(),
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
  ].every((part, index) => part === parts[index]);

// DATE must be declared; a TZID belongs only to a local DATE-TIME.
const supportedTime = (line: Line, allDay: boolean, utc: boolean) => {
  const value = parameterOf(line, 'VALUE')?.toUpperCase();
  const hasZone = parameterOf(line, 'TZID') !== undefined;
  if (allDay) {
    return value === 'DATE' && !hasZone;
  }
  return (value === undefined || value === 'DATE-TIME') && !(hasZone && utc);
};

// A DATE, a UTC DATE-TIME or a DATE-TIME in an IANA zone; floating and unknown-zone times are
// unreadable.
const timeOf = (line: Line | undefined): InvitationTime | undefined => {
  const match = dateTime.exec(line?.value.trim() ?? '');
  if (line === undefined || match === null) {
    return undefined;
  }
  const [, year, month, day, hour, minute, second, utc] = match;
  const [y = 0, mo = 1, d = 1, h = 0, mi = 0, se = 0] = [
    year,
    month,
    day,
    hour,
    minute,
    second,
  ].map((field) => Number(field ?? 0));
  const naive = Date.UTC(y, mo - 1, d, h, mi, se);
  if (
    !sameDate(new Date(naive), [y, mo - 1, d, h, mi, se]) ||
    !supportedTime(line, hour === undefined, utc === 'Z')
  ) {
    return undefined;
  }
  return hour === undefined || utc === 'Z'
    ? { at: naive, allDay: hour === undefined }
    : zonedTime(naive, parameterOf(line, 'TZID'));
};

const recurring = new Set(['RRULE', 'RDATE', 'EXDATE', 'RECURRENCE-ID']);

// Each property line's calendar or top-level component scope, and how many top-level events the
// calendar has. Deeper components cannot supply meeting properties.
const scoped = (lines: readonly Line[]) => {
  const stack: string[] = [];
  // Advance only through matching components in one outer calendar.
  const advance = (line: Line) => {
    if (line.name === 'BEGIN') {
      if (stack.length === 0 && line.value.toUpperCase() !== 'VCALENDAR') {
        return false;
      }
      stack.push(line.value.trim().toUpperCase());
      return true;
    }
    if (line.name === 'END') {
      return stack.pop() === line.value.trim().toUpperCase();
    }
    return stack.length > 0;
  };
  const properties: Array<{ path: readonly string[]; line: Line }> = [];
  const components: Array<readonly string[]> = [];
  for (const line of lines) {
    if (!advance(line)) {
      return undefined;
    }
    const path = stack.length <= 2 ? [...stack] : [];
    if (line.name === 'BEGIN') {
      components.push(path);
    } else if (line.name !== 'END') {
      properties.push({ path, line });
    }
  }
  return stack.length === 0 &&
    components.filter((path) => path.length === 1).length === 1
    ? {
        properties,
        events: components.filter((path) => path[1] === 'VEVENT').length,
      }
    : undefined;
};

// The single top-level event of a `METHOD:REQUEST` calendar, or undefined for anything else.
const requestedEvent = (lines: readonly Line[] | undefined) => {
  const calendar = lines === undefined ? undefined : scoped(lines);
  if (calendar === undefined) {
    return undefined;
  }
  const { properties, events } = calendar;
  const methods = properties
    .filter(({ path, line }) => path.length === 1 && line.name === 'METHOD')
    .map(({ line }) => line.value.trim().toUpperCase());
  const versions = properties.filter(
    ({ path, line }) => path.length === 1 && line.name === 'VERSION',
  );
  return methods.join(',') === 'REQUEST' &&
    events === 1 &&
    versions.length === 1 &&
    versions[0]?.line.value === '2.0'
    ? properties
        .filter(({ path }) => path[1] === 'VEVENT')
        .map(({ line }) => line)
    : undefined;
};

const find = (event: readonly Line[], name: string) =>
  event.find((line) => line.name === name);

// A non-negative SEQUENCE, 0 when absent.
const sequenceOf = (event: readonly Line[]) => {
  const value = find(event, 'SEQUENCE')?.value.trim() ?? '0';
  const sequence = Number(value);
  return /^\d+$/u.test(value) && Number.isSafeInteger(sequence)
    ? sequence
    : undefined;
};

// The ORGANIZER line and its recipient.
const organizerOf = (event: readonly Line[]) => {
  const line = find(event, 'ORGANIZER');
  const recipient = line === undefined ? undefined : recipientOf(line);
  return recipient === undefined || line === undefined
    ? undefined
    : { line, recipient };
};

const second = 1000;
const day = 24 * 60 * 60 * second;

// An all-day meeting lasts whole weeks or days; a timed one only hours, minutes and seconds,
// whose length doesn't change across a daylight-saving shift.
const durations = {
  allDay: {
    pattern: /^\+?P(?:(?<weeks>\d+)W|(?<days>\d+)D)$/u,
    units: [7 * day, day],
  },
  timed: {
    pattern:
      /^\+?PT(?:(?<hours>\d+)H)?(?:(?<minutes>\d+)M)?(?:(?<seconds>\d+)S)?$/u,
    units: [60 * 60 * second, 60 * second, second],
  },
};

// The end a DURATION gives `start`.
const durationEnd = (
  line: Line,
  start: InvitationTime,
): InvitationTime | undefined => {
  const { pattern, units } = start.allDay ? durations.allDay : durations.timed;
  const match = pattern.exec(line.value.trim());
  return match === null
    ? undefined
    : DateTime.make(
        units.reduce(
          (at, unit, index) => at + Number(match[index + 1] ?? 0) * unit,
          start.at,
        ),
      ).pipe(
        Option.map((end) => ({
          at: DateTime.toEpochMillis(end),
          allDay: start.allDay,
        })),
        Option.getOrUndefined,
      );
};

// The meeting's end from DTEND or DURATION, never both; `null` when it has neither.
const endOf = (
  event: readonly Line[],
  start: InvitationTime,
): InvitationTime | null | undefined => {
  const dtend = find(event, 'DTEND');
  const length = find(event, 'DURATION');
  if (dtend === undefined && length === undefined) {
    return null;
  }
  if (dtend !== undefined && length !== undefined) {
    return undefined;
  }
  const end = length === undefined ? timeOf(dtend) : durationEnd(length, start);
  return end === undefined || end.allDay !== start.allDay || end.at <= start.at
    ? undefined
    : end;
};

const detailsOf = (
  event: readonly Line[],
  start: InvitationTime,
  organizer: Recipient,
): InvitationDetails | undefined => {
  const end = endOf(event, start);
  if (end === undefined) {
    return undefined;
  }
  const summary = find(event, 'SUMMARY');
  const location = find(event, 'LOCATION');
  return {
    ...(summary === undefined ? {} : { summary: text(summary.value) }),
    start,
    ...(end === null ? {} : { end }),
    ...(location === undefined ? {} : { location: text(location.value) }),
    organizer,
  };
};

// A single meeting's identity and details; a recurring meeting or one missing its UID, organizer
// or start is unreadable.
const meetingOf = (event: readonly Line[]) => {
  const uid = find(event, 'UID')?.value.trim() ?? '';
  const organizer = organizerOf(event);
  const start = timeOf(find(event, 'DTSTART'));
  const sequence = sequenceOf(event);
  const singletons = [
    'UID',
    'SEQUENCE',
    'DTSTART',
    'DTEND',
    'DURATION',
    'ORGANIZER',
    'SUMMARY',
    'LOCATION',
  ];
  if (
    event.some((line) => recurring.has(line.name)) ||
    singletons.some(
      (name) => event.filter((line) => line.name === name).length > 1,
    ) ||
    uid === '' ||
    organizer === undefined ||
    start === undefined ||
    sequence === undefined
  ) {
    return undefined;
  }
  const details = detailsOf(event, start, organizer.recipient);
  if (details === undefined) {
    return undefined;
  }
  return {
    uid,
    sequence,
    details,
    organizerLine: organizer.line,
    summary: find(event, 'SUMMARY'),
  };
};

// The message's invitation for the owning mailbox `address`. The attendee is never guessed: only
// an ATTENDEE whose address is the mailbox's own can be answered.
export function invitationOf(
  document: Pick<BodyDocument, 'id' | 'calendar' | 'headers'>,
  address: string,
): InvitationOffer | undefined {
  if (document.calendar === undefined) {
    return undefined;
  }
  const event = requestedEvent(contentLines(document.calendar));
  const meeting = event === undefined ? undefined : meetingOf(event);
  if (event === undefined || meeting === undefined) {
    return unreadable;
  }
  const { uid, sequence, details, organizerLine, summary } = meeting;
  const attendees = event.filter((line) => line.name === 'ATTENDEE');
  const attendee = attendees.find(
    (line) => addressOf(line)?.toLowerCase() === address.toLowerCase(),
  );
  if (attendee === undefined) {
    return {
      kind: 'elsewhere',
      details,
      invited: attendees.flatMap((line) => {
        const invited = addressOf(line);
        return invited === undefined ||
          invited.toLowerCase() === details.organizer.address.toLowerCase()
          ? []
          : [invited];
      }),
    };
  }
  const messageId = document.headers?.messageId?.trim();
  return {
    kind: 'invited',
    details,
    address,
    uid,
    sequence,
    message: document.id,
    ...(messageId === undefined || messageId === '' ? {} : { messageId }),
    lines: {
      organizer: organizerLine,
      attendee,
      ...(summary === undefined ? {} : { summary }),
    },
  };
}

const partStats = {
  accepted: 'ACCEPTED',
  tentative: 'TENTATIVE',
  declined: 'DECLINED',
} as const;

const written = ({ name, parameters, value }: Line) =>
  `${[name, ...parameters].join(';')}:${value}`;

// A content line folded after 75 octets without splitting a character.
const folded = (line: string) => {
  const encoder = new TextEncoder();
  const pieces: string[] = [];
  let piece = '';
  let octets = 0;
  for (const character of line) {
    const size = encoder.encode(character).length;
    if (octets + size > (pieces.length === 0 ? 75 : 74)) {
      pieces.push(piece);
      piece = '';
      octets = 0;
    }
    piece += character;
    octets += size;
  }
  return [...pieces, piece].join('\r\n ');
};

const stamp = (at: number) =>
  new Date(at).toISOString().replaceAll(/[-:]|\.\d{3}/gu, '');

// The iTIP REPLY for `choice`: the invitation's UID and SEQUENCE, its organizer, and the owning
// mailbox's own attendee line with the chosen participation status.
export function invitationReply(
  invitation: Invitation,
  choice: InvitationChoice,
  at: number,
) {
  const { attendee, organizer, summary } = invitation.lines;
  const answered: Line = {
    ...attendee,
    parameters: [
      ...attendee.parameters.filter(
        (parameter) => !/^(?:PARTSTAT|RSVP)=/iu.test(parameter),
      ),
      `PARTSTAT=${partStats[choice]}`,
    ],
  };
  return `${[
    'BEGIN:VCALENDAR',
    'PRODID:-//Unwired//Unwired Mail//EN',
    'VERSION:2.0',
    'METHOD:REPLY',
    'BEGIN:VEVENT',
    `UID:${invitation.uid}`,
    `SEQUENCE:${invitation.sequence.toString()}`,
    `DTSTAMP:${stamp(at)}`,
    written(organizer),
    written(answered),
    ...(summary === undefined ? [] : [written(summary)]),
    'END:VEVENT',
    'END:VCALENDAR',
  ]
    .map(folded)
    .join('\r\n')}\r\n`;
}

// Where a response to one invitation stands on this device. `unknown` and `checking` keep the
// sent message's boundary, which finds its Sent copy.
export type ResponseState =
  | Readonly<{ kind: 'unanswered' }>
  | Readonly<{
      kind: 'sending' | 'refused' | 'offline' | 'authentication';
      choice: InvitationChoice;
    }>
  | Readonly<{ kind: 'sent'; choice: InvitationChoice; at: number }>
  | Readonly<{
      kind: 'unknown' | 'checking';
      choice: InvitationChoice;
      boundary: string;
    }>;

// The plain text a response carries beside its calendar reply, in the person's language.
export type ResponseCopy = Readonly<{ subject: string; text: string }>;

type ResponseInbox = Pick<
  GmailInbox,
  'send' | 'findSent' | 'getSnapshot' | 'subscribe' | 'recordResponse'
>;

const unanswered: ResponseState = { kind: 'unanswered' };

// Where a send leaves a response. Nothing that Gmail refused or never received waits to be sent
// later.
const outcomeState = (
  outcome: SendOutcome,
  sent: Readonly<{ choice: InvitationChoice; boundary: string; at: number }>,
): ResponseState => {
  const { choice } = sent;
  if (outcome.kind === 'sent' || outcome.kind === 'accepted') {
    return { kind: 'sent', choice, at: sent.at };
  }
  if (outcome.kind === 'unknown') {
    return { kind: 'unknown', choice, boundary: sent.boundary };
  }
  if (outcome.problem === 'authorization') {
    return { kind: 'authentication', choice };
  }
  return outcome.kind === 'queued' && outcome.problem === 'offline'
    ? { kind: 'offline', choice }
    : { kind: 'refused', choice };
};

// Whether a choice may be sent now: a response under way ignores it, an unknown delivery needs the
// person to confirm, and the confirmed choice is not sent twice.
const answerable = (
  current: ResponseState,
  choice: InvitationChoice,
  again: boolean,
) =>
  current.kind !== 'sending' &&
  current.kind !== 'checking' &&
  (current.kind === 'unknown') === again &&
  !(current.kind === 'sent' && current.choice === choice);

// The record that restores `state` after relaunch; other states are not recorded.
const responseOf = (
  { uid, sequence }: Invitation,
  state: ResponseState,
): InvitationResponse | undefined => {
  if (state.kind === 'sent') {
    return { kind: 'sent', uid, sequence, choice: state.choice, at: state.at };
  }
  return state.kind === 'unknown'
    ? {
        kind: 'unknown',
        uid,
        sequence,
        choice: state.choice,
        boundary: state.boundary,
      }
    : undefined;
};

// A revision of the meeting is a new invitation to answer, so its sequence is part of the key.
const keyOf = (invitation: Invitation) =>
  `${invitation.address.toLowerCase()}\u0000${invitation.uid}\u0000${invitation.sequence}`;

const replySubject = (subject: string) =>
  /^\s*re:/iu.test(subject) ? subject : `Re: ${subject}`;

// The response message: a reply to the invitation, from the invited mailbox to the organizer,
// carrying the calendar reply beside its text.
const responseMessage = (
  invitation: Invitation,
  {
    choice,
    copy,
    received,
  }: Readonly<{
    choice: InvitationChoice;
    copy: ResponseCopy;
    received: string | undefined;
  }>,
  at: number,
) => {
  const boundary = Math.random().toString(36).slice(2, 14);
  const { messageId } = invitation;
  const draft: Draft = {
    id: invitation.uid,
    connection: invitation.address,
    from: invitation.address,
    to: [invitation.details.organizer],
    cc: [],
    bcc: [],
    // Gmail keeps a reply in the invitation's conversation only when its subject matches.
    subject: received === undefined ? copy.subject : replySubject(received),
    body: [{ kind: 'paragraph', spans: [{ text: copy.text }] }],
    response: {
      kind: 'reply',
      message: invitation.message,
      ...(messageId === undefined ? {} : { inReplyTo: messageId }),
      references: messageId === undefined ? [] : [messageId],
    },
    updatedAt: at,
  };
  const { segments } = outgoingMessage(draft, {
    date: at,
    boundary,
    calendar: invitationReply(invitation, choice, at),
  });
  return { segments, boundary: boundaryOf(segments) ?? `=_${boundary}_a` };
};

// Responses to meeting invitations sent from one Gmail Inbox, shared by every window showing it.
// Each response is sent once, only after the person chooses it: a response being sent or checked
// ignores further choices, and one whose delivery is unknown is sent again only when the person
// confirms. A sent response, or one whose delivery is unknown, is recorded in the mailbox's cache
// before it is sent, so it is restored after relaunch; this run's other states stay in memory.
function createInvitationResponses(
  inbox: ResponseInbox,
  now: () => number = Date.now,
) {
  const states = new Map<string, ResponseState>();
  const listeners = new Set<() => void>();
  const set = (invitation: Invitation, state: ResponseState) => {
    states.set(keyOf(invitation), state);
    for (const listener of listeners) {
      listener();
    }
  };
  const recordOf = (invitation: Invitation) => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready' &&
      state.address?.toLowerCase() === invitation.address.toLowerCase()
      ? state.responses?.find(
          ({ uid, sequence }) =>
            uid === invitation.uid && sequence === invitation.sequence,
        )
      : undefined;
  };
  // One state per record, so readers see the same snapshot until it changes.
  const recorded = new WeakMap<InvitationResponse, ResponseState>();
  const restored = (record: InvitationResponse): ResponseState => {
    const existing = recorded.get(record);
    if (existing !== undefined) {
      return existing;
    }
    const state: ResponseState =
      record.kind === 'sent'
        ? { kind: 'sent', choice: record.choice, at: record.at }
        : { kind: 'unknown', choice: record.choice, boundary: record.boundary };
    recorded.set(record, state);
    return state;
  };
  const stateOf = (invitation: Invitation) => {
    const record = recordOf(invitation);
    return (
      states.get(keyOf(invitation)) ??
      (record === undefined ? unanswered : restored(record))
    );
  };
  // Resolves whether the mailbox's cache now holds `response` for the invitation's revision.
  const record = async (
    invitation: Invitation,
    response: InvitationResponse | undefined,
  ) => {
    const { uid, sequence } = invitation;
    const saved = await inbox
      .recordResponse({ uid, sequence }, response)
      .catch(() => false);
    return saved;
  };
  const receivedOf = (message: string) => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready'
      ? (listedMessage(state, message) ??
          state.found?.find(({ id }) => id === message))
      : undefined;
  };
  const send = async (
    invitation: Invitation,
    chosen: Readonly<{ choice: InvitationChoice; copy: ResponseCopy }>,
    again: boolean,
  ) => {
    if (!answerable(stateOf(invitation), chosen.choice, again)) {
      return;
    }
    const received = receivedOf(invitation.message);
    const thread = received?.threadId;
    const { segments, boundary } = responseMessage(
      invitation,
      { ...chosen, received: received?.subject },
      now(),
    );
    set(invitation, { kind: 'sending', choice: chosen.choice });
    const previous = recordOf(invitation);
    const pending = {
      kind: 'unknown',
      choice: chosen.choice,
      boundary,
    } as const;
    // A response that cannot be recorded is not sent, so a relaunch never offers it as unanswered.
    if (!(await record(invitation, responseOf(invitation, pending)))) {
      set(invitation, { kind: 'refused', choice: chosen.choice });
      return;
    }
    const outcome = await inbox
      .send({ segments, ...(thread === undefined ? {} : { threadId: thread }) })
      .catch((): SendOutcome => ({ kind: 'unknown' }));
    const state = outcomeState(outcome, {
      choice: chosen.choice,
      boundary,
      at: now(),
    });
    // The response stays busy until its outcome is recorded, so another one cannot take the
    // temporary record as the earlier one.
    if (state.kind !== 'unknown') {
      // Unless Gmail confirmed it, nothing was sent, so the earlier record is restored.
      await record(invitation, responseOf(invitation, state) ?? previous);
    }
    set(invitation, state);
  };
  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      // Recorded responses arrive with the mailbox's cache.
      const unsubscribe = inbox.subscribe(listener);
      return () => {
        listeners.delete(listener);
        unsubscribe();
      };
    },
    state: stateOf,
    // Sends `choice` to the organizer, unless a response is under way or its delivery is unknown.
    respond: (
      invitation: Invitation,
      choice: InvitationChoice,
      copy: ResponseCopy,
    ) => send(invitation, { choice, copy }, false),
    // Sends `choice` after the person confirms that an unknown delivery may already have arrived.
    respondAgain: (
      invitation: Invitation,
      choice: InvitationChoice,
      copy: ResponseCopy,
    ) => send(invitation, { choice, copy }, true),
    // Lets the person respond again once the mailbox is signed in after Gmail refused authorization.
    signedIn: (invitation: Invitation) => {
      if (stateOf(invitation).kind === 'authentication') {
        set(invitation, unanswered);
      }
    },
    // Looks in Sent for a response whose delivery is unknown; it stays unknown unless found.
    check: async (invitation: Invitation) => {
      const current = stateOf(invitation);
      if (current.kind !== 'unknown') {
        return;
      }
      set(invitation, { ...current, kind: 'checking' });
      const found = await inbox
        .findSent(current.boundary)
        .catch(() => undefined);
      if (found?.kind !== 'sent' && found?.kind !== 'accepted') {
        set(invitation, current);
        return;
      }
      const sent = { kind: 'sent', choice: current.choice, at: now() } as const;
      await record(invitation, responseOf(invitation, sent));
      set(invitation, sent);
    },
  };
}

export type InvitationResponses = ReturnType<typeof createInvitationResponses>;

const responsesByInbox = new WeakMap<ResponseInbox, InvitationResponses>();

// The invitation responses of `inbox`, the same for every reader of it.
export function invitationResponses(
  inbox: ResponseInbox,
  now?: () => number,
): InvitationResponses {
  const existing = responsesByInbox.get(inbox);
  if (existing !== undefined) {
    return existing;
  }
  const created = createInvitationResponses(inbox, now);
  responsesByInbox.set(inbox, created);
  return created;
}
