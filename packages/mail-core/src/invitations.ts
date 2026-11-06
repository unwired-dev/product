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
  // The original start of the one meeting of a series the invitation is for (its RECURRENCE-ID),
  // which identifies that meeting.
  recurrence?: number;
}>;

// One iCalendar content line: its name, its raw parameters and its value.
type Line = Readonly<{
  name: string;
  parameters: readonly string[];
  value: string;
}>;

// An invitation to one meeting, a weekly series or one meeting of a series, addressed to the owning
// mailbox, with what its reply repeats.
export type Invitation = Readonly<{
  kind: 'invited';
  details: InvitationDetails;
  // The owning mailbox's address, which the invitation names as an attendee.
  address: string;
  // Every attendee address, lowercase.
  attendees: readonly string[];
  uid: string;
  sequence: number;
  // The received message it answers and its Message-ID header, for threading.
  message: string;
  messageId?: string;
  lines: Readonly<{
    organizer: Line;
    attendee: Line;
    summary?: Line;
  }>;
}>;

// What a received message's calendar part offers: nothing, a response the owning mailbox can
// send, a meeting that names only other addresses, a cancelled meeting, a series update that
// doesn't say which of its meetings it changes, or an invitation Unwired cannot read.
export type InvitationOffer =
  | Invitation
  | Readonly<{
      kind: 'elsewhere';
      details: InvitationDetails;
      invited: readonly string[];
    }>
  | Readonly<{ kind: 'cancelled'; details: InvitationDetails }>
  | Readonly<{ kind: 'ambiguous'; details: InvitationDetails }>
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

const recurring = new Set(['RDATE', 'EXDATE']);

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

// The most meetings a readable series holds, whether a COUNT or an UNTIL ends it, which bounds the
// work of listing them.
const maxMeetings = 9999;

// Each meeting's start through the last week, or undefined for none or more than the most.
const meetingsOf = (last: number, at: (week: number) => number | undefined) => {
  const meetings: number[] = [];
  for (
    let week = 0;
    week <= last && meetings.length <= maxMeetings;
    week += 1
  ) {
    const meeting = at(week);
    if (meeting !== undefined) {
      meetings.push(meeting);
    }
  }
  return meetings.length === 0 || meetings.length > maxMeetings
    ? undefined
    : meetings;
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
  const meetings = meetingsOf(lastWeekOf(rule, start, starts.at), starts.at);
  return meetings === undefined ? undefined : { starts: meetings };
};

// One meeting of a series: its RECURRENCE-ID's instant, of the same value type as DTSTART. null
// without one, undefined for a range of meetings, which it can't read.
const recurrenceOf = (event: readonly Line[], start: InvitationTime) => {
  const line = find(event, 'RECURRENCE-ID');
  if (line === undefined) {
    return null;
  }
  const time = timeOf(line);
  return time === undefined ||
    time.allDay !== start.allDay ||
    parameterOf(line, 'RANGE') !== undefined
    ? undefined
    : time.at;
};

const detailsOf = (
  event: readonly Line[],
  start: InvitationTime,
  organizer: Recipient,
): InvitationDetails | undefined => {
  const end = endOf(event, start);
  const series = seriesOf(event, start);
  const recurrence = recurrenceOf(event, start);
  if (end === undefined || series === undefined || recurrence === undefined) {
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
    ...(recurrence === null || series.starts !== undefined
      ? {}
      : { recurrence }),
  };
};

// A meeting's, weekly series' or one series meeting's identity and details; another recurrence or a
// meeting missing its UID, organizer or start is unreadable.
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
    'RECURRENCE-ID',
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
  // A RECURRENCE-ID beside a rule names one meeting yet carries the whole series, so neither a
  // response nor a change can be matched to a meeting.
  if (
    details.starts !== undefined &&
    find(event, 'RECURRENCE-ID') !== undefined
  ) {
    return { kind: 'ambiguous', details };
  }
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
    attendees: attendees.flatMap(
      (line) => addressOf(line)?.toLowerCase() ?? [],
    ),
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

// The Profile's other mailboxes the invitation also names. Each copy responds only for its own
// mailbox, so these are listed, never answered for.
export const alsoInvited = <M extends Readonly<{ address?: string }>>(
  invitation: Invitation,
  mailboxes: readonly M[],
) =>
  mailboxes.filter((mailbox): mailbox is M & Readonly<{ address: string }> => {
    const other = mailbox.address?.toLowerCase();
    return (
      other !== undefined &&
      other !== invitation.address.toLowerCase() &&
      invitation.attendees.includes(other)
    );
  });

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

// The iTIP REPLY for `choice`: the invitation's UID, SEQUENCE and RECURRENCE-ID, its organizer, and
// the owning mailbox's own attendee line with the chosen participation status.
export function invitationReply(
  invitation: Invitation,
  choice: InvitationChoice,
  at: number,
) {
  const { attendee, organizer, summary } = invitation.lines;
  const { start, recurrence } = invitation.details;
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
    // A timed meeting is named by its original start in UTC, which needs no VTIMEZONE beside it.
    ...(recurrence === undefined
      ? []
      : [
          start.allDay
            ? `RECURRENCE-ID;VALUE=DATE:${stamp(recurrence).slice(0, 8)}`
            : `RECURRENCE-ID:${stamp(recurrence)}`,
        ]),
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
// sent message's boundary, which finds its Sent copy. `older` is a revision older than one this
// device answered, and `removed` one whose mailbox left Unwired while sending; neither can respond.
export type ResponseState =
  | Readonly<{ kind: 'unanswered' }>
  | Readonly<{ kind: 'older' }>
  | Readonly<{
      kind: 'sending' | 'refused' | 'removed' | 'offline' | 'authentication';
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
  | 'send'
  | 'findSent'
  | 'findMessage'
  | 'getSnapshot'
  | 'subscribe'
  | 'recordResponse'
>;

const unanswered: ResponseState = { kind: 'unanswered' };
const older: ResponseState = { kind: 'older' };

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
  // No other mailbox ever sends it in the removed one's place.
  if (outcome.problem === 'mailbox') {
    return { kind: 'removed', choice };
  }
  return outcome.kind === 'queued' && outcome.problem === 'offline'
    ? { kind: 'offline', choice }
    : { kind: 'refused', choice };
};

// Whether a choice may be sent now: a response under way or an older revision ignores it, an
// unknown delivery needs the person to confirm, and the confirmed choice is not sent twice.
const answerable = (
  current: ResponseState,
  choice: InvitationChoice,
  again: boolean,
) =>
  current.kind !== 'sending' &&
  current.kind !== 'older' &&
  current.kind !== 'removed' &&
  current.kind !== 'checking' &&
  (current.kind === 'unknown') === again &&
  !(current.kind === 'sent' && current.choice === choice);

// The record that restores `state` after relaunch; other states are not recorded. It keeps the
// time it answered, so a later revision can say what changed, and the message it answered, which
// an older revision opens.
const responseOf = (
  { uid, sequence, message, details: { start, end, recurrence } }: Invitation,
  state: ResponseState,
): InvitationResponse | undefined => {
  const revision = {
    uid,
    sequence,
    ...(recurrence === undefined ? {} : { recurrence }),
    start,
    ...(end === undefined ? {} : { end }),
    message,
  };
  if (state.kind === 'sent') {
    return { kind: 'sent', ...revision, choice: state.choice, at: state.at };
  }
  return state.kind === 'unknown'
    ? {
        kind: 'unknown',
        ...revision,
        choice: state.choice,
        boundary: state.boundary,
      }
    : undefined;
};

// A confirmed response to an earlier revision of an invitation, and the time it answered.
export type EarlierResponse = Readonly<{
  choice: InvitationChoice;
  start: InvitationTime;
  end?: InvitationTime;
}>;

const timed = (
  record: InvitationResponse,
): record is Extract<InvitationResponse, { kind: 'sent' }> & EarlierResponse =>
  record.kind === 'sent' && record.start !== undefined;

const sameTime = (
  a: InvitationTime | undefined,
  b: InvitationTime | undefined,
) => a?.at === b?.at && a?.allDay === b?.allDay;

// A revision of the meeting is a new invitation to answer, so its sequence is part of the key, as
// is the one meeting of a series it is for.
const keyOf = (invitation: Invitation) =>
  `${invitation.address.toLowerCase()}\u0000${invitation.uid}\u0000${invitation.sequence}\u0000${invitation.details.recurrence ?? ''}`;

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
  // The opened mailbox's recorded responses to the invitation's meeting, most recent first. One
  // meeting of a series has its own.
  const recordsOf = (invitation: Invitation) => {
    const state = inbox.getSnapshot();
    return state.kind === 'ready' &&
      state.address?.toLowerCase() === invitation.address.toLowerCase()
      ? (state.responses ?? []).filter(
          ({ uid, recurrence }) =>
            uid === invitation.uid &&
            recurrence === invitation.details.recurrence,
        )
      : [];
  };
  const recordOf = (invitation: Invitation) =>
    recordsOf(invitation).find(
      ({ sequence }) => sequence === invitation.sequence,
    );
  // The record of the newest other revision of the invitation's meeting that was answered.
  const newestOtherOf = (invitation: Invitation) =>
    recordsOf(invitation)
      .filter(({ sequence }) => sequence !== invitation.sequence)
      .reduce<InvitationResponse | undefined>(
        (found, record) =>
          found === undefined || record.sequence > found.sequence
            ? record
            : found,
        undefined,
      );
  // The confirmed response to the latest earlier revision, when that revision was at another time.
  const earlierOf = (invitation: Invitation): EarlierResponse | undefined => {
    // A newer answered revision makes this one an older version, which names no earlier answer.
    const latest = newestOtherOf(invitation);
    return latest !== undefined &&
      latest.sequence < invitation.sequence &&
      timed(latest) &&
      !(
        sameTime(latest.start, invitation.details.start) &&
        sameTime(latest.end, invitation.details.end)
      )
      ? latest
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
    // A response to a newer revision outdates this one, whatever it answered before.
    if (
      recordsOf(invitation).some(
        ({ sequence }) => sequence > invitation.sequence,
      )
    ) {
      return older;
    }
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
    const {
      uid,
      sequence,
      details: { recurrence },
    } = invitation;
    const saved = await inbox
      .recordResponse(
        {
          uid,
          sequence,
          ...(recurrence === undefined ? {} : { recurrence }),
        },
        response,
      )
      .catch(() => false);
    return saved;
  };
  const newerMessageOf = (invitation: Invitation) => {
    const newest = newestOtherOf(invitation);
    return newest !== undefined && newest.sequence > invitation.sequence
      ? newest.message
      : undefined;
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
    earlier: earlierOf,
    // The message of the newest revision this device answered after `invitation`'s, while the
    // reader can open it.
    latest: (invitation: Invitation) => {
      const message = newerMessageOf(invitation);
      return message !== undefined && receivedOf(message) !== undefined
        ? message
        : undefined;
    },
    // Asks Gmail for that message when the reader cannot open it yet, as when it was archived, so
    // `latest` finds it while the mailbox still has it.
    findLatest: async (invitation: Invitation) => {
      const message = newerMessageOf(invitation);
      if (message !== undefined && receivedOf(message) === undefined) {
        await inbox.findMessage(message).catch(() => undefined);
      }
    },
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
  // English short weekday names in the formats' time zone, read only for their iCalendar code.
  weekday: Intl.DateTimeFormat;
  dayMonth: Intl.DateTimeFormat;
  date: Intl.DateTimeFormat;
  year: Intl.DateTimeFormat;
  // An earlier revision's day, which appears beside the current one and its year.
  earlierDay: Intl.DateTimeFormat;
  earlierAllDay: Intl.DateTimeFormat;
}>;

const days = { weekday: 'short', day: 'numeric', month: 'short' } as const;

export const createInvitationFormats = (locale: string): InvitationFormats => ({
  day: new Intl.DateTimeFormat(locale, { ...days, year: 'numeric' }),
  allDay: new Intl.DateTimeFormat(locale, {
    ...days,
    year: 'numeric',
    timeZone: 'UTC',
  }),
  time: new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }),
  weekday: new Intl.DateTimeFormat('en-US', { weekday: 'short' }),
  dayMonth: new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' }),
  date: new Intl.DateTimeFormat(locale, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }),
  year: new Intl.DateTimeFormat(locale, { year: 'numeric' }),
  earlierDay: new Intl.DateTimeFormat(locale, days),
  earlierAllDay: new Intl.DateTimeFormat(locale, { ...days, timeZone: 'UTC' }),
});

// Whether every meeting in a series starts, and ends, on the first meeting's local weekday and time.
const sameLocalTimes = (
  formats: InvitationFormats,
  starts: readonly number[],
  {
    start,
    end,
  }: Readonly<{ start: InvitationTime; end: InvitationTime | undefined }>,
) => {
  const local = (meeting: number) =>
    `${formats.weekday.format(meeting)} ${formats.time.format(meeting)}`;
  const first = local(start.at);
  const last = end === undefined ? undefined : local(end.at);
  const length = end === undefined ? 0 : end.at - start.at;
  return starts.every(
    (meeting) =>
      local(meeting) === first &&
      (last === undefined || local(meeting + length) === last),
  );
};

// When the meeting happens in the device's time zone: a day, or a day with its start and end. A
// weekly series names its weekday instead of a day when the meeting ends on the day it starts and
// every meeting has the same local start and end, which a daylight-saving change can break;
// otherwise it names the first meeting.
export function invitationWhen(
  t: Translate,
  formats: InvitationFormats,
  { start, end, starts }: Pick<InvitationDetails, 'start' | 'end' | 'starts'>,
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
  const weekly =
    starts !== undefined &&
    (end === undefined || sameDay) &&
    sameLocalTimes(formats, starts, { start, end });
  const date = weekly
    ? t('invitation.weekdays', {
        context:
          weekdays.find(
            (weekday) =>
              weekday ===
              formats.weekday.format(start.at).slice(0, 2).toUpperCase(),
          ) ?? 'SU',
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

// How often a weekly series repeats and between which days, that one meeting of a series is
// shown, or undefined for a single meeting.
export function invitationRepeats(
  t: Translate,
  formats: InvitationFormats,
  { start, starts, recurrence }: InvitationDetails,
): string | undefined {
  if (recurrence !== undefined) {
    return t('invitation.oneMeeting');
  }
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

// Which meetings an unanswered response answers, for a weekly series or one meeting of a series.
export function invitationScope(
  t: Translate,
  formats: InvitationFormats,
  { start, starts, recurrence }: InvitationDetails,
): string | undefined {
  if (recurrence !== undefined) {
    return t('invitation.oneMeetingDetail', {
      date: (start.allDay ? formats.earlierAllDay : formats.earlierDay).format(
        start.at,
      ),
    });
  }
  return starts === undefined ? undefined : t('invitation.seriesDetail');
}

// When the earlier revision a response answered happened, shown beneath the current time.
export const invitationWas = (
  t: Translate,
  formats: InvitationFormats,
  earlier: EarlierResponse,
) =>
  t('invitation.was', {
    when: invitationWhen(
      t,
      { ...formats, day: formats.earlierDay, allDay: formats.earlierAllDay },
      earlier,
    ),
  });

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
  // How many of the Profile's other addresses the invitation also names.
  alsoInvited: number;
  // Which meetings of a series a response answers, from `invitationScope`.
  scope?: string | undefined;
  // The person's response to an earlier revision at another time, which an unanswered one names.
  earlier?: InvitationChoice | undefined;
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
  unanswered: (
    _,
    { t, name, address, alsoInvited: others, earlier, scope },
  ) => {
    // A moved meeting asks for a new answer first; the address it answers from stays in Invited.
    if (earlier !== undefined) {
      return {
        icon: 'info.circle',
        title: t('invitation.changedTime', { name }),
        detail: t(`invitation.${earlier}Earlier`),
      };
    }
    return others === 0
      ? {
          title: t('invitation.unanswered'),
          detail: scope ?? t('invitation.unansweredDetail', { name, address }),
        }
      : {
          icon: 'info.circle',
          title: t('invitation.respondingAs', { address }),
          detail: t(
            others === 1
              ? 'invitation.invitedTwice'
              : 'invitation.invitedMoreThanTwice',
            { address, count: others + 1 },
          ),
        };
  },
  older: (_, { t }) => ({
    icon: 'info.circle',
    title: t('invitation.older'),
    detail: t('invitation.olderDetail'),
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
  removed: (_, { t, address }) => ({
    icon: 'exclamationmark.triangle.fill',
    tone: 'statusDestructive',
    title: t('invitation.refused'),
    detail: t('invitation.removedDetail', { address }),
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
