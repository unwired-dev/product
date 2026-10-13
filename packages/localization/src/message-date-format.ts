export function createMessageDateFormat(locale: string, detail = false) {
  return new Intl.DateTimeFormat(
    locale,
    detail
      ? {
          year: 'numeric',
          month: 'long',
          day: 'numeric',
          hour: 'numeric',
          minute: '2-digit',
          timeZone: 'UTC',
        }
      : { month: 'short', day: 'numeric', timeZone: 'UTC' },
  );
}

const day = 86_400_000;

// The day group of a listed message, relative to `now`: the list's date dividers and the row's
// time label. Days are UTC days, the same the listed times use.
export type MessageDay = 'today' | 'yesterday' | 'lastWeek' | 'earlier';

export function messageDay(receivedAt: string, now: number): MessageDay {
  const days = Math.floor(now / day) - Math.floor(Date.parse(receivedAt) / day);
  if (days <= 0) {
    return 'today';
  }
  if (days === 1) {
    return 'yesterday';
  }
  return days < 7 ? 'lastWeek' : 'earlier';
}

// How a row and its divider name a day: a time today, the weekday within the last week, the
// month of an earlier message (with its year once it is not this year's).
export function createMessageListDateFormats(locale: string) {
  const zone = { timeZone: 'UTC' } as const;
  const thisYear = new Intl.DateTimeFormat(locale, { month: 'long', ...zone });
  const otherYear = new Intl.DateTimeFormat(locale, {
    month: 'long',
    year: 'numeric',
    ...zone,
  });
  return {
    time: new Intl.DateTimeFormat(locale, {
      hour: 'numeric',
      minute: '2-digit',
      ...zone,
    }),
    weekday: new Intl.DateTimeFormat(locale, { weekday: 'long', ...zone }),
    month: (date: Date, now: number) =>
      (date.getUTCFullYear() === new Date(now).getUTCFullYear()
        ? thisYear
        : otherYear
      ).format(date),
  };
}
