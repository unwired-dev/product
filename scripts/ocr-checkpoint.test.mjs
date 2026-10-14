import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);

const script = fileURLToPath(new URL('ocr-checkpoint.mjs', import.meta.url));

function repository(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'ocr-checkpoint-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const cwd = path.join(root, 'repo');
  mkdirSync(cwd);
  const git = (...args) =>
    execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
  git('init', '-b', 'main');
  git('config', 'user.name', 'Review Test');
  git('config', 'user.email', 'review@example.invalid');
  git('config', 'commit.gpgsign', 'false');
  const commit = (file, content) => {
    mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
    writeFileSync(path.join(cwd, file), content);
    git('add', '--', file);
    git('commit', '-m', file);
    return git('rev-parse', 'HEAD');
  };
  const base = commit('source.txt', 'base\n');
  git('switch', '-c', 'task');
  const run = (...args) =>
    spawnSync(process.execPath, [script, ...args], { cwd, encoding: 'utf8' });
  const plan = (...args) => {
    const result = run('plan', 'issue-123', 'main', ...args);
    assert.equal(result.status, 0, result.stderr);
    return parseJson(result.stdout);
  };
  const finish = (review) => {
    const planFile = path.join(root, 'plan.json');
    const reportFile = path.join(root, 'report.md');
    writeFileSync(planFile, JSON.stringify(review));
    writeFileSync(
      reportFile,
      'All selected files reviewed; findings fixed and verified.',
    );
    return run('complete', planFile, reportFile);
  };
  return { root, cwd, git, commit, base, run, plan, finish };
}

test('only completed reviews advance the range, including across linked worktrees', (t) => {
  const r = repository(t);
  const first = r.commit('source.txt', 'first\n');
  const initial = r.plan();
  assert.equal(initial.mode, 'full');
  assert.equal(initial.from, r.base);
  assert.equal(r.plan().from, r.base);
  assert.equal(r.finish(initial).status, 0);
  assert.equal(r.plan().reason, 'unchanged');
  const next = r.commit('source.txt', 'second\n');
  const followup = r.plan();
  assert.equal(followup.mode, 'incremental');
  assert.equal(followup.from, first);
  assert.equal(followup.to, next);
  assert.match(followup.previousReport, /findings fixed/u);
  assert.equal(r.finish(initial).status, 1);
  assert.equal(r.plan().from, first);
  assert.equal(r.finish(followup).status, 0);
  r.git('switch', 'main');
  const linked = path.join(r.root, 'linked');
  r.git('worktree', 'add', linked, 'task');
  const restored = parseJson(
    execFileSync(process.execPath, [script, 'plan', 'issue-123', 'main'], {
      cwd: linked,
      encoding: 'utf8',
    }),
  );
  assert.equal(restored.reason, 'unchanged');
  assert.equal(restored.from, next);
});

test('base movement, policy edits, rewritten history and explicit requests require full reviews', (t) => {
  const r = repository(t);
  r.commit('source.txt', 'first\n');
  assert.equal(r.finish(r.plan()).status, 0);
  r.commit('AGENTS.md', 'changed review instructions\n');
  assert.equal(r.plan().reason, 'policy_changed');
  assert.equal(r.finish(r.plan()).status, 0);
  assert.equal(r.plan('--full').reason, 'requested_full_review');
  r.commit('.opencodereview/rule.json', '{}\n');
  assert.equal(r.plan().reason, 'policy_changed');
  assert.equal(r.finish(r.plan()).status, 0);
  r.git('switch', 'main');
  r.commit('base.txt', 'base moved\n');
  r.git('switch', 'task');
  assert.equal(r.plan().reason, 'base_changed');
  assert.equal(r.finish(r.plan()).status, 0);
  r.git('commit', '--amend', '-m', 'Rewrite the reviewed commit');
  // The policy content is identical, but the completed head is no longer an ancestor.
  assert.equal(r.plan().reason, 'not_ancestor');
  assert.equal(r.plan().from, r.base);
});

test('dirty work, malformed records, empty reports and changed target refs cannot bless unreviewed content', (t) => {
  const r = repository(t);
  r.commit('source.txt', 'first\n');
  const initial = r.plan();
  writeFileSync(path.join(r.cwd, 'untracked.txt'), 'unreviewed');
  assert.equal(r.run('plan', 'issue-123', 'main').status, 1);
  assert.equal(r.finish(initial).status, 1);
  rmSync(path.join(r.cwd, 'untracked.txt'));
  writeFileSync(path.join(r.cwd, 'source.txt'), 'dirty');
  assert.equal(r.run('plan', 'issue-123', 'main').status, 1);
  r.git('add', 'source.txt');
  assert.equal(r.run('plan', 'issue-123', 'main').status, 1);
  r.git('reset', '--hard', 'HEAD');
  assert.equal(r.finish(initial).status, 0);
  const checkpointDirectory = path.join(r.cwd, '.git', 'ocr-checkpoints');
  const checkpoint = path.join(
    checkpointDirectory,
    readdirSync(checkpointDirectory)[0],
  );
  const valid = readFileSync(checkpoint, 'utf8');
  for (const content of ['{', '{}', 'null']) {
    writeFileSync(checkpoint, content);
    assert.equal(r.plan().reason, 'invalid_checkpoint');
    assert.equal(r.plan().from, r.base);
  }
  writeFileSync(checkpoint, valid);
  const pending = r.plan();
  writeFileSync(path.join(r.root, 'plan.json'), JSON.stringify(pending));
  writeFileSync(path.join(r.root, 'report.md'), '');
  assert.equal(
    r.run(
      'complete',
      path.join(r.root, 'plan.json'),
      path.join(r.root, 'report.md'),
    ).status,
    1,
  );
  r.git('switch', 'main');
  r.commit('base.txt', 'new base');
  r.git('switch', 'task');
  assert.equal(r.finish(pending).status, 1);
  assert.equal(readFileSync(checkpoint, 'utf8'), valid);
  const other = parseJson(r.run('plan', 'different-task', 'main').stdout);
  assert.equal(other.reason, 'missing_checkpoint');
});
