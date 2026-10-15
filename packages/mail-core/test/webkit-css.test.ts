import { readFileSync } from 'node:fs';

import { parseDeclarations } from '@private-email/mail-core/inline-style';
import * as Schema from 'effect/Schema';

// How macOS WebKit reads every inline style the sanitizer fixtures use, plus adversarial CSS.
// scripts/record-webkit-css.ts records each parsed declaration with WebKit's serialization of
// the parsed value alone and of the property after WebKit reads the whole style.
const decodeOracle = Schema.decodeSync(
  Schema.fromJsonString(
    Schema.Array(
      Schema.Struct({
        style: Schema.String,
        declared: Schema.Array(
          Schema.Tuple([
            Schema.String,
            Schema.String,
            Schema.String,
            Schema.String,
          ]),
        ),
      }),
    ),
  ),
);
const oracle = decodeOracle(
  readFileSync(new URL('webkit-css.json', import.meta.url), 'utf8'),
);

// The sanitizer orders a shorthand and its longhands itself, after parsing, so WebKit's
// reading of either property alone is not the parser's to match.
const overlaps = (name: string, names: readonly string[]) =>
  names.some(
    (other) =>
      other !== name &&
      (other.startsWith(`${name}-`) || name.startsWith(`${other}-`)),
  );

// Parsed declarations whose value WebKit serializes differently from its own reading of the style.
const disagreements = oracle.flatMap(({ style, declared }) =>
  declared
    .filter(
      ([name, , parsed, webkit]) =>
        parsed !== webkit &&
        !overlaps(
          name,
          declared.map(([other]) => other),
        ),
    )
    .map(([name]) => `${name} in ${style}`),
);

describe('inline style parsing', () => {
  it('reads declarations from sender styles as WebKit does', () => {
    expect.hasAssertions();
    // A difference here means the parser changed: rerun the recorder on a Mac.
    expect(
      oracle.map(({ style }) => [
        style,
        [...parseDeclarations(style).declared],
      ]),
    ).toStrictEqual(
      oracle.map(({ style, declared }) => [
        style,
        declared.map(([name, value]) => [name, value]),
      ]),
    );
    expect(disagreements).toStrictEqual([]);
  });
});
