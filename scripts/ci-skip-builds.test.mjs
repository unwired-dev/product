import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const script = path.join(root, 'scripts/ci-skip-builds.sh');

test('skips builds only for draft and documentation-only pull requests', (t) => {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const cwd = mkdtempSync(path.join(root, 'scratchpad/ci-skip-builds-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const git = (...args) =>
    execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
  const commit = (files) => {
    for (const file of files) {
      mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
      writeFileSync(path.join(cwd, file), `${file}\n`);
    }
    git('add', '.');
    git('commit', '-qm', files.join(' '));
    return git('rev-parse', 'HEAD');
  };
  git('init', '-q', '-b', 'main');
  git('config', 'user.email', 'ci@example.com');
  git('config', 'user.name', 'CI');
  const base = commit(['package.json']);
  const skip = (headSha, env = {}) => {
    const result = spawnSync('bash', [script], {
      cwd,
      encoding: 'utf8',
      env: {
        ...process.env,
        GITHUB_EVENT_NAME: 'pull_request',
        DRAFT: 'false',
        BASE_SHA: base,
        HEAD_SHA: headSha,
        ...env,
      },
    });
    return result.status === 0 ? result.stdout : `failed: ${result.status}`;
  };

  const docs = commit([
    'docs/guide.md',
    'docs/image.png',
    '.agents/skills/probe/scripts/run.py',
    'README.md',
    'apps/mobile/README.md',
    '.changeset/probe.md',
  ]);
  git('switch', '-qc', 'code', base);
  const code = commit(['docs/guide.md', 'apps/mobile/src/app.ts']);
  const nested = commit(['apps/mobile/docs/notes.txt']);

  assert.equal(skip(docs), 'skip=true\n');
  assert.equal(skip(code), 'skip=false\n');
  assert.equal(skip(nested, { BASE_SHA: code }), 'skip=false\n');
  assert.equal(skip(code, { DRAFT: 'true' }), 'skip=true\n');
  assert.equal(skip(docs, { GITHUB_EVENT_NAME: 'push' }), 'skip=false\n');
  // The workflow runs every job when detection fails.
  assert.equal(skip('0'.repeat(40)), 'failed: 128');
});
