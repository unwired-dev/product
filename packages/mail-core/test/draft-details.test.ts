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

  it('reads ambiguous lowercase standalone names as words', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole(
          'You may want to march on, sat by the sun. An august guest watched.',
        ),
        'You might want to go on. An esteemed guest watched.',
      ).changes,
    ).toStrictEqual([]);
    expect(
      checkDetails(whole('See you in May.'), 'See you in June.').changes,
    ).toStrictEqual([
      { kind: 'date', status: 'changed', original: 'May', result: 'June' },
    ]);
  });

  it.each([
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ])('flags a removed lowercase full weekday: %s', (weekday) => {
    expect.hasAssertions();
    expect(
      checkDetails(whole(`Meet on ${weekday}.`), 'Meet soon.').changes,
    ).toStrictEqual([{ kind: 'date', status: 'removed', original: weekday }]);
    expect(
      checkDetails(
        whole(`Meet on ${weekday}.`),
        `Meet on ${weekday.toUpperCase()}.`,
      ),
    ).toStrictEqual({ kept: [weekday], changes: [] });
  });

  it('compares a lowercase month with its year as a complete date', () => {
    expect.hasAssertions();
    expect(
      checkDetails(whole('Due in may 2026.'), 'Due in june 2026.').changes,
    ).toStrictEqual([
      {
        kind: 'date',
        status: 'changed',
        original: 'may 2026',
        result: 'june 2026',
      },
    ]);
    expect(
      checkDetails(whole('Due in november 2026.'), 'Due in November 2026.'),
    ).toStrictEqual({ kept: ['november 2026'], changes: [] });
  });

  it.each([
    'january',
    'february',
    'april',
    'june',
    'july',
    'september',
    'october',
    'november',
    'december',
  ])('flags a removed unambiguous lowercase month: %s', (month) => {
    expect.hasAssertions();
    expect(
      checkDetails(whole(`Meet in ${month}.`), 'Meet soon.').changes,
    ).toStrictEqual([{ kind: 'date', status: 'removed', original: month }]);
    expect(
      checkDetails(
        whole(`Meet in ${month}.`),
        `Meet in ${month.toUpperCase()}.`,
      ),
    ).toStrictEqual({ kept: [month], changes: [] });
  });

  it('compares yearless dates, addresses with apostrophes and quotes across lines whole', () => {
    expect.hasAssertions();
    const changes = (original: string, result: string) =>
      checkDetails(whole(original), result).changes;
    expect(changes('Meet on 11/01.', 'Meet on 01/11.')).toStrictEqual([
      { kind: 'date', status: 'changed', original: '11/01', result: '01/11' },
    ]);
    expect(
      changes(
        "Write to o'connor@example.com.",
        "Write to d'connor@example.com.",
      ),
    ).toStrictEqual([
      {
        kind: 'email',
        status: 'changed',
        original: "o'connor@example.com",
        result: "d'connor@example.com",
      },
    ]);
    expect(
      changes("Write to 'bob@example.com'.", 'Write to bob@example.com.'),
    ).toStrictEqual([]);
    expect(
      changes(
        'He said “Please approve\nthe full budget”.',
        'He said “Please reject\nthe full budget”.',
      ),
    ).toStrictEqual([
      {
        kind: 'quote',
        status: 'changed',
        original: 'Please approve\nthe full budget',
        result: 'Please reject\nthe full budget',
      },
    ]);
  });

  it.each([
    { kind: 'email', original: 'a!!b@example.com', result: 'c!!b@example.com' },
    { kind: 'email', original: '!bob@example.com', result: '?bob@example.com' },
    {
      kind: 'link',
      original: 'mailto:bob@example.com?subject=Approve',
      result: 'mailto:bob@example.com?subject=Reject',
    },
    { kind: 'time', original: '12:30 UTC', result: '12:30 PST' },
    { kind: 'time', original: '12:30+01:00', result: '12:30-01:00' },
    { kind: 'time', original: '12:30:45.5', result: '12:30:45.6' },
    { kind: 'date', original: '2026/11/01', result: '2026/01/11' },
    {
      kind: 'link',
      original: 'example.com/A@b.com',
      result: 'example.com/a@b.com',
    },
    {
      kind: 'link',
      original: 'example.com/?x=A@b.com',
      result: 'example.com/?x=a@b.com',
    },
    { kind: 'date', original: 'Mon', result: 'Tue' },
    { kind: 'date', original: 'NOV', result: 'DEC' },
    { kind: 'date', original: 'MAY 3', result: 'MAY 4' },
    { kind: 'date', original: '3 may', result: '4 may' },
    { kind: 'date', original: 'November', result: 'December' },
    { kind: 'number', original: '100/200', result: '200/100' },
    { kind: 'number', original: '1.5/2.5', result: '2.5/1.5' },
    { kind: 'number', original: '1–2', result: '2–1' },
    { kind: 'number', original: '11-01', result: '01-11' },
    { kind: 'number', original: '100:200', result: '200:100' },
    { kind: 'number', original: '10%', result: '10' },
  ] satisfies ReadonlyArray<{
    kind: DetailChange['kind'];
    original: string;
    result: string;
  }>)(
    'compares the complete $kind detail $original',
    ({ kind, original, result }) => {
      expect.hasAssertions();
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind, status: 'changed', original, result }],
      });
    },
  );

  it('compares each month and year as one date before matching occurrences', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('November 2026 and December 2027'),
        'November 2027 and December 2026',
      ),
    ).toStrictEqual({
      kept: [],
      changes: [
        {
          kind: 'date',
          status: 'changed',
          original: 'November 2026',
          result: 'November 2027',
        },
        {
          kind: 'date',
          status: 'changed',
          original: 'December 2027',
          result: 'December 2026',
        },
      ],
    });
  });

  it('keeps grouping separate from ordinary spacing when comparing numbers and amounts', () => {
    expect.hasAssertions();
    expect(checkDetails(whole('1 500'), '500 1').changes).not.toStrictEqual([]);
    expect(checkDetails(whole('1 500'), '1500').changes).toStrictEqual([
      {
        kind: 'number',
        status: 'uncertain',
        original: '1 500',
        result: '1500',
      },
    ]);
    expect(checkDetails(whole('€1\u202F500'), '€1500').changes).toStrictEqual([
      {
        kind: 'amount',
        status: 'uncertain',
        original: '€1\u202F500',
        result: '€1500',
      },
    ]);
    expect(
      checkDetails(
        whole('1 / 200 and 12:30 P.M. UTC and 10 %'),
        '1/200 and 12:30pm UTC and 10%',
      ).changes,
    ).toStrictEqual([]);
  });

  it('does not let an inch mark consume the next quoted passage across lines', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('Use 12" pipe.\nHe said "approve".'),
        'Use 12" pipe.\nHe said "reject".',
      ),
    ).toStrictEqual({
      kept: ['12'],
      changes: [
        {
          kind: 'quote',
          status: 'changed',
          original: 'approve',
          result: 'reject',
        },
      ],
    });
    expect(
      checkDetails(
        whole('Use 12" pipe.\nThen 6" pipe.'),
        'Use 12" pipe.\nThen 6" pipe.',
      ).kept,
    ).toStrictEqual(['12', '6']);
  });

  it.each(['" approve "', '"\napprove\n"'])(
    'compares quoted words with whitespace at their edges: %s',
    (original) => {
      expect.hasAssertions();
      expect(
        checkDetails(whole(original), original.replace('approve', 'reject'))
          .changes,
      ).toStrictEqual([
        {
          kind: 'quote',
          status: 'changed',
          original: 'approve',
          result: 'reject',
        },
      ]);
    },
  );

  it('compares a whole email address whose local part has dots', () => {
    expect.hasAssertions();
    expect(
      checkDetails(
        whole('Write to first.last+tag@example.com.'),
        'Write to first.last_tag@example.com.',
      ).changes,
    ).toStrictEqual([
      {
        kind: 'email',
        status: 'changed',
        original: 'first.last+tag@example.com',
        result: 'first.last_tag@example.com',
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

  it('compares the complete date, time and zone of an ISO timestamp', () => {
    expect.hasAssertions();
    for (const [original, result] of [
      ['2026-11-01T12:30Z', '2026-11-01T13:30Z'],
      ['2026-11-01T12:30+01:00', '2026-11-01T12:30+02:00'],
      ['2026-11-01T12:30+01', '2026-11-01T12:30-01'],
      ['2026-11-01T12:30+0100', '2026-11-01T12:30-0100'],
      ['2026-11-01T12:30:00.125Z', '2026-11-01T12:30:00.126Z'],
      ['2026-11-01t12:30z', '2026-11-01t13:30z'],
    ] as const) {
      expect(checkDetails(whole(original), result)).toStrictEqual({
        kept: [],
        changes: [{ kind: 'date', status: 'changed', original, result }],
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
