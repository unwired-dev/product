import type { TFunction } from 'i18next';

// The received date a response quotes when the message has no Date header: a full UTC date, so
// mail sent to other people never carries a relative day or an unnamed time zone.
export function createMessageDateFormat(locale: string) {
  return new Intl.DateTimeFormat(locale, {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
  });
}

const dayLength = 86_400_000;
const calendars = new Map<string, Intl.DateTimeFormat>();

// The calendar date `at` falls on in `timeZone`: its days since the epoch, its year and its month.
function calendarDate(at: number, timeZone: string) {
  let format = calendars.get(timeZone);
  if (format === undefined) {
    format = new Intl.DateTimeFormat('en-US', {
      timeZone,
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
    });
    calendars.set(timeZone, format);
  }
  const parts = new Map(
    format.formatToParts(at).map(({ type, value }) => [type, Number(value)]),
  );
  const year = parts.get('year') ?? 0;
  const month = parts.get('month') ?? 1;
  return {
    days: Date.UTC(year, month - 1, parts.get('day') ?? 1) / dayLength,
    year,
    month: `${year}-${month}`,
  };
}

// The day group of a listed message, relative to `now`: the list's date dividers, the row's time
// label and the header's date. Days are the calendar days of the device's time zone.
export type MessageDay = 'today' | 'yesterday' | 'lastWeek' | 'earlier';

const daysBefore = (at: number, now: number, timeZone: string) =>
  calendarDate(now, timeZone).days - calendarDate(at, timeZone).days;

export function messageDay(
  receivedAt: string,
  now: number,
  timeZone: string,
): MessageDay {
  const days = daysBefore(Date.parse(receivedAt), now, timeZone);
  if (days <= 0) {
    return 'today';
  }
  if (days === 1) {
    return 'yesterday';
  }
  return days < 7 ? 'lastWeek' : 'earlier';
}

// The month an earlier message's divider names, in the device's time zone.
export const messageMonth = (receivedAt: string, timeZone: string) =>
  calendarDate(Date.parse(receivedAt), timeZone).month;

// How the interface names when a message arrived, on the device's clocks: a row and its divider, a
// message header, and the full date VoiceOver reads.
export function createMessageDateFormats(locale: string, timeZone: string) {
  const format = (options: Intl.DateTimeFormatOptions) =>
    new Intl.DateTimeFormat(locale, { ...options, timeZone });
  const clock = { hour: 'numeric', minute: '2-digit' } as const;
  const day = { weekday: 'short', day: 'numeric', month: 'short' } as const;
  const time = format(clock);
  const thisYear = format({ month: 'long' });
  const otherYear = format({ month: 'long', year: 'numeric' });
  const dated = format({ ...day, ...clock });
  const datedYear = format({ ...day, year: 'numeric', ...clock });
  const weekday = format({ weekday: 'long' });
  const shortWeekday = format({ weekday: 'short' });
  const date = format({ month: 'short', day: 'numeric' });
  const sameYear = (at: Date, now: number) =>
    calendarDate(at.getTime(), timeZone).year ===
    calendarDate(now, timeZone).year;
  return {
    day: (receivedAt: string, now: number) =>
      messageDay(receivedAt, now, timeZone),
    time,
    month: (at: Date, now: number) =>
      (sameYear(at, now) ? thisYear : otherYear).format(at),
    // A row's time: the clock today, Yesterday, the day's name within the last week and the date
    // before that. iPhone's compact message header names the day in short.
    row(
      // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- i18next's translation function is mutable; this only calls it.
      t: TFunction,
      receivedAt: string,
      now: number,
      short = false,
    ) {
      const at = new Date(receivedAt);
      const day = messageDay(receivedAt, now, timeZone);
      if (day === 'today') {
        return time.format(at);
      }
      if (day === 'yesterday') {
        return t('inbox.yesterday');
      }
      return day === 'lastWeek'
        ? (short ? shortWeekday : weekday).format(at)
        : date.format(at);
    },
    // A message header: Today or Yesterday with the time, then the weekday and date with the time,
    // and the year once it is not this one.
    header(
      // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- i18next's translation function is mutable; this only calls it.
      t: TFunction,
      at: Date,
      now: number,
    ) {
      const days = daysBefore(at.getTime(), now, timeZone);
      if (days <= 1) {
        return t(days <= 0 ? 'message.today' : 'message.yesterday', {
          time: time.format(at),
        });
      }
      return (sameYear(at, now) ? dated : datedYear).format(at);
    },
    full: format({
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      ...clock,
    }),
  };
}
