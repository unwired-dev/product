import { loadCategorizationFixtures } from '../src/scenario.ts';

describe('categorization scenario corpus', () => {
  it('loads one synthetic fixture for every expected visible outcome', async () => {
    expect.assertions(4);
    const runId = '00000000-0000-0000-0000-000000000001';

    const fixtures = await loadCategorizationFixtures(
      runId,
      new Date('2026-08-10T00:00:00Z'),
    );

    expect(
      fixtures.map(({ expectedCategory, id }) => ({ expectedCategory, id })),
    ).toStrictEqual([
      { expectedCategory: 'People', id: 'people' },
      { expectedCategory: 'Orders', id: 'orders' },
      {
        expectedCategory: 'Newsletters & Promotions',
        id: 'newsletters-promotions',
      },
      { expectedCategory: 'Invites', id: 'invites' },
      { expectedCategory: 'Flights', id: 'flights' },
      { expectedCategory: null, id: 'ambiguous' },
    ]);
    expect(
      fixtures.every((fixture) =>
        fixture.rawMessage.includes(fixture.messageId),
      ),
    ).toBe(true);
    expect(
      fixtures.every((fixture) => !fixture.rawMessage.includes('{{')),
    ).toBe(true);
    expect(
      fixtures.every((fixture) =>
        [...fixture.rawMessage.matchAll(/@[a-z0-9.-]+/giu)].every(
          ([domain]) => domain.toLowerCase() === '@synthetic.invalid',
        ),
      ),
    ).toBe(true);
  });
});
