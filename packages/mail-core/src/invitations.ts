import type { Translate } from '@private-email/localization';

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
  // Every meeting's start, the first included, when the invitation is a weekly series.
  starts?: readonly number[];
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
// send, a meeting that names only other addresses, a cancelled meeting, or an invitation Unwired
// cannot read.
export type InvitationOffer =
  | Invitation
  | Readonly<{
      kind: 'elsewhere';
      details: InvitationDetails;
      invited: readonly string[];
    }>
  | Readonly<{ kind: 'cancelled'; details: InvitationDetails }>
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

const recurring = new Set(['RDATE', 'EXDATE', 'RECURRENCE-ID']);

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

// The single top-level event of a `METHOD:REQUEST` or `METHOD:CANCEL` calendar with its method,
// or undefined for anything else.
const calendarEvent = (lines: readonly Line[] | undefined) => {
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
  const method = methods.join(',');
  return (method === 'REQUEST' || method === 'CANCEL') &&
    events === 1 &&
    versions.length === 1 &&
    versions[0]?.line.value === '2.0'
    ? {
        method,
        event: properties
          .filter(({ path }) => path[1] === 'VEVENT')
          .map(({ line }) => line),
      }
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

const weekdays = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'] as const;

// A UTC time an UNTIL names.
const untilOf = (value: string) => {
  const until = timeOf({ name: 'UNTIL', parameters: [], value });
  return until?.allDay === false ? until.at : undefined;
};

// What each part of a readable weekly series rule may say; any other part is unreadable. Up to
// 9999 meetings keeps the last one a valid date.
const readableParts: Readonly<
  Record<string, (value: string, weekday: string | undefined) => boolean>
> = {
  FREQ: (value) => value === 'WEEKLY',
  INTERVAL: (value) => value === '1',
  BYDAY: (value, weekday) => value === weekday,
  WKST: (value) => weekdays.some((weekday) => weekday === value),
  COUNT: (value) => /^[1-9]\d{0,3}$/u.test(value),
  UNTIL: (value) => untilOf(value) !== undefined,
};

// The parts of a weekly rule on `weekday` that ends at an UNTIL or after a COUNT, or undefined for
// any other rule.
const weeklyRule = (value: string, weekday: string | undefined) => {
  const parts = value
    .trim()
    .toUpperCase()
    .split(';')
    .map((part) => part.split('='));
  const rule = new Map(parts.map(([name = '', part = '']) => [name, part]));
  const readable = parts.every(
    ([name = '', part, ...rest]) =>
      part !== undefined &&
      rest.length === 0 &&
      readableParts[name]?.(part, weekday) === true,
  );
  return readable &&
    rule.size === parts.length &&
    rule.has('FREQ') &&
    rule.has('COUNT') !== rule.has('UNTIL')
    ? rule
    : undefined;
};

// The weekday of a timed meeting's declared start and when each week of its series starts: the
// first at the meeting's start, each later one at the declared wall-clock time 7 days on, or
// undefined when its zone skips that time.
const weeklyStarts = (dtstart: Line | undefined, start: InvitationTime) => {
  const [y = 0, mo = 1, d = 1, h = 0, mi = 0, se = 0] = (
    dateTime.exec(dtstart?.value.trim() ?? '') ?? []
  )
    .slice(1, 7)
    .map(Number);
  const timeZone = DateTime.zoneMakeNamed(
    (dtstart && parameterOf(dtstart, 'TZID')) ?? 'UTC',
  ).pipe(Option.getOrUndefined);
  if (dtstart === undefined || start.allDay || timeZone === undefined) {
    return undefined;
  }
  const at = (week: number) => {
    const naive = Date.UTC(y, mo - 1, d + 7 * week, h, mi, se);
    const meeting = DateTime.makeZoned(naive, {
      timeZone,
      adjustForTimeZone: true,
    }).pipe(Option.getOrUndefined);
    if (meeting === undefined) {
      return undefined;
    }
    const declared = DateTime.toDate(meeting).getTime() === naive;
    return declared ? DateTime.toEpochMillis(meeting) : undefined;
  };
  return {
    weekday: new Date(Date.UTC(y, mo - 1, d)).getUTCDay(),
    at: (week: number) => (week === 0 ? start.at : at(week)),
  };
};

// How many weeks after the first meeting a readable rule's last one starts; negative when an UNTIL
// comes before the first. `at` is undefined for a week whose wall-clock time a daylight-saving gap
// skips, which a COUNT doesn't count.
const lastWeekOf = (
  rule: ReadonlyMap<string, string>,
  start: InvitationTime,
  at: (week: number) => number | undefined,
) => {
  const count = rule.get('COUNT');
  if (count !== undefined) {
    let week = -1;
    let left = Number(count);
    while (left > 0) {
      week += 1;
      left -= at(week) === undefined ? 0 : 1;
    }
    return week;
  }
  const until = untilOf(rule.get('UNTIL') ?? '') ?? start.at;
  // Past an UNTIL, step back: a daylight-saving shift moves a meeting by hours, never by a week.
  let week = Math.floor((until - start.at) / (7 * day)) + 1;
  while (week >= 0 && (at(week) ?? Number.POSITIVE_INFINITY) > until) {
    week -= 1;
  }
  return week;
};

// A timed meeting's weekly series: {} without a rule, undefined for a rule it can't read.
const seriesOf = (
  event: readonly Line[],
  start: InvitationTime,
): Readonly<{ starts?: readonly number[] }> | undefined => {
  const rrule = find(event, 'RRULE');
  if (rrule === undefined) {
    return {};
  }
  const starts = weeklyStarts(find(event, 'DTSTART'), start);
  const rule =
    starts === undefined
      ? undefined
      : weeklyRule(rrule.value, weekdays[starts.weekday]);
  if (starts === undefined || rule === undefined) {
    return undefined;
  }
  const last = lastWeekOf(rule, start, starts.at);
  const meetings: number[] = [];
  for (let week = 0; week <= last; week += 1) {
    const at = starts.at(week);
    if (at !== undefined) {
      meetings.push(at);
    }
  }
  return meetings.length === 0 ? undefined : { starts: meetings };
};

const detailsOf = (
  event: readonly Line[],
  start: InvitationTime,
  organizer: Recipient,
): InvitationDetails | undefined => {
  const end = endOf(event, start);
  const series = seriesOf(event, start);
  if (end === undefined || series === undefined) {
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
    ...series,
  };
};

// A meeting's or weekly series' identity and details; another recurrence or a meeting missing its
// UID, organizer or start is unreadable.
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
    'RRULE',
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
  const calendar = calendarEvent(contentLines(document.calendar));
  const meeting =
    calendar === undefined ? undefined : meetingOf(calendar.event);
  if (calendar === undefined || meeting === undefined) {
    return unreadable;
  }
  const { method, event } = calendar;
  const { uid, sequence, details, organizerLine, summary } = meeting;
  // A cancellation needs no attendee: there is nothing to answer. Its STATUS can only be CANCELLED.
  if (method === 'CANCEL') {
    const statuses = event.filter((line) => line.name === 'STATUS');
    return statuses.length <= 1 &&
      statuses.every((line) => line.value.trim().toUpperCase() === 'CANCELLED')
      ? { kind: 'cancelled', details }
      : unreadable;
  }
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
    const current = stateOf(invitation);
    if (!answerable(current, chosen.choice, again)) {
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
      // An earlier delivery that is still unknown stays unknown, since nothing new was sent.
      set(
        invitation,
        current.kind === 'unknown'
          ? current
          : { kind: 'refused', choice: chosen.choice },
      );
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

// The words that name each choice on its button and in status text.
export const invitationChoiceKeys = {
  accepted: 'accept',
  tentative: 'maybe',
  declined: 'decline',
} as const;

export const organizerName = ({ organizer }: InvitationDetails) =>
  organizer.name ?? organizer.address;

export type InvitationFormats = Readonly<{
  day: Intl.DateTimeFormat;
  allDay: Intl.DateTimeFormat;
  time: Intl.DateTimeFormat;
  dayMonth: Intl.DateTimeFormat;
  date: Intl.DateTimeFormat;
  year: Intl.DateTimeFormat;
}>;

export const createInvitationFormats = (locale: string): InvitationFormats => ({
  day: new Intl.DateTimeFormat(locale, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }),
  allDay: new Intl.DateTimeFormat(locale, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  }),
  time: new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }),
  dayMonth: new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' }),
  date: new Intl.DateTimeFormat(locale, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }),
  year: new Intl.DateTimeFormat(locale, { year: 'numeric' }),
});

// When the meeting happens in the device's time zone: a day, or a day with its start and end. A
// weekly series names its weekday instead of a day when the meeting ends on the day it starts and
// every meeting falls on that weekday at that time, which a daylight-saving change in only one of
// the event's and the device's time zones breaks; otherwise it names the first meeting.
export function invitationWhen(
  t: Translate,
  formats: InvitationFormats,
  { start, end, starts }: InvitationDetails,
): string {
  if (start.allDay) {
    // An all-day end is exclusive: the meeting's last day is the one before it.
    const last = end?.allDay === true ? end.at - day : start.at;
    return t('invitation.allDay', {
      date:
        last > start.at
          ? t('invitation.dateRange', {
              start: formats.allDay.format(start.at),
              end: formats.allDay.format(last),
            })
          : formats.allDay.format(start.at),
    });
  }
  const at = (time: InvitationTime) =>
    t('invitation.dateTime', {
      date: formats.day.format(time.at),
      time: formats.time.format(time.at),
    });
  const sameDay =
    end !== undefined &&
    formats.day.format(start.at) === formats.day.format(end.at);
  const local = (meeting: number) =>
    `${new Date(meeting).getDay()} ${formats.time.format(meeting)}`;
  const weekly =
    starts !== undefined &&
    (end === undefined || sameDay) &&
    starts.every((meeting) => local(meeting) === local(start.at));
  const date = weekly
    ? t('invitation.weekdays', {
        context: weekdays[new Date(start.at).getDay()] ?? 'SU',
      })
    : formats.day.format(start.at);
  if (end === undefined) {
    return t('invitation.dateTime', {
      date,
      time: formats.time.format(start.at),
    });
  }
  return sameDay
    ? t('invitation.timeRange', {
        date,
        start: formats.time.format(start.at),
        end: formats.time.format(end.at),
      })
    : t('invitation.dateRange', {
        start: at(start),
        end: at(end.allDay ? start : end),
      });
}

// How often a weekly series repeats and between which days, or undefined for a single meeting.
export function invitationRepeats(
  t: Translate,
  formats: InvitationFormats,
  { start, starts }: InvitationDetails,
): string | undefined {
  const lastStart = starts?.at(-1);
  if (lastStart === undefined) {
    return undefined;
  }
  const sameYear =
    formats.year.format(start.at) === formats.year.format(lastStart);
  return t('invitation.everyWeek', {
    start: (sameYear ? formats.dayMonth : formats.date).format(start.at),
    end: formats.date.format(lastStart),
  });
}

// An offline device or a refused sign-in, which the mailbox's sync names before anything is sent.
export const invitationBlockedBy = (sync: string | undefined) => {
  if (sync === 'retry') {
    return 'offline';
  }
  return sync === 'authentication' ? 'authentication' : undefined;
};

// How a card describes a response state: its SF Symbol and palette color, or a spinner when busy.
export type InvitationStatus = Readonly<{
  icon?: string;
  tone?: 'accentInk' | 'statusDestructive' | 'statusWarning';
  busy?: boolean;
  title: string;
  detail: string;
}>;

type StatusContext = Readonly<{
  t: Translate;
  name: string;
  address: string;
  provider: string;
  time: Intl.DateTimeFormat;
  // Whether a response answers every meeting in a weekly series.
  series?: boolean;
}>;

type Kind = ResponseState['kind'];

const choiceOf = (t: Translate, state: ResponseState) =>
  'choice' in state
    ? t(`invitation.${invitationChoiceKeys[state.choice]}`)
    : '';

const statuses: {
  readonly [K in Kind]: (
    state: Extract<ResponseState, { readonly kind: K }>,
    context: StatusContext,
  ) => InvitationStatus;
} = {
  unanswered: (_, { t, name, address, series }) => ({
    title: t('invitation.unanswered'),
    detail: series
      ? t('invitation.seriesDetail')
      : t('invitation.unansweredDetail', { name, address }),
  }),
  sending: (state, { t, address }) => ({
    busy: true,
    title: t('invitation.sending'),
    detail: t('invitation.sendingDetail', {
      choice: choiceOf(t, state),
      address,
    }),
  }),
  sent: (state, { t, name, provider, time }) => ({
    icon: 'checkmark.circle.fill',
    tone: 'accentInk',
    title: t(`invitation.${state.choice}`),
    detail: t('invitation.sentDetail', {
      provider,
      name,
      time: time.format(state.at),
    }),
  }),
  refused: (state, { t, name, provider }) => ({
    icon: 'exclamationmark.triangle.fill',
    tone: 'statusDestructive',
    title: t('invitation.refused'),
    detail: t('invitation.refusedDetail', {
      provider,
      choice: choiceOf(t, state),
      name,
    }),
  }),
  unknown: (state, { t, provider }) => ({
    icon: 'exclamationmark.triangle.fill',
    tone: 'statusWarning',
    title: t('invitation.unknown'),
    detail: t('invitation.unknownDetail', {
      provider,
      choice: choiceOf(t, state),
    }),
  }),
  checking: (state, { t, provider }) => ({
    busy: true,
    title: t('invitation.checking', { provider }),
    detail: t('invitation.checkingDetail', { choice: choiceOf(t, state) }),
  }),
  offline: (_, { t }) => ({
    icon: 'wifi.slash',
    title: t('invitation.offline'),
    detail: t('invitation.offlineDetail'),
  }),
  authentication: (_, { t, address, provider }) => ({
    icon: 'exclamationmark.triangle.fill',
    tone: 'statusWarning',
    title: t('invitation.authentication', { provider }),
    detail: t('invitation.authenticationDetail', { address }),
  }),
};

export const invitationStatus = <K extends Kind>(
  state: Extract<ResponseState, { readonly kind: K }>,
  context: StatusContext,
): InvitationStatus => statuses[state.kind](state, context);
