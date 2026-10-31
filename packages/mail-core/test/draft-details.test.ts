import type { SemanticDocument } from '../src/semantic-document.ts';

import { checkDetails } from '../src/assistance.ts';

const whole = (text: string, body: SemanticDocument = [
  { kind: 'paragraph', spans: [{ text }] },
]) => ({ text, draft: { body }, selection: { start: 0, end: text.length } });

describe('Writing tools detail check', () => {
  it('lists changed, removed and added details and the kept ones', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole(
          'Done — I booked Taberna da Graça for 8 pm on Saturday and paid the €40 deposit. Taxi at 5:30 works. See https://tabernadagraca.pt/r/4821.',
        ),
        'Booked Taberna da Graça for 8 pm Saturday, 1 Nov, and paid the €45 deposit. https://tabernadagraca.pt/r/4812 Questions: reservas@tabernadagraca.pt',
      ),
    ).toStrictEqual({
      kept: ['8 pm'],
      changes: [
        {
          kind: 'date',
          status: 'changed',
          original: 'Saturday',
          result: 'Saturday, 1 Nov',
        },
        { kind: 'amount', status: 'changed', original: '€40', result: '€45' },
        { kind: 'time', status: 'removed', original: '5:30' },
        {
          kind: 'link',
          status: 'changed',
          original: 'https://tabernadagraca.pt/r/4821',
          result: 'https://tabernadagraca.pt/r/4812',
        },
        {
          kind: 'email',
          status: 'added',
          result: 'reservas@tabernadagraca.pt',
        },
      ],
    });
  });

  it('accepts only unambiguous differences in writing', () => {
    expect.hasAssertions();
    // Spacing, letter case, a currency's side and sentence punctuation after a link are equal.
    expect(
      checkDetails(
        whole(
          'Call at 8 P.M. or write to Ana.Kovac@Example.com. It costs 40 € (see www.example.com/menu_(2026)).',
        ),
        'Call at 8pm or write to ana.kovac@example.com; it costs €40, see www.example.com/menu_(2026)',
      ),
    ).toStrictEqual({
      kept: ['8 P.M.', 'Ana.Kovac@Example.com', '40 €', 'www.example.com/menu_(2026)'],
      changes: [],
    });
    // A number written as a word, a regrouped number, a reformatted date and an edited quote
    // stay to compare.
    expect(
      checkDetails(whole('We need 3 rooms.'), 'We need three rooms.').changes,
    ).toStrictEqual([{ kind: 'number', status: 'removed', original: '3' }]);
    expect(
      checkDetails(
        whole('For 1,000 guests on 2026-11-01, “the whole team”.'),
        'For 1000 guests on 1 November 2026, “the team”.',
      ).changes,
    ).toStrictEqual([
      { kind: 'number', status: 'changed', original: '1,000', result: '1000' },
      {
        kind: 'date',
        status: 'changed',
        original: '2026-11-01',
        result: '1 November 2026',
      },
      {
        kind: 'quote',
        status: 'changed',
        original: 'the whole team',
        result: 'the team',
      },
    ]);
  });

  it('keeps the destinations of selected links that their words do not show', () => {
    expect.hasAssertions();
    const body: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [
          { text: 'Here is the ' },
          {
            text: 'booking',
            link: 'https://tabernadagraca.pt/r/4821',
            marks: ['bold'],
          },
          { text: ' confirmation', link: 'https://tabernadagraca.pt/r/4821' },
          { text: '. Ask ' },
          { text: 'the restaurant', link: 'mailto:reservas@tabernadagraca.pt' },
          { text: '.' },
        ],
      },
      {
        kind: 'paragraph',
        spans: [{ text: 'Not selected', link: 'https://example.com/' }],
      },
    ];
    const text =
      'Here is the booking confirmation. Ask the restaurant.';
    const original = { text, draft: { body }, selection: { start: 0, end: text.length } };
    // Plain result text cannot carry a link, so it is removed unless written out.
    expect(
      checkDetails(original, 'The booking confirmation is attached.'),
    ).toStrictEqual({
      kept: [],
      changes: [
        {
          kind: 'link',
          status: 'removed',
          label: 'booking confirmation',
          original: 'https://tabernadagraca.pt/r/4821',
        },
        {
          kind: 'email',
          status: 'removed',
          label: 'the restaurant',
          original: 'reservas@tabernadagraca.pt',
        },
      ],
    });
    expect(
      checkDetails(
        original,
        'Booking: https://tabernadagraca.pt/r/4821. Ask reservas@tabernadagraca.pt.',
      ),
    ).toStrictEqual({
      kept: ['https://tabernadagraca.pt/r/4821', 'reservas@tabernadagraca.pt'],
      changes: [],
    });
  });

  it('finds nothing to compare in text without details', () => {
    expect.hasAssertions();
    expect(
      checkDetails(whole('lets meet soon. thanks'), 'Let us meet soon. Thanks!'),
    ).toStrictEqual({ kept: [], changes: [] });
  });
});
