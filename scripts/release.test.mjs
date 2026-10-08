import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const root = fileURLToPath(new URL('../', import.meta.url));
const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

// The release workflow's changesets/action calls these scripts. The action's
// own branch, pull request, tag and GitHub Release handling is not exercised.
function fixture() {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(path.join(root, 'scratchpad/release-'));
  const cwd = path.join(directory, 'checkout');
  const write = (file, contents) => {
    mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
    writeFileSync(path.join(cwd, file), contents);
  };
  const hosts = (mobile, macos = mobile) => {
    for (const [host, version] of [
      ['mobile', mobile],
      ['macos', macos],
    ]) {
      write(
        `apps/${host}/package.json`,
        JSON.stringify({
          name: `@private-email/${host}`,
          version,
          private: true,
        }),
      );
    }
  };
  const version = (host) =>
    parseJson(readFileSync(path.join(cwd, `apps/${host}/package.json`), 'utf8'))
      .version;
  write(
    'package.json',
    JSON.stringify({ name: '@fixture/root', private: true }),
  );
  write('pnpm-workspace.yaml', 'packages:\n  - apps/*\n  - packages/*\n');
  write(
    '.changeset/config.json',
    JSON.stringify({
      changelog: false,
      commit: false,
      fixed: [['@private-email/mobile', '@private-email/macos']],
      linked: [],
      access: 'restricted',
      baseBranch: 'main',
      updateInternalDependencies: 'patch',
      ignore: [],
      privatePackages: { version: true, tag: false },
    }),
  );
  write(
    'packages/convex/package.json',
    JSON.stringify({
      name: '@private-email/convex',
      private: true,
      version: '0.0.0',
    }),
  );
  hosts('0.1.0');
  for (const script of ['release-version.sh', 'release-tag.sh']) {
    write(`scripts/${script}`, '');
    copyFileSync(
      path.join(root, 'scripts', script),
      path.join(cwd, 'scripts', script),
    );
  }
  symlinkSync(path.join(root, 'node_modules'), path.join(cwd, 'node_modules'));
  const bin = path.join(directory, 'bin');
  mkdirSync(bin);
  // Exercise real Changesets; only the GitHub API is a fake boundary.
  writeFileSync(
    path.join(bin, 'pnpm'),
    `#!/bin/sh\nexec "${process.execPath}" "${path.join(root, 'node_modules/@changesets/cli/bin.js')}" version\n`,
    { mode: 0o755 },
  );
  writeFileSync(
    path.join(bin, 'gh'),
    `#!/usr/bin/env node
const a = process.argv.slice(2), env = process.env;
if (env.RELEASE_TEST_API_FAILURE === '1') process.exit(1);
if (a.some(x => x.includes('/git/ref/heads/main'))) { console.log(env.RELEASE_TEST_MAIN_SHA || env.GITHUB_SHA); process.exit(0); }
if (a.some(x => x.includes('/commits/'))) { if (env.RELEASE_TEST_UNMERGED !== '1') console.log(7); process.exit(0); }
if (a.some(x => x.includes('/matching-refs/'))) { if (env.RELEASE_TEST_TAG) console.log(env.RELEASE_TEST_TAG); process.exit(0); }
process.exit(2);
`,
    { mode: 0o755 },
  );
  const run = (script, env = {}) => {
    const output = path.join(directory, 'changesets-output.ndjson');
    writeFileSync(output, '');
    const result = spawnSync('bash', [`scripts/${script}`], {
      cwd,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GITHUB_SHA: 'merge',
        GITHUB_REPOSITORY: 'fixture/product',
        CHANGESETS_OUTPUT: output,
        ...env,
      },
    });
    return { ...result, output: readFileSync(output, 'utf8') };
  };
  return {
    cwd,
    hosts,
    version,
    write,
    run,
    close: () => rmSync(directory, { recursive: true, force: true }),
  };
}

test('versioning consumes host changesets and gives package-only changesets a shared host patch', () => {
  for (const [changeset, expected] of [
    ['"@private-email/mobile": minor', '0.2.0'],
    ['"@private-email/convex": patch', '0.1.1'],
  ]) {
    const f = fixture();
    try {
      f.write('.changeset/update.md', `---\n${changeset}\n---\nChanges\n`);
      const result = f.run('release-version.sh');
      assert.equal(result.status, 0, result.stderr);
      assert.equal(f.version('mobile'), expected);
      assert.equal(f.version('macos'), expected);
      for (const file of ['update.md', 'release-hosts.md']) {
        assert.equal(existsSync(path.join(f.cwd, '.changeset', file)), false);
      }
    } finally {
      f.close();
    }
  }
});

test('stale version planning and unavailable main refs cannot consume changesets or change host versions', () => {
  const f = fixture();
  try {
    const changeset = '---\n"@private-email/mobile": minor\n---\nChanges\n';
    f.write('.changeset/update.md', changeset);
    for (const env of [
      { RELEASE_TEST_MAIN_SHA: 'newer-main' },
      { RELEASE_TEST_API_FAILURE: '1' },
    ]) {
      const result = f.run('release-version.sh', env);
      assert.equal(result.status, 1, result.stdout);
      assert.equal(f.version('mobile'), '0.1.0');
      assert.equal(f.version('macos'), '0.1.0');
      assert.equal(
        readFileSync(path.join(f.cwd, '.changeset/update.md'), 'utf8'),
        changeset,
      );
    }
  } finally {
    f.close();
  }
});

test('only a merged version pull request with an untagged shared version reports a release tag', () => {
  const f = fixture();
  try {
    let result = f.run('release-tag.sh');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(parseJson(result.output), {
      type: 'git-tag',
      tag: 'v0.1.0',
      packageName: '@private-email/mobile',
    });
    for (const env of [
      { RELEASE_TEST_UNMERGED: '1' },
      { RELEASE_TEST_TAG: 'merge' },
    ]) {
      result = f.run('release-tag.sh', env);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.output, '');
    }
    for (const env of [
      { RELEASE_TEST_TAG: 'other' },
      { RELEASE_TEST_API_FAILURE: '1' },
    ]) {
      result = f.run('release-tag.sh', env);
      assert.equal(result.status, 1);
      assert.equal(result.output, '');
    }
    f.hosts('0.1.0', '0.2.0');
    result = f.run('release-tag.sh');
    assert.equal(result.status, 1);
    assert.equal(result.output, '');
  } finally {
    f.close();
  }
});
