import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
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
  const scratchpad = join(root, 'scratchpad');
  mkdirSync(scratchpad, { recursive: true });
  const directory = mkdtempSync(join(scratchpad, 'effect-boundaries-'));
  try {
    const fixture = join(directory, name);
    writeFileSync(fixture, cases.map(([source]) => source).join('\n'));
    const result = spawnSync(
      join(root, 'node_modules/.bin/oxlint'),
      ['--config', join(root, config), '--format', 'json', fixture],
      { cwd: root, encoding: 'utf8' },
    );
    assert.ifError(result.error);
    const { diagnostics } = JSON.parse(result.stdout);
    return diagnostics
      .filter((diagnostic) => Object.values(codes).includes(diagnostic.code))
      .map((diagnostic) => [
        diagnostic.labels[0].span.line,
        diagnostic.code,
        diagnostic.severity,
      ])
      .sort(([a], [b]) => a - b);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

for (const config of [
  'oxlint.config.ts',
  'apps/mobile/oxlint.config.ts',
  'apps/macos/oxlint.config.ts',
]) {
  test(`${config} rejects hand-rolled boundary parsing`, () => {
    assert.deepEqual(
      boundaryDiagnostics(config, 'boundaries.ts'),
      cases.flatMap(([, kind], index) =>
        kind === null ? [] : [[index + 1, codes[kind], 'error']],
      ),
    );
  });

  test(`${config} exempts tests, which read trusted fixtures`, () => {
    assert.deepEqual(boundaryDiagnostics(config, 'boundaries.test.tsx'), []);
  });
}
