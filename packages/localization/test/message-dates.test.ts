import { createMessageListDateFormats, messageDay } from '../src/index.ts';

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
