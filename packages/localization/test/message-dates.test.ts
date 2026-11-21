import {
  createLocalization,
  createMessageDateFormats,
  english,
  lastUpdated,
  messageDay,
  messageMonth,
} from '../src/index.ts';

// The list groups rows by the calendar day they arrived in the device's time zone, the day their
// listed times and the reader's header use.
describe('message list days', () => {
  const now = Date.parse('2026-10-13T09:41:00Z');

  it('names each arrival day relative to now and keeps the week before the earlier months', () => {
    expect.hasAssertions();
    expect(messageDay('2026-10-13T00:00:00Z', now, 'UTC')).toBe('today');
    expect(messageDay('2026-10-13T23:59:59Z', now, 'UTC')).toBe('today');
    expect(messageDay('2026-10-12T23:59:59Z', now, 'UTC')).toBe('yesterday');
    expect(messageDay('2026-10-07T00:00:00Z', now, 'UTC')).toBe('lastWeek');
    expect(messageDay('2026-10-06T23:59:59Z', now, 'UTC')).toBe('earlier');
  });

  it('keeps a message dated ahead of this device clock in today', () => {
    expect.hasAssertions();
    expect(messageDay('2026-10-14T01:00:00Z', now, 'UTC')).toBe('today');
  });

  it('formats a row time, a weekday and a month that names its year once it is not this one', () => {
    expect.hasAssertions();
    const formats = createMessageDateFormats('en-GB', 'UTC');
    expect(formats.time.format(new Date('2026-10-13T09:41:00Z'))).toMatch(
      /^0?9:41$/u,
    );
    expect(
      [
        '2026-10-12T12:00:00Z',
        '2026-10-08T12:00:00Z',
        '2026-09-03T12:00:00Z',
      ].map((at) => [
        formats.row(english, at, now),
        formats.compact(english, at, now),
      ]),
    ).toStrictEqual([
      ['Yesterday', 'Yesterday'],
      ['Thursday', 'Thu'],
      ['3 Sept', '3 Sept'],
    ]);
    expect(
      ['2026-09-03T12:00:00Z', '2025-12-03T12:00:00Z'].map((at) =>
        formats.month(new Date(at), now),
      ),
    ).toStrictEqual(['September', 'December 2025']);
  });
});

// A message header says when the message arrived as the rest of the interface does, on the
// device's clocks: 9:30 on 13 October in Prague is 7:30 UTC.
describe('message header dates', () => {
  const zone = 'Europe/Prague';
  const now = Date.parse('2026-10-13T07:30:00Z');
  const formats = createMessageDateFormats('en-GB', zone);
  const header = (at: string, current = now) =>
    formats.header(english, new Date(at), current);

  it('names today, yesterday, an earlier date this year and a date of another year', () => {
    expect.hasAssertions();
    expect(
      [
        '2026-10-13T06:12:00Z',
        '2026-10-12T19:14:00Z',
        '2026-10-11T19:14:00Z',
        '2025-10-11T19:14:00Z',
      ].map((at) => header(at)),
    ).toStrictEqual([
      'Today, 8:12',
      'Yesterday, 21:14',
      'Sun 11 Oct, 21:14',
      'Sat, 11 Oct 2025, 21:14',
    ]);
    expect(formats.full.format(new Date('2026-10-13T06:12:00Z'))).toBe(
      'Tuesday, 13 October 2026 at 8:12',
    );
  });

  it('reads the day on both sides of midnight in the device time zone, as the list does', () => {
    expect.hasAssertions();
    // 00:30 on 13 October in Prague is still 12 October in UTC; 23:59 on the 12th is yesterday.
    expect(
      ['2026-10-12T22:30:00Z', '2026-10-12T21:59:00Z'].map((at) => [
        header(at),
        formats.day(at, now),
        messageDay(at, now, 'UTC'),
      ]),
    ).toStrictEqual([
      ['Today, 0:30', 'today', 'yesterday'],
      ['Yesterday, 23:59', 'yesterday', 'yesterday'],
    ]);
    // West of UTC the day ends earlier: 3:00 UTC is 23:00 the day before in New York.
    expect(messageDay('2026-10-13T03:00:00Z', now, 'America/New_York')).toBe(
      'yesterday',
    );
    expect(
      [zone, 'UTC'].map((each) => messageMonth('2026-09-30T22:30:00Z', each)),
    ).toStrictEqual(['2026-10', '2026-9']);
  });

  it('moves a header to Yesterday once midnight passes, and follows a new time zone', () => {
    expect.hasAssertions();
    const afterMidnight = Date.parse('2026-10-13T22:05:00Z');
    expect(header('2026-10-13T06:12:00Z', afterMidnight)).toBe(
      'Yesterday, 8:12',
    );
    expect(
      createMessageDateFormats('en-GB', 'Asia/Tokyo').header(
        english,
        new Date('2026-10-13T06:12:00Z'),
        now,
      ),
    ).toBe('Today, 15:12');
  });

  it('writes German and Czech dates by their own conventions', () => {
    expect.hasAssertions();
    const sunday = new Date('2026-10-11T19:14:00Z');
    expect(
      createMessageDateFormats('de-DE', zone).header(english, sunday, now),
    ).toBe('So., 11. Okt., 21:14');
    expect(
      createMessageDateFormats('cs-CZ', zone).header(english, sunday, now),
    ).toBe('ne 11. 10. 21:14');
    expect(createMessageDateFormats('cs-CZ', zone).full.format(sunday)).toBe(
      'neděle 11. října 2026 v 21:14',
    );
  });
});

// The Inbox subtitle names when the shown Inboxes were last all brought up to date.
describe('last update', () => {
  const now = Date.parse('2026-10-27T09:41:30Z');
  const { t } = createLocalization(
    { preference: null, language: 'en', locale: 'en-GB', timeZone: 'UTC' },
    { getSettings: async () => undefined, setLanguage: async () => undefined },
  ).i18n;

  const updated = (...at: string[]) => lastUpdated(t, at, now);

  it('names the oldest shown synchronization, and nothing before any completed', () => {
    expect.hasAssertions();
    expect(updated()).toBeUndefined();
    expect(updated('2026-10-27T09:40:30Z', '2026-10-27T08:41:30Z')).toBe(
      'Updated 1 hour ago',
    );
  });

  it('counts whole minutes, hours and days', () => {
    expect.hasAssertions();
    expect(updated('2026-10-27T09:40:31Z')).toBe('Updated just now');
    expect(updated('2026-10-27T09:40:30Z')).toBe('Updated 1 minute ago');
    expect(updated('2026-10-27T08:41:31Z')).toBe('Updated 59 minutes ago');
    expect(updated('2026-10-26T09:41:31Z')).toBe('Updated 23 hours ago');
    expect(updated('2026-10-25T09:41:30Z')).toBe('Updated 2 days ago');
  });
});
