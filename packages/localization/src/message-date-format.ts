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
