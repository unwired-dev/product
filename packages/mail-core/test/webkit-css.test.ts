import { readFileSync } from 'node:fs';

import { parseDeclarations } from '@private-email/mail-core/inline-style';
import * as Schema from 'effect/Schema';

// How macOS WebKit reads every inline style the sanitizer fixtures use, plus adversarial CSS.
// scripts/record-webkit-css.ts records every property WebKit sets from the style, and each parsed
// declaration with WebKit's serialization of the parsed value alone and of the property after
// WebKit reads the whole style.
const decodeOracle = Schema.decodeSync(
  Schema.fromJsonString(
    Schema.Array(
      Schema.Struct({
        style: Schema.String,
        webkit: Schema.Array(Schema.String),
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

// Properties WebKit sets that the parser leaves out, by style. Each is deliberate strictness:
// escapes that do not decode to a plain identifier, unbounded functions such as calc() or var(),
// strings the attribute end interrupts, or longhands WebKit derives from a declaration the
// sanitizer does not retain. A new omission fails until it is reviewed and listed here.
const reviewedOmissions = new Map<string, readonly string[]>([
  [
    String.raw`display:block;background-image:u\72l(/*);display:none`,
    ['background-image'],
  ],
  ['display:block;font-family:"a\\\r\n/*";display:none;/* */', ['font-family']],
  ['display:block;text-indent:calc(10000px)', ['text-indent']],
  [
    'display:inline-block;letter-spacing:10000px;white-space:nowrap',
    ['text-wrap-mode'],
  ],
  [
    'display:inline-block;line-height:clamp(10000px, 10000px, 10000px)',
    ['line-height'],
  ],
  [
    'display:table;border-spacing:10000px',
    ['-webkit-border-horizontal-spacing', '-webkit-border-vertical-spacing'],
  ],
  [String.raw`font-family:'foo\'';display:none`, ['font-family']],
  [String.raw`font-family:-\31 foo`, ['font-family']],
  ['font-family:"\\61\n/*";display:none', ['font-family']],
  ['font-family:"\\61\r\n/*";display:none', ['font-family']],
  ['font-family:"\\66\noo";display:none', ['font-family']],
  [String.raw`font-family:"a\22 ;display:none"`, ['font-family']],
  ['font-family:"a\\\r\n/*";display:none;*/b";display:block', ['font-family']],
  ['font-family:"foo; font-size:0', ['font-family']],
  [String.raw`font-family:"foo\";display:none`, ['font-family']],
  [String.raw`font-family:"foo\"";display:none`, ['font-family']],
  [String.raw`font-family:"foo\\";display:none`, ['font-family']],
  ['font-family:"foo\\\nbar";display:none', ['font-family']],
  [String.raw`font-family:\31 foo`, ['font-family']],
  [String.raw`font-family:a\3b display\3a none`, ['font-family']],
  [String.raw`font-family:foo\;bar;display:none`, ['font-family']],
  [String.raw`font-family:foo\"bar;display:none`, ['font-family']],
  ['font-size:calc(0px)', ['font-size']],
  [
    'height:200px;min-height:200px;padding-top:100px;padding:100px;margin-top:200px;margin:200px;border-top-width:200px;border-width:200px',
    ['border-right-width', 'border-bottom-width', 'border-left-width'],
  ],
  ['line-height:0;white-space:pre', ['text-wrap-mode']],
  ['line-height:calc(100px + 100px)', ['line-height']],
  ['max-width:calc(1px);max-height:calc(1px)', ['max-width', 'max-height']],
  ['text-indent:-10000px hanging each-line', ['text-indent']],
  ['white-space:nowrap', ['text-wrap-mode']],
  ['white-space:pre', ['text-wrap-mode']],
  ['width:0;height:0;overflow:hidden;white-space:nowrap', ['text-wrap-mode']],
  ['width:var(--missing);height:var(--missing)', ['width', 'height']],
  ['display:none;font-family:"abc', ['font-family']],
  ['font-family:"abc;display:none', ['font-family']],
  ['font-family:"ab\\\nc";display:none', ['font-family']],
  [String.raw`font-family:"a\"b";display:none`, ['font-family']],
  [String.raw`font-family:"a\\";display:none`, ['font-family']],
  [
    String.raw`background:u\72l(a;b);display:none`,
    [
      'background-image',
      'background-position-x',
      'background-position-y',
      'background-size',
      'background-repeat',
      'background-attachment',
      'background-origin',
      'background-clip',
      'background-color',
    ],
  ],
  [
    String.raw`background:url(a\);display:none`,
    [
      'background-image',
      'background-position-x',
      'background-position-y',
      'background-size',
      'background-repeat',
      'background-attachment',
      'background-origin',
      'background-clip',
      'background-color',
    ],
  ],
  [
    String.raw`background:url(a\29;b);display:none`,
    [
      'background-image',
      'background-position-x',
      'background-position-y',
      'background-size',
      'background-repeat',
      'background-attachment',
      'background-origin',
      'background-clip',
      'background-color',
    ],
  ],
  [String.raw`font-family:a\;b;display:none`, ['font-family']],
  [String.raw`font-family:a\"b;display:none`, ['font-family']],
  [String.raw`font-family:a\}b;display:none`, ['font-family']],
  [String.raw`font-size:0\70x`, ['font-size']],
  [String.raw`font-size:0p\78`, ['font-size']],
  [String.raw`opacity:c\61lc(0)`, ['opacity']],
  ['width:calc(100% - 10px)', ['width']],
  [
    String.raw`background:url(a\}b);display:none`,
    [
      'background-image',
      'background-position-x',
      'background-position-y',
      'background-size',
      'background-repeat',
      'background-attachment',
      'background-origin',
      'background-clip',
      'background-color',
    ],
  ],
  [
    String.raw`background:url(a\7d b);display:none`,
    [
      'background-image',
      'background-position-x',
      'background-position-y',
      'background-size',
      'background-repeat',
      'background-attachment',
      'background-origin',
      'background-clip',
      'background-color',
    ],
  ],
]);

// WebKit properties no parsed declaration or its shorthand accounts for.
const omissions = new Map(
  oracle.flatMap(({ style, webkit }) => {
    const names = [...parseDeclarations(style).declared.keys()];
    const omitted = webkit.filter(
      (property) =>
        !names.some(
          (name) => property === name || property.startsWith(`${name}-`),
        ),
    );
    return omitted.length === 0 ? [] : [[style, omitted] as const];
  }),
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
    expect(omissions).toStrictEqual(reviewedOmissions);
  });
});
