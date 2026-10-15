/* oxlint-disable node/no-sync -- A short-lived recording script runs its steps in order. */
// Records how macOS WebKit reads each inline style in test/webkit-css.json, beside the declarations
// the sanitizer parses from it. Add a style as `{ "style": "…" }` and rerun on a Mac with
// `pnpm record:webkit-css` (set DEVELOPER_DIR when Xcode is not the selected toolchain).
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { parseDeclarations } from '@private-email/mail-core/inline-style';
import * as Schema from 'effect/Schema';

const oracle = new URL('../test/webkit-css.json', import.meta.url);
const styles = Schema.decodeSync(
  Schema.fromJsonString(Schema.Array(Schema.Struct({ style: Schema.String }))),
)(readFileSync(oracle, 'utf8'));
const parsed = styles.map(({ style }) => [
  style,
  [...parseDeclarations(style).declared],
]);
// For each parsed declaration: WebKit's serialization of the parsed value on its own, and of the
// property after reading the whole style. Also every property WebKit sets from the whole style, so
// declarations the parser omits stay visible.
const judged = execFileSync(
  'swift',
  [fileURLToPath(new URL('webkit-css-oracle.swift', import.meta.url))],
  {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    input: `
const styleOf = (style) => {
  const element = document.createElement('div');
  element.setAttribute('style', style);
  return element.style;
};
return JSON.stringify(${JSON.stringify(parsed)}.map(([style, declared]) => {
  const webkit = styleOf(style);
  return {
    style,
    webkit: Array.from({ length: webkit.length }, (_, index) => webkit[index]),
    declared: declared.map(([name, value]) => {
      const alone = document.createElement('div').style;
      alone.setProperty(name, value);
      return [name, value, alone.getPropertyValue(name), webkit.getPropertyValue(name)];
    }),
  };
}));`,
  },
);
writeFileSync(oracle, judged);
execFileSync('pnpm', ['exec', 'oxfmt', '--write', fileURLToPath(oracle)]);
