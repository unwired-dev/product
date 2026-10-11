import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  copyFile,
  mkdir,
  mkdtemp,
  rm,
  writeFile,
  readFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import manifest from '../package.json' with { type: 'json' };

const root = new URL('../', import.meta.url);
const cli = fileURLToPath(
  new URL(
    '../node_modules/dependency-cruiser/bin/dependency-cruiser.mjs',
    import.meta.url,
  ),
);

// Exercise the installed parser, resolver and repository rules together, without touching workspace sources.
test('package boundaries reject deep imports across source scopes and TypeScript syntax', async () => {
  const directory = await mkdtemp(
    path.join(tmpdir(), 'dependency-boundaries-'),
  );
  const write = async (file, body) => {
    const target = path.join(directory, file);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, body);
  };
  const command = manifest.scripts['lint:boundaries'].split(' ').slice(1);
  const cruise = (...args) =>
    spawnSync(process.execPath, [cli, ...command, ...args], {
      cwd: directory,
      encoding: 'utf8',
    });
  try {
    await copyFile(
      new URL('.dependency-cruiser.cjs', root),
      path.join(directory, '.dependency-cruiser.cjs'),
    );
    await write('.dependency-cruiser-known-violations.json', '[]');
    await mkdir(path.join(directory, 'apps/mobile'), { recursive: true });
    await mkdir(path.join(directory, 'apps/macos'), { recursive: true });
    for (const name of ['one', 'two']) {
      await write(
        `packages/${name}/package.json`,
        '{"exports":{".":"./src/index.ts"}}',
      );
      await write(
        `packages/${name}/src/index.ts`,
        "export { value } from './private.ts';\n",
      );
      await write(
        `packages/${name}/src/private.ts`,
        'export const value = 1;\nexport type Value = number;\n',
      );
    }
    await write('packages/one/test/fixture.ts', 'export const fixture = 1;\n');
    await write(
      'packages/one/test/public.test.ts',
      "import '../src/index.ts';\nimport './fixture.ts';\nimport '../../two/src/index.ts';\n",
    );
    await write(
      'scripts/public.ts',
      "import '../packages/one/src/index.ts';\n",
    );
    assert.equal(cruise().status, 0);
    for (const [file, body, rule] of [
      [
        'scripts/private.ts',
        "import '../packages/one/src/private.ts';\n",
        'entrypoint-boundary-from-app',
      ],
      [
        'apps/mobile/private.ts',
        "import '../../packages/one/src/private.ts';\n",
        'entrypoint-boundary-from-app',
      ],
      [
        'packages/two/src/other.ts',
        "import '../../one/src/private.ts';\n",
        'entrypoint-boundary-across-packages',
      ],
      [
        'packages/one/test/private.test.ts',
        "import type { Value } from '../src/private.ts';\n",
        'tests-through-entrypoints',
      ],
      [
        'packages/one/test/alias.test.ts',
        "type Value = import('../src/private.ts').Value;\n",
        'tests-through-entrypoints',
      ],
      [
        'packages/one/test/private.mts',
        "import '../src/private.ts';\n",
        'tests-through-entrypoints',
      ],
      [
        'packages/one/test/private.cts',
        "import '../src/private.ts';\n",
        'tests-through-entrypoints',
      ],
      [
        'packages/one/src/fixture.ts',
        "import '../test/fixture.ts';\n",
        'tests-folder-is-private',
      ],
      [
        'packages/two/test/fixture.ts',
        "import '../../one/test/fixture.ts';\n",
        'tests-through-entrypoints',
      ],
      ['packages/one/src/cycle.ts', "import './cycle.ts';\n", 'no-circular'],
    ]) {
      await write(file, body);
      const result = cruise();
      assert.notEqual(result.status, 0, `${file} was accepted`);
      assert.ok(
        result.stdout.includes(rule),
        `${file}: ${result.stdout}${result.stderr}`,
      );
      await rm(path.join(directory, file));
    }
    assert.equal(cruise().status, 0);

    // Fixing an old violation must never grandfather a newly introduced one.
    await write('scripts/old.ts', "import '../packages/one/src/private.ts';\n");
    assert.equal(cruise('--baseline').status, 0);
    await rm(path.join(directory, 'scripts/old.ts'));
    await write('scripts/new.ts', "import '../packages/two/src/private.ts';\n");
    assert.equal(
      cruise('--baseline', '--baseline-mode', 'shrink-only').status,
      0,
    );
    const baseline = await readFile(
      path.join(directory, '.dependency-cruiser-known-violations.json'),
      'utf8',
    );
    assert.equal(baseline.trim(), '[]');
    assert.notEqual(cruise('--ignore-known').status, 0);
    await rm(path.join(directory, 'scripts/new.ts'));
    assert.equal(cruise('--ignore-known').status, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
