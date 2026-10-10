import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const root = fileURLToPath(new URL('..', import.meta.url));
const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const cases = [
  ["export const a = (value: unknown) => typeof value === 'object';", 'guard'],
  ["export const b = (value: unknown) => 'object' !== typeof value;", 'guard'],
  ["export const c = (value: unknown) => typeof value == 'object';", 'guard'],
  ["export const d = (value: unknown) => typeof value === 'string';", null],
  ['export const e = (text: string): unknown => JSON.parse(text);', 'parse'],
  ['export const f = (value: unknown) => JSON.stringify(value);', null],
  ["export const g = (text: string): unknown => JSON['parse'](text);", 'parse'],
  ['export const h = (text: string): unknown => JSON . parse(text);', 'parse'],
  [
    'export const i = (text: string): unknown => JSON/* trusted? */.parse(text);',
    'parse',
  ],
  ['export const j = (value: { parse: () => 1 }) => value.parse();', null],
  ['export class Failure extends Error {}', 'error'],
];
const codes = {
  guard: 'effect-boundaries(no-object-typeof-guard)',
  parse: 'effect-boundaries(no-json-parse)',
  error: 'effecttsgo(extends-native-error)',
};

function boundaryDiagnostics(config, name) {
  const scratchpad = path.join(root, 'scratchpad');
  mkdirSync(scratchpad, { recursive: true });
  const directory = mkdtempSync(path.join(scratchpad, 'effect-boundaries-'));
  try {
    const fixture = path.join(directory, name);
    writeFileSync(fixture, cases.map(([source]) => source).join('\n'));
    const result = spawnSync(
      path.join(root, 'node_modules/.bin/oxlint'),
      ['--config', path.join(root, config), '--format', 'json', fixture],
      { cwd: root, encoding: 'utf8' },
    );
    assert.ifError(result.error);
    const { diagnostics } = parseJson(result.stdout);
    return diagnostics
      .filter((diagnostic) => Object.values(codes).includes(diagnostic.code))
      .map((diagnostic) => [
        diagnostic.labels[0].span.line,
        diagnostic.code,
        diagnostic.severity,
      ])
      .toSorted(([a], [b]) => a - b);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

for (const config of [
  'oxlint.config.ts',
  'apps/mobile/oxlint.config.ts',
  'apps/macos/oxlint.config.ts',
]) {
  for (const name of ['boundaries.ts', 'boundaries.test.tsx']) {
    test(`${config} rejects hand-rolled boundary parsing in ${name}`, () => {
      assert.deepEqual(
        boundaryDiagnostics(config, name),
        cases.flatMap(([, kind], index) =>
          kind === null ? [] : [[index + 1, codes[kind], 'error']],
        ),
      );
    });
  }
}
