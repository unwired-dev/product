import {
  createLocalization,
  createMessageListDateFormats,
  lastUpdated,
  messageDay,
} from '../src/index.ts';

// The list groups rows by the UTC day they arrived, the day their listed times use.
describe('message list days', () => {
  const now = Date.parse('2026-10-13T09:41:00Z');

  it('names each arrival day relative to now and keeps the week before the earlier months', () => {
    expect.hasAssertions();
    expect(messageDay('2026-10-13T00:00:00Z', now)).toBe('today');
    expect(messageDay('2026-10-13T23:59:59Z', now)).toBe('today');
    expect(messageDay('2026-10-12T23:59:59Z', now)).toBe('yesterday');
    expect(messageDay('2026-10-07T00:00:00Z', now)).toBe('lastWeek');
    expect(messageDay('2026-10-06T23:59:59Z', now)).toBe('earlier');
  });

  it('keeps a message dated ahead of this device clock in today', () => {
    expect.hasAssertions();
    expect(messageDay('2026-10-14T01:00:00Z', now)).toBe('today');
  });

  it('formats a row time, a weekday and a month that names its year once it is not this one', () => {
    expect.hasAssertions();
    const formats = createMessageListDateFormats('en-GB');
    expect(formats.time.format(new Date('2026-10-13T09:41:00Z'))).toMatch(
      /^0?9:41$/u,
    );
    expect(formats.weekday.format(new Date('2026-10-08T12:00:00Z'))).toBe(
      'Thursday',
    );
    expect(formats.month(new Date('2026-09-03T12:00:00Z'), now)).toBe(
      'September',
    );
    expect(formats.month(new Date('2025-12-03T12:00:00Z'), now)).toBe(
      'December 2025',
    );
  });
});

// The Inbox subtitle names when the shown Inboxes were last all brought up to date.
describe('last update', () => {
  const now = Date.parse('2026-10-27T09:41:30Z');
  const { t } = createLocalization(
    { preference: null, language: 'en', locale: 'en-GB' },
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
