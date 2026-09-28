import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const cases = [
  ["import * as Effect from 'effect/Effect';", false],
  ["import type * as EffectTypes from 'effect/Effect';", false],
  ["import * as Presets from '@effect/tsgo/oxlint-presets';", false],
  ["import { succeed } from 'effect/Effect';", true],
  ["import type { Effect as EffectType } from 'effect/Effect';", true],
  ["import EffectDefault from 'effect/Effect';", true],
  ["import { Effect as BarrelEffect } from 'effect';", true],
  ["import * as Barrel from 'effect';", true],
  ["import { recommended } from '@effect/tsgo/oxlint-presets';", true],
  ["import 'effect/Effect';", true],
  ["import Default, * as Mixed from 'effect/Effect';", true],
  ["import { readFile } from 'node:fs';", false],
];

for (const config of ['oxlint.config.ts', 'apps/mobile/oxlint.config.ts']) {
  test(`${config} enforces Effect namespace imports`, () => {
    const scratchpad = join(root, 'scratchpad');
    mkdirSync(scratchpad, { recursive: true });
    const directory = mkdtempSync(join(scratchpad, 'effect-import-policy-'));
    try {
      const fixture = join(directory, 'imports.ts');
      writeFileSync(fixture, cases.map(([source]) => source).join('\n'));
      const result = spawnSync(
        join(root, 'node_modules/.bin/oxlint'),
        ['--config', join(root, config), '--format', 'json', fixture],
        { cwd: root, encoding: 'utf8' },
      );
      assert.ifError(result.error);
      assert.equal(result.status, 1, result.stderr);
      const output = JSON.parse(result.stdout);
      const violations = output.diagnostics.filter(
        (diagnostic) => diagnostic.code === 'effect-imports(namespace-imports)',
      );
      assert.deepEqual(
        violations
          .map((diagnostic) => diagnostic.labels[0].span.line)
          .sort((a, b) => a - b),
        cases.flatMap(([, rejected], index) => (rejected ? [index + 1] : [])),
      );
      assert.ok(
        violations.every((diagnostic) => diagnostic.severity === 'error'),
      );
      assert.equal(
        output.diagnostics.filter(
          (diagnostic) =>
            diagnostic.code === 'import(no-namespace)' &&
            [1, 2, 3].includes(diagnostic.labels[0].span.line),
        ).length,
        0,
        'Namespace imports must not conflict with the shared import/no-namespace rule',
      );
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
