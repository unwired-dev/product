import schema from '../convex/schema.js';

describe('convex schema identifiers', () => {
  // Convex rejects these index names only at deployment.
  it('uses index names the deployment accepts', () => {
    expect.assertions(2);

    const indexNames = Object.values(schema.tables).flatMap((table) =>
      table[' indexes']().map(({ indexDescriptor }) => indexDescriptor),
    );

    expect(indexNames).toContain('by_tokenIdentifier');
    expect(
      indexNames.filter(
        (indexName) => !/^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(indexName),
      ),
    ).toStrictEqual([]);
  });
});
