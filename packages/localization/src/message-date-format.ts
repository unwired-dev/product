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
type CalendarDate = Readonly<{ days: number; month: string }>;
const calendars = new Map<
  string,
  {
    format: Intl.DateTimeFormat;
    arrivals: Map<number, CalendarDate>;
    now?: Readonly<{ at: number; date: CalendarDate }>;
  }
>();

function zoneCalendar(timeZone: string) {
  let calendar = calendars.get(timeZone);
  if (calendar === undefined) {
    calendar = {
      format: new Intl.DateTimeFormat('en-US', {
        timeZone,
        year: 'numeric',
        month: 'numeric',
        day: 'numeric',
      }),
      arrivals: new Map(),
    };
    calendars.set(timeZone, calendar);
  }
  return calendar;
}

// The Gregorian calendar date `at` falls on: its days since the epoch and its month.
function readDate(format: Readonly<Intl.DateTimeFormat>, at: number) {
  const parts = new Map(
    format.formatToParts(at).map(({ type, value }) => [type, Number(value)]),
  );
  const year = parts.get('year') ?? 0;
  const month = parts.get('month') ?? 1;
  return {
    days: Date.UTC(year, month - 1, parts.get('day') ?? 1) / dayLength,
    month: `${year}-${month}`,
  };
}

// The calendar date a message arrived on in `timeZone`. Each zone keeps the arrivals it has read,
// so regrouping a loaded list every minute formats only new ones.
function arrivalDate(at: number, timeZone: string) {
  const { format, arrivals } = zoneCalendar(timeZone);
  const known = arrivals.get(at);
  if (known !== undefined) {
    return known;
  }
  const date = readDate(format, at);
  if (arrivals.size >= 50_000) {
    arrivals.clear();
  }
  arrivals.set(at, date);
  return date;
}

// The calendar date of `now`, read once for every row of a pass and kept apart from the arrivals.
function currentDate(now: number, timeZone: string) {
  const calendar = zoneCalendar(timeZone);
  if (calendar.now?.at !== now) {
    calendar.now = { at: now, date: readDate(calendar.format, now) };
  }
  return calendar.now.date;
}

// The day group of a listed message, relative to `now`: the list's date dividers, the row's time
// label and the header's date. Days are the calendar days of the device's time zone.
export type MessageDay = 'today' | 'yesterday' | 'lastWeek' | 'earlier';

const daysBefore = (at: number, now: number, timeZone: string) =>
  currentDate(now, timeZone).days - arrivalDate(at, timeZone).days;

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
  arrivalDate(Date.parse(receivedAt), timeZone).month;

const formatSets = new Map<string, ReturnType<typeof messageDateFormats>>();

// How the interface names when a message arrived, on the device's clocks: a row and its divider, a
// message header, and the full date VoiceOver reads. Every row of a locale and zone shares one set.
export function createMessageDateFormats(locale: string, timeZone: string) {
  const key = `${locale}\n${timeZone}`;
  let formats = formatSets.get(key);
  if (formats === undefined) {
    formats = messageDateFormats(locale, timeZone);
    formatSets.set(key, formats);
  }
  return formats;
}

function messageDateFormats(locale: string, timeZone: string) {
  const format = (options: Readonly<Intl.DateTimeFormatOptions>) =>
    new Intl.DateTimeFormat(locale, { ...options, timeZone });
  const clock = format({ hour: 'numeric', minute: '2-digit' });
  // An unpadded hour, as `hour: 'numeric'` asks: Apple's formatter, which Hermes uses there, writes
  // 07:12 in 24-hour locales, in the locale's own digits.
  const zero = new Intl.NumberFormat(locale).format(0);
  const time = {
    format: (at: Date | number) =>
      clock
        .formatToParts(at)
        .map(({ type, value }) =>
          type === 'hour' &&
          value.length > zero.length &&
          value.startsWith(zero)
            ? value.slice(zero.length)
            : value,
        )
        .join(''),
  };
  const shortDate = {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
  } as const;
  const thisYear = format({ month: 'long' });
  const otherYear = format({ month: 'long', year: 'numeric' });
  const dated = format(shortDate);
  const datedYear = format({ ...shortDate, year: 'numeric' });
  const weekday = format({ weekday: 'long' });
  const shortWeekday = format({ weekday: 'short' });
  const date = format({ month: 'short', day: 'numeric' });
  // Years of the display calendar, which System default takes from the device.
  const year = format({ year: 'numeric' });
  const sameYear = (at: Date, now: number) =>
    year.format(at) === year.format(now);
  // A row's time: the clock today, Yesterday, the day's name within the last week and the date
  // before that.
  const row =
    (named: Intl.DateTimeFormat) =>
    (
      // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- i18next's translation function is mutable; this only calls it.
      t: TFunction,
      receivedAt: string,
      now: number,
    ) => {
      const at = new Date(receivedAt);
      const day = messageDay(receivedAt, now, timeZone);
      if (day === 'today') {
        return time.format(at);
      }
      if (day === 'yesterday') {
        return t('inbox.yesterday');
      }
      return day === 'lastWeek' ? named.format(at) : date.format(at);
    };
  return {
    day: (receivedAt: string, now: number) =>
      messageDay(receivedAt, now, timeZone),
    time,
    month: (at: Date, now: number) =>
      (sameYear(at, now) ? thisYear : otherYear).format(at),
    row: row(weekday),
    // iPhone's compact message header names the day as its row does, the weekday in short.
    compact: row(shortWeekday),
    // A message header: Today or Yesterday with the time, then the weekday and date with the time,
    // and the year once it is not this one.
    header(
      // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- i18next's translation function is mutable; this only calls it.
      t: TFunction,
      at: Date,
      now: number,
    ) {
      const days = daysBefore(at.getTime(), now, timeZone);
      const clockTime = time.format(at);
      if (days <= 1) {
        return t(days <= 0 ? 'message.today' : 'message.yesterday', {
          time: clockTime,
        });
      }
      return t('message.dated', {
        date: (sameYear(at, now) ? dated : datedYear).format(at),
        time: clockTime,
      });
    },
    full: format({
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    }),
  };
}
