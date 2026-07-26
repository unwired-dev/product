import { readFileSync } from 'node:fs';

describe('convex schema identifiers', () => {
  it('uses valid index names', () => {
    expect.assertions(1);

    const schemaSource = readFileSync(
      new URL('../convex/schema.ts', import.meta.url),
      'utf8',
    );
    const invalidIndexNames = [
      ...schemaSource.matchAll(/\.index\(\s*['"](?<indexName>[^'"]+)['"]/gu),
    ]
      .map((match) => match.groups?.indexName)
      .filter((indexName): indexName is string => indexName !== undefined)
      .filter((indexName) => !/^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(indexName));

    expect(invalidIndexNames).toStrictEqual([]);
  });
});
