import type { DetailChange } from '@private-email/mail-core/assistance';
import type { SemanticDocument } from '@private-email/mail-core/semantic-document';

import { checkDetails } from '@private-email/mail-core/assistance';

const whole = (
  text: string,
  body: SemanticDocument = [{ kind: 'paragraph', spans: [{ text }] }],
) => ({ text, draft: { body }, selection: { start: 0, end: text.length } });

describe('the Writing tools detail check', () => {
  it('lists changed, removed and added details and the kept ones', () => {
    expect.hasAssertions();
    // Callers can read the compared values after narrowing the reported outcome.
    expectTypeOf<DetailChange>()
      .extract<{ status: 'changed' | 'uncertain' }>()
      .toHaveProperty('result')
      .toBeString();
    expectTypeOf<DetailChange>()
      .extract<{ status: 'removed' }>()
      .toHaveProperty('original')
      .toBeString();
    expectTypeOf<DetailChange>()
      .extract<{ status: 'added' }>()
      .toHaveProperty('result')
      .toBeString();
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
          status: 'uncertain',
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
    // A number written as a word is removed; a regrouped number and a reformatted date may be the
    // same and stay uncertain; an edited quote changed.
    expect(
      checkDetails(whole('We need 3 rooms.'), 'We need three rooms.').changes,
    ).toStrictEqual([{ kind: 'number', status: 'removed', original: '3' }]);
    expect(
      checkDetails(
        whole('For 1,000 guests on 2026-11-01, “the whole team”.'),
        'For 1000 guests on 1 November 2026, “the team”.',
      ).changes,
    ).toStrictEqual([
      {
        kind: 'number',
        status: 'uncertain',
        original: '1,000',
        result: '1000',
      },
      {
        kind: 'date',
        status: 'uncertain',
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
        status: 'uncertain',
        original: 'https://example.com/approve!',
        result: 'https://example.com/approve',
      },
    ]);
  });

  it('compares compact currency codes as complete amounts', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('Pay 40USD, USD40, $40USD or USD-40.'),
        'Pay 40EUR, EUR40, €40USD or USD+40.',
      ).changes,
    ).toStrictEqual([
      { kind: 'amount', status: 'changed', original: '40USD', result: '40EUR' },
      { kind: 'amount', status: 'changed', original: 'USD40', result: 'EUR40' },
      {
        kind: 'amount',
        status: 'changed',
        original: '$40USD',
        result: '€40USD',
      },
      {
        kind: 'amount',
        status: 'changed',
        original: 'USD-40',
        result: 'USD+40',
      },
    ]);
  });

  it('compares complete bare addresses with ports', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('See example.com:8080/old and www.example.com:8080/old.'),
        'See example.com:8080/new and www.example.com:8080/new.',
      ).changes,
    ).toStrictEqual([
      {
        kind: 'link',
        status: 'changed',
        original: 'example.com:8080/old',
        result: 'example.com:8080/new',
      },
      {
        kind: 'link',
        status: 'changed',
        original: 'www.example.com:8080/old',
        result: 'www.example.com:8080/new',
      },
    ]);
  });

  it('keeps a plain difference changed and a possible equivalent uncertain', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('Pay €1,500 or 1.5 units on Monday at example.com/pay?'),
        'Pay €1500 or 2 units on Tuesday at example.com/pay',
      ).changes,
    ).toStrictEqual([
      {
        kind: 'amount',
        status: 'uncertain',
        original: '€1,500',
        result: '€1500',
      },
      { kind: 'number', status: 'changed', original: '1.5', result: '2' },
      {
        kind: 'date',
        status: 'changed',
        original: 'Monday',
        result: 'Tuesday',
      },
      {
        kind: 'link',
        status: 'uncertain',
        original: 'example.com/pay?',
        result: 'example.com/pay',
      },
    ]);
  });

  it('reads an all-caps month after a day as a date and compares days as whole figures', () => {
    expect.hasAssertions();
    const changes = (original: string, result: string) =>
      checkDetails(whole(original), result).changes;
    expect(changes('See you 3 NOV.', 'See you 3 Nov.')).toStrictEqual([]);
    expect(changes('See you 3 Nov.', 'See you 13 Nov.')).toStrictEqual([
      { kind: 'date', status: 'changed', original: '3 Nov', result: '13 Nov' },
    ]);
    expect(changes('Due 1/11/2026.', 'Due 11/11/2026.')).toStrictEqual([
      {
        kind: 'date',
        status: 'changed',
        original: '1/11/2026',
        result: '11/11/2026',
      },
    ]);
    expect(changes('Due 2026-11-01.', 'Due 2026-11-01, Sunday.')).toStrictEqual(
      [{ kind: 'date', status: 'added', result: 'Sunday' }],
    );
  });

  it('keeps an added or removed year uncertain without matching part of a day or year', () => {
    expect.hasAssertions();
    for (const [original, result, status] of [
      ['3 Nov', '3 Nov 2026', 'uncertain'],
      ['3 Nov 2026', '3 Nov', 'uncertain'],
      ['Nov 3', 'Nov 3 2026', 'uncertain'],
      ['Nov 3 2026', 'Nov 3', 'uncertain'],
      ['Nov 3', 'Nov 31', 'changed'],
      ['3 Nov 2026', '3 Nov 2027', 'changed'],
    ] as const) {
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind: 'date', status, original, result }],
      });
    }
  });

  it('preserves complete amounts when dates take precedence', () => {
    expect.hasAssertions();
    for (const [original, result] of [
      ['€1.50', '€1.60'],
      ['1.500 CZK', '1.600 CZK'],
      ['12.10 EUR', '12.20 EUR'],
    ] as const) {
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind: 'amount', status: 'changed', original, result }],
      });
    }
  });

  it('compares numbers with exponents and addresses with punycode labels', () => {
    expect.hasAssertions();
    const changes = (original: string, result: string) =>
      checkDetails(whole(original), result).changes;
    expect(
      changes('The limit is 1e3 units.', 'The limit is 1e4 units.'),
    ).toStrictEqual([
      { kind: 'number', status: 'changed', original: '1e3', result: '1e4' },
    ]);
    expect(
      changes('Order at shop.xn--p1ai/old.', 'Order at shop.xn--p1ai/new.'),
    ).toStrictEqual([
      {
        kind: 'link',
        status: 'changed',
        original: 'shop.xn--p1ai/old',
        result: 'shop.xn--p1ai/new',
      },
    ]);
  });

  it('distinguishes an amount sign from its exponent sign', () => {
    expect.hasAssertions();
    for (const [original, result] of [
      ['$1e-3', '-$1e-3'],
      ['$1e-3', '$-1e-3'],
      ['1e-3 USD', '-1e-3 USD'],
      ['USD1E-3', 'USD-1E-3'],
    ] as const) {
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind: 'amount', status: 'changed', original, result }],
      });
    }
    expect(checkDetails(whole('-$1e-3'), '-1e-3 $')).toStrictEqual({
      kept: ['-$1e-3'],
      changes: [],
    });
  });

  it('recognizes web schemes and punycode prefixes in any letter case', () => {
    expect.hasAssertions();
    for (const address of ['shop.XN--P1AI', 'HTTPS://127.0.0.1']) {
      const original = `${address}/old`;
      const result = `${address}/new`;
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind: 'link', status: 'changed', original, result }],
      });
    }
  });

  it('reads complete signed exponents without interpreting ordinary word suffixes or identifiers', () => {
    expect.hasAssertions();
    for (const [original, result] of [
      ['1E+3', '1E+4'],
      ['.5e-3', '.5e-4'],
      ['-1e3s', '-1e4s'],
    ] as const) {
      expect(checkDetails(whole(original), result).changes).toStrictEqual([
        {
          kind: 'number',
          status: 'changed',
          original: original.replace(/s$/u, ''),
          result: result.replace(/s$/u, ''),
        },
      ]);
    }
    for (const [original, result, kept] of [
      ['3e place', '3e rue', ['3']],
      ['2e-mail', '2e-letter', ['2']],
      ['0x1e3', '0x1e4', ['0']],
      ['ref1e3', 'ref1e4', []],
    ] as const) {
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept,
        changes: [],
      });
    }
  });

  it('compares a whole number beside its unit and ordinal dates in capitals', () => {
    expect.hasAssertions();
    const changes = (original: string, result: string) =>
      checkDetails(whole(original), result).changes;
    expect(changes('Wait 0.5s.', 'Wait 0.6s.')).toStrictEqual([
      { kind: 'number', status: 'changed', original: '0.5', result: '0.6' },
    ]);
    expect(changes('Meet NOV 3RD.', 'Meet NOV 4TH.')).toStrictEqual([
      {
        kind: 'date',
        status: 'changed',
        original: 'NOV 3RD',
        result: 'NOV 4TH',
      },
    ]);
    expect(changes('Meet 3RD NOV.', 'Meet 4TH NOV.')).toStrictEqual([
      {
        kind: 'date',
        status: 'changed',
        original: '3RD NOV',
        result: '4TH NOV',
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

  it.each([
    {
      text: 'https://example.com/reviewed',
      href: 'https://example.com/review',
      kind: 'link',
      originalTarget: 'https://example.com/review',
    },
    {
      text: 'https://example.com/review',
      href: 'https://example.com/review/',
      kind: 'link',
      originalTarget: 'https://example.com/review/',
    },
    {
      text: 'otherana@example.com',
      href: 'mailto:ana@example.com',
      kind: 'email',
      originalTarget: 'ana@example.com',
    },
    {
      text: 'ana@example.com',
      href: 'mailto:ana@example.com?cc=other@example.com',
      kind: 'link',
      originalTarget: 'mailto:ana@example.com?cc=other@example.com',
    },
  ] as const)(
    'keeps the full destination of $text visible for review',
    ({ text, href, kind, originalTarget }) => {
      expect.hasAssertions();
      const original = whole(text, [
        { kind: 'paragraph', spans: [{ text, link: href }] },
      ]);
      expect(checkDetails(original, text).changes).toStrictEqual([
        {
          kind,
          status: 'removed',
          label: text,
          original: originalTarget,
        },
      ]);
    },
  );

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
