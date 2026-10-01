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
  ["export const g = (text: string): unknown => JSON['parse'](text);", null],
  ['export class Failure extends Error {}', 'error'],
];
const codes = {
  guard: 'effect-boundaries(no-object-typeof-guard)',
  parse: 'effect-boundaries(no-json-parse)',
  error: 'effecttsgo(extends-native-error)',
};

for (const [config, fixtureDirectory] of [
  ['oxlint.config.ts', 'packages/mail-core/src'],
  ['apps/mobile/oxlint.config.ts', 'apps/mobile/src'],
  ['apps/macos/oxlint.config.ts', 'apps/macos/src'],
]) {
  test(`${config} rejects hand-rolled boundary parsing`, () => {
    const scratchpad = join(root, 'scratchpad');
    mkdirSync(scratchpad, { recursive: true });
    const directory = mkdtempSync(join(scratchpad, 'effect-boundaries-'));
    try {
      const fixture = join(directory, 'boundaries.ts');
      writeFileSync(fixture, cases.map(([source]) => source).join('\n'));
      const result = spawnSync(
        join(root, 'node_modules/.bin/oxlint'),
        ['--config', join(root, config), '--format', 'json', fixture],
        { cwd: join(root, fixtureDirectory), encoding: 'utf8' },
      );
      assert.ifError(result.error);
      assert.equal(result.status, 1, result.stderr);
      const { diagnostics } = JSON.parse(result.stdout);
      const reported = diagnostics
        .filter((diagnostic) => Object.values(codes).includes(diagnostic.code))
        .map((diagnostic) => [
          diagnostic.labels[0].span.line,
          diagnostic.code,
          diagnostic.severity,
        ])
        .sort(([a], [b]) => a - b);
      assert.deepEqual(
        reported,
        cases.flatMap(([, kind], index) =>
          kind === null ? [] : [[index + 1, codes[kind], 'error']],
        ),
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
