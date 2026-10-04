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

function fixture() {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(path.join(root, 'scratchpad/release-plan-'));
  const cwd = path.join(directory, 'checkout');
  mkdirSync(cwd);
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const write = (file, contents) => {
    mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
    writeFileSync(path.join(cwd, file), contents);
  };
  const hosts = (version) => {
    for (const host of ['mobile', 'macos']) {
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
  git('init', '--initial-branch=main');
  git('config', 'user.name', 'Release contract');
  git('config', 'user.email', 'release-test@example.invalid');
  git('init', '--bare', path.join(directory, 'remote.git'));
  git('remote', 'add', 'origin', path.join(directory, 'remote.git'));
  write('.gitignore', 'node_modules\n');
  write(
    'package.json',
    JSON.stringify({
      name: '@fixture/root',
      private: true,
      packageManager: 'pnpm@11.5.2',
    }),
  );
  write('pnpm-workspace.yaml', 'packages:\n  - apps/*\n  - packages/*\n');
  write('pnpm-lock.yaml', 'lockfileVersion: 9.0\n');
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
  write('.changeset/README.md', 'Changesets\n');
  write('packages/README.md', 'Workspace packages\n');
  hosts('0.1.0');
  for (const script of ['check-changesets.mjs', 'release-plan.sh']) {
    mkdirSync(path.join(cwd, 'scripts'), { recursive: true });
    copyFileSync(
      path.join(root, 'scripts', script),
      path.join(cwd, 'scripts', script),
    );
  }
  symlinkSync(path.join(root, 'node_modules'), path.join(cwd, 'node_modules'));
  git('add', '.');
  git('commit', '-m', 'Initial hosts');
  git('push', 'origin', 'main');
  const bin = path.join(directory, 'bin');
  mkdirSync(bin);
  // Exercise real Changesets and Git; only the GitHub API is a fake boundary.
  writeFileSync(
    path.join(bin, 'pnpm'),
    `#!/bin/sh\nexec "${process.execPath}" "${path.join(root, 'node_modules/@changesets/cli/bin.js')}" version\n`,
    { mode: 0o755 },
  );
  writeFileSync(
    path.join(bin, 'gh'),
    `#!/usr/bin/env node
import fs from 'node:fs';
const a = process.argv.slice(2), dir = process.env.RELEASE_TEST_DIRECTORY;
fs.appendFileSync(dir + '/gh.log', JSON.stringify(a) + '\\n');
if (a[0] === 'auth') process.exit(0);
if (a[0] === 'pr' && a[1] === 'list') { if (fs.existsSync(dir + '/pr')) console.log(7); process.exit(0); }
if (a[0] === 'pr' && a[1] === 'create') { fs.writeFileSync(dir + '/pr', '7'); process.exit(0); }
if (a[0] === 'api' && a.includes('PATCH')) process.exit(0);
if (a[0] === 'api' && a.some(x => x.includes('/commits/'))) { if (process.env.RELEASE_TEST_UNMERGED !== '1') console.log(7); process.exit(0); }
if (a[0] === 'api') { if (process.env.RELEASE_TEST_API_FAILURE === '1') process.exit(1); if (fs.existsSync(dir + '/release')) console.log(10); process.exit(0); }
if (a[0] === 'release' && a[1] === 'create') { fs.writeFileSync(dir + '/release', '10'); if (process.env.RELEASE_TEST_LOST_RESPONSE === '1') process.exit(1); process.exit(0); }
process.exit(2);
`,
    { mode: 0o755 },
  );
  const commit = (message) => {
    git('add', '.');
    git('commit', '-m', message);
    git('push', 'origin', 'main');
    return git('rev-parse', 'HEAD');
  };
  const run = (sha = git('rev-parse', 'HEAD'), env = {}) => {
    const output = path.join(directory, 'output');
    writeFileSync(output, '');
    const result = spawnSync('bash', ['scripts/release-plan.sh'], {
      cwd,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GITHUB_SHA: sha,
        GITHUB_OUTPUT: output,
        GITHUB_REPOSITORY: 'fixture/product',
        RUNNER_TEMP: directory,
        RELEASE_TEST_DIRECTORY: directory,
        ...env,
      },
    });
    return { ...result, output: readFileSync(output, 'utf8') };
  };
  return {
    cwd,
    directory,
    git,
    hosts,
    write,
    commit,
    run,
    close: () => rmSync(directory, { recursive: true, force: true }),
  };
}

test('version planning consumes real changesets and preserves its branch on a rerun', () => {
  const f = fixture();
  try {
    f.write(
      '.changeset/host.md',
      '---\n"@private-email/mobile": minor\n---\nRelease hosts\n',
    );
    const sha = f.commit('Add changeset');
    let result = f.run(sha);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.output.includes('release=false'));
    const branch = f.git('rev-parse', 'HEAD');
    assert.equal(
      parseJson(
        readFileSync(path.join(f.cwd, 'apps/macos/package.json'), 'utf8'),
      ).version,
      '0.2.0',
    );
    assert.equal(existsSync(path.join(f.cwd, '.changeset/host.md')), false);
    f.git('checkout', '--detach', sha);
    result = f.run(sha);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      f
        .git('ls-remote', 'origin', 'refs/heads/changeset-release/main')
        .split(/\s/u)[0],
      branch,
    );
    const log = readFileSync(path.join(f.directory, 'gh.log'), 'utf8');
    assert.equal(
      log.split('\n').filter((line) => line.includes('"create"')).length,
      1,
    );
    assert.ok(log.includes('PATCH'));
    f.git('checkout', 'main');
    f.write('README.md', 'New main\n');
    f.commit('Newer main');
    f.git('checkout', '--detach', sha);
    result = f.run(sha);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      f
        .git('ls-remote', 'origin', 'refs/heads/changeset-release/main')
        .split(/\s/u)[0],
      branch,
    );
  } finally {
    f.close();
  }
});

test('package-only and empty changesets produce a new shared TestFlight version', () => {
  for (const target of ['', '"@private-email/convex": patch']) {
    const f = fixture();
    try {
      f.write(
        'packages/convex/package.json',
        JSON.stringify({
          name: '@private-email/convex',
          private: true,
          version: '0.0.0',
        }),
      );
      f.write(
        '.changeset/update.md',
        `---\n${target}\n---\nWorkspace changes\n`,
      );
      const result = f.run(f.commit('Add workspace changeset'));
      assert.equal(result.status, 0, result.stderr);
      for (const host of ['mobile', 'macos']) {
        const manifest = parseJson(
          readFileSync(path.join(f.cwd, `apps/${host}/package.json`), 'utf8'),
        );
        assert.equal(manifest.version, '0.1.1');
      }
      assert.equal(
        existsSync(path.join(f.cwd, '.changeset/release-hosts.md')),
        false,
      );
    } finally {
      f.close();
    }
  }
});

test('release reruns recover a tag and lost GitHub response, and reject a moved tag', () => {
  const f = fixture();
  try {
    f.hosts('0.2.0');
    const sha = f.commit('Merge version PR');
    let result = f.run(sha, { RELEASE_TEST_LOST_RESPONSE: '1' });
    assert.equal(result.status, 1);
    assert.ok(!result.output.includes('release=true'));
    assert.equal(
      f.git('ls-remote', 'origin', 'refs/tags/v0.2.0').split(/\s/u)[0],
      sha,
    );
    result = f.run(sha);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.output.includes('release=true\ntag=v0.2.0'));
    rmSync(path.join(f.directory, 'release'));
    result = f.run(sha);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(existsSync(path.join(f.directory, 'release')));
    result = f.run(sha, { RELEASE_TEST_API_FAILURE: '1' });
    assert.equal(result.status, 1);
    f.git('tag', '-f', 'v0.2.0', 'HEAD^');
    f.git('push', '--force', 'origin', 'refs/tags/v0.2.0');
    result = f.run(sha);
    assert.equal(result.status, 1);
    assert.ok(result.stderr.includes('another commit'));
  } finally {
    f.close();
  }
});

test('ordinary main pushes, manual bumps and unequal host versions never release', () => {
  const f = fixture();
  try {
    f.write('README.md', 'Docs only\n');
    let result = f.run(f.commit('Docs'));
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!result.output.includes('release=true'));
    f.hosts('0.2.0');
    result = f.run(f.commit('Manual bump'), { RELEASE_TEST_UNMERGED: '1' });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!result.output.includes('release=true'));
    f.write(
      'apps/macos/package.json',
      JSON.stringify({
        name: '@private-email/macos',
        version: '0.3.0',
        private: true,
      }),
    );
    result = f.run(f.commit('Unequal hosts'));
    assert.equal(result.status, 1);
    assert.equal(f.git('ls-remote', 'origin', 'refs/tags/*'), '');
  } finally {
    f.close();
  }
});
