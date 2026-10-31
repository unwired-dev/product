import type { SemanticDocument } from '../src/semantic-document.ts';

import { checkDetails } from '../src/assistance.ts';

const whole = (
  text: string,
  body: SemanticDocument = [{ kind: 'paragraph', spans: [{ text }] }],
) => ({ text, draft: { body }, selection: { start: 0, end: text.length } });

describe('the Writing tools detail check', () => {
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
      kept: [
        '8 P.M.',
        'Ana.Kovac@Example.com',
        '40 €',
        'www.example.com/menu_(2026)',
      ],
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

  it('compares whole numbers, bare addresses and link punctuation', () => {
    expect.hasAssertions();
    const changes = (original: string, result: string) =>
      checkDetails(whole(original), result).changes;
    expect(changes('Balance: -40.', 'Balance: 40.')).toStrictEqual([
      { kind: 'number', status: 'changed', original: '-40', result: '40' },
    ]);
    expect(
      changes('Refund -€40 and .5 mg', 'Refund €40 and 5 mg'),
    ).toStrictEqual([
      { kind: 'amount', status: 'changed', original: '-€40', result: '€40' },
      { kind: 'number', status: 'changed', original: '.5', result: '5' },
    ]);
    expect(
      changes('See example.com/old.', 'See example.com/new.'),
    ).toStrictEqual([
      {
        kind: 'link',
        status: 'changed',
        original: 'example.com/old',
        result: 'example.com/new',
      },
    ]);
    expect(
      changes(
        'See https://example.com/approve!',
        'See https://example.com/approve',
      ),
    ).toStrictEqual([
      {
        kind: 'link',
        status: 'changed',
        original: 'https://example.com/approve!',
        result: 'https://example.com/approve',
      },
    ]);
  });

  it('compares dates in any letter case', () => {
    expect.hasAssertions();
    expect(
      checkDetails(whole('Meet MONDAY, 3 NOV.'), 'Meet TUESDAY, 3 NOV.')
        .changes,
    ).toStrictEqual([
      {
        kind: 'date',
        status: 'changed',
        original: 'MONDAY, 3 NOV',
        result: 'TUESDAY, 3 NOV',
      },
    ]);
    // The same signed amount on either side of its currency, and a date in another case, are equal.
    expect(
      checkDetails(whole('Refund -€40 on Monday.'), 'Refund -40 € on MONDAY.'),
    ).toStrictEqual({ kept: ['-€40', 'Monday'], changes: [] });
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
    const text = 'Here is the booking confirmation. Ask the restaurant.';
    const original = {
      text,
      draft: { body },
      selection: { start: 0, end: text.length },
    };
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

  it("decides by a link's own destination", () => {
    expect.hasAssertions();
    // Even where its words show the address without its scheme, or with punctuation that written
    // text would end before.
    const linked = (spans: SemanticDocument[number]['spans']) => {
      const words = spans.map((span) => span.text).join('');
      return whole(words, [{ kind: 'paragraph', spans }]);
    };
    expect(
      checkDetails(
        linked([
          { text: 'See ' },
          { text: 'example.com', link: 'https://example.com/' },
        ]),
        'See example.com',
      ),
    ).toStrictEqual({ kept: ['example.com'], changes: [] });
    expect(
      checkDetails(
        linked([
          { text: 'See ' },
          {
            text: 'https://example.com/approve.',
            link: 'https://example.com/approve.',
          },
        ]),
        'See https://example.com/approve',
      ).changes,
    ).toStrictEqual([
      {
        kind: 'link',
        status: 'removed',
        label: 'https://example.com/approve.',
        original: 'https://example.com/approve.',
      },
    ]);
  });

  it('finds nothing to compare in text without details', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('lets meet soon. thanks'),
        'Let us meet soon. Thanks!',
      ),
    ).toStrictEqual({ kept: [], changes: [] });
  });
});
