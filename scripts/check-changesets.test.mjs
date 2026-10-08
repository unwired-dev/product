import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));

// fallow-ignore-next-line complexity -- One fixture workspace exercises every accepted and rejected target form.
test('the target gate uses Changesets YAML semantics and the configured workspace', () => {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const fixture = mkdtempSync(path.join(root, 'scratchpad/changeset-gate-'));
  try {
    for (const directory of [
      'scripts',
      '.changeset',
      'apps/mobile',
      'apps/excluded',
      'packages/nested/core',
    ]) {
      mkdirSync(path.join(fixture, directory), { recursive: true });
    }
    symlinkSync(
      path.join(root, 'node_modules'),
      path.join(fixture, 'node_modules'),
    );
    copyFileSync(
      path.join(root, 'scripts/check-changesets.mjs'),
      path.join(fixture, 'scripts/check-changesets.mjs'),
    );
    writeFileSync(
      path.join(fixture, 'package.json'),
      JSON.stringify({ name: '@root/fixture', private: true }),
    );
    writeFileSync(
      path.join(fixture, 'pnpm-workspace.yaml'),
      'packages:\n  - apps/mobile\n  - packages/nested/*\n',
    );
    for (const [directory, name] of [
      ['apps/mobile', '@fixture/mobile'],
      ['apps/excluded', '@fixture/excluded'],
      ['packages/nested/core', '@fixture/core'],
    ]) {
      writeFileSync(
        path.join(fixture, directory, 'package.json'),
        JSON.stringify({ name, version: '0.1.0' }),
      );
    }
    const cases = [
      ['---\n---\nNo package changes\n', 0],
      ['---\n{ "@fixture/core": patch }\n---\nNested member\n', 0],
      [
        '---\n{ "@deleted/host": patch }\n---\nBad target\n',
        1,
        '@deleted/host',
      ],
      [
        '---\n"@fixture/excluded": patch\n---\nExcluded app\n',
        1,
        '@fixture/excluded',
      ],
      [
        '---\n"@root/fixture": patch\n---\nRoot is not a member\n',
        1,
        '@root/fixture',
      ],
      ['---\n"@fixture/mobile": banana\n---\nBad type\n', 1, 'banana'],
      ['---\n{ broken\n---\nBad YAML\n', 1, 'invalid YAML'],
    ];
    for (const [contents, status, message] of cases) {
      writeFileSync(path.join(fixture, '.changeset/probe.md'), contents);
      const result = spawnSync(
        process.execPath,
        ['scripts/check-changesets.mjs'],
        { cwd: fixture, encoding: 'utf8' },
      );
      assert.equal(result.status, status, result.stderr);
      if (message) {
        assert.ok(result.stderr.includes('probe.md'), result.stderr);
        assert.ok(result.stderr.includes(message), result.stderr);
      }
    }
    // Versioning reads prerelease changesets too, skipping only exact agent-guide names.
    writeFileSync(path.join(fixture, '.changeset/probe.md'), '---\n---\n');
    mkdirSync(path.join(fixture, '.changeset/pre'));
    writeFileSync(
      path.join(fixture, '.changeset/pre/agents.md'),
      '---\n"@deleted/host": patch\n---\nBad prerelease target\n',
    );
    const prerelease = spawnSync(
      process.execPath,
      ['scripts/check-changesets.mjs'],
      { cwd: fixture, encoding: 'utf8' },
    );
    assert.equal(prerelease.status, 1, prerelease.stderr);
    assert.ok(prerelease.stderr.includes('pre/agents.md'), prerelease.stderr);
    // The Release workflow drops empty changesets so they cannot block a
    // merged version PR's release; targeted ones stay and are still checked.
    writeFileSync(
      path.join(fixture, '.changeset/host.md'),
      '---\n"@fixture/mobile": patch\n---\nHost\n',
    );
    const drop = spawnSync(
      process.execPath,
      ['scripts/check-changesets.mjs', '--drop-empty'],
      { cwd: fixture, encoding: 'utf8' },
    );
    assert.equal(drop.status, 1, drop.stderr);
    assert.equal(existsSync(path.join(fixture, '.changeset/probe.md')), false);
    assert.ok(existsSync(path.join(fixture, '.changeset/host.md')));
    assert.ok(existsSync(path.join(fixture, '.changeset/pre/agents.md')));
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
