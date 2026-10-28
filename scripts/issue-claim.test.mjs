import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const script = fileURLToPath(new URL('issue-claim', import.meta.url));
const branch = 't3/claim-test';

// A fake `gh` over a JSON issue store; `--jq` filters run through the real jq.
const fakeGh = String.raw`#!/usr/bin/env node
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const file = process.env.FAKE_GH_STORE;
const store = JSON.parse(fs.readFileSync(file, 'utf8'));
const args = process.argv.slice(2);
const flag = (name) => args[args.indexOf(name) + 1];
const out = (value) => {
  const json = JSON.stringify(value);
  const filter = args.includes('--jq') ? flag('--jq') : undefined;
  process.stdout.write(filter ? execFileSync('jq', ['-r', filter], { input: json }) : json + '\n');
};
// An issue answers only in its own repository (owner/repo unless it names one).
const issue = (number, repo) => {
  const it = store.issues[number];
  return it && (it.repo ?? 'owner/repo') === repo ? it : process.exit(1);
};
if (store.failReads > 0 && args[0] === 'api' && store.writes >= store.failAfterWrites) {
  store.failReads -= 1;
  fs.writeFileSync(file, JSON.stringify(store));
  process.exit(1);
}
if (args[0] === 'issue') store.writes = (store.writes ?? 0) + 1;
if (store.failWrite && args[0] === 'issue' && args[1] === store.failWrite) process.exit(1);
if (args[0] === 'repo') out({ nameWithOwner: 'owner/repo' });
else if (args[0] === 'api') {
  const [, owner, name, , number, comments] = args[1].split('/');
  const it = issue(number, owner + '/' + name);
  // One comment per page, so a marker past the first page needs --paginate.
  let bodies = it.comments;
  if (comments && store.hideLastCommentReads > 0) {
    store.hideLastCommentReads -= 1;
    bodies = bodies.slice(0, -1);
  }
  const pages = bodies.map((body) => [{ body }]);
  if (comments) {
    if (!args.includes('--paginate')) out(pages[0] ?? []);
    else if (args.includes('--slurp')) out(pages);
    else process.exit(1);
  }
  else out({
    state: it.state,
    labels: it.labels.map((name) => ({ name })),
    parent_issue_url: it.parent
      ? 'https://api.github.com/repos/' + (store.issues[it.parent].repo ?? 'owner/repo') + '/issues/' + it.parent
      : null,
  });
} else if (args[0] === 'issue' && args[1] === 'edit') {
  const it = issue(args[2], flag('--repo'));
  if (args.includes('--add-label') && !store.dropLabels && !it.labels.includes(flag('--add-label'))) it.labels.push(flag('--add-label'));
  if (args.includes('--remove-label')) it.labels = it.labels.filter((name) => name !== flag('--remove-label'));
} else if (args[0] === 'issue' && args[1] === 'comment') issue(args[2], flag('--repo')).comments.push(flag('--body'));
else process.exit(1);
fs.writeFileSync(file, JSON.stringify(store));
`;

function marker(kind, owner) {
  return `<!-- issue-${kind} ${JSON.stringify(owner)} -->`;
}

// Gives each test a fresh git checkout; `owner` is the claim it would make.
function checkout(t) {
  const directory = realpathSync(
    mkdtempSync(path.join(os.tmpdir(), 'issue-claim-')),
  );
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  spawnSync('git', ['init', '-q', '-b', branch, directory]);
  writeFileSync(path.join(directory, 'gh'), fakeGh, { mode: 0o755 });
  return { directory, owner: { branch, worktree: directory } };
}

// Runs the real script and jq; only the GitHub CLI is a fake boundary.
function run({ directory }, store, ...args) {
  const storeFile = path.join(directory, 'store.json');
  writeFileSync(storeFile, JSON.stringify(store));
  const result = spawnSync(script, args, {
    cwd: directory,
    encoding: 'utf8',
    env: {
      ...process.env,
      FAKE_GH_STORE: storeFile,
      PATH: `${directory}:${process.env.PATH}`,
    },
  });
  return {
    ...result,
    issues: parseJson(readFileSync(storeFile, 'utf8')).issues,
  };
}

const open = (fields = {}) => ({
  state: 'open',
  labels: [],
  parent: null,
  comments: [],
  ...fields,
});
const other = { branch: 't3/other', worktree: '/elsewhere' };

test('claims a sub-issue and tells its parent', (t) => {
  const result = run(
    checkout(t),
    { issues: { 7: open({ parent: 3 }), 3: open() } },
    'claim',
    '7',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, ['in progress']);
  assert.match(result.issues[7].comments[0], /<!-- issue-claim \{"branch"/u);
  assert.deepEqual(result.issues[3].labels, []);
  assert.match(
    result.issues[3].comments[0],
    /^Sub-issue owner\/repo#7 is in progress on branch/u,
  );
});

test('reclaiming your own claim writes nothing', (t) => {
  const repo = checkout(t);
  const claimed = open({
    labels: ['in progress'],
    comments: [marker('claim', repo.owner)],
  });
  const result = run(repo, { issues: { 7: claimed } }, 'claim', '7');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7], claimed);
});

test('refuses an issue claimed by other work', (t) => {
  const claimed = open({
    labels: ['in progress'],
    comments: [marker('claim', other)],
  });
  const result = run(checkout(t), { issues: { 7: claimed } }, 'claim', '7');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /claimed by other work/u);
  assert.deepEqual(result.issues[7], claimed);
});

test('fails when the label does not read back', (t) => {
  const result = run(
    checkout(t),
    { dropLabels: true, issues: { 7: open() } },
    'claim',
    '7',
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /did not read back/u);
});

test('releasing a sub-issue clears the label and reports to the parent', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({
      parent: 3,
      labels: ['in progress'],
      comments: [marker('claim', repo.owner)],
    }),
    3: open(),
  };
  const result = run(
    repo,
    { issues },
    'release',
    '7',
    '--outcome',
    'merged',
    '--remaining',
    'the iPad layout',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, []);
  assert.ok(
    result.issues[7].comments[1].includes(marker('release', repo.owner)),
  );
  assert.match(
    result.issues[3].comments[0],
    /^Sub-issue owner\/repo#7: merged\. Remaining work: the iPad layout\n\n<!-- issue-sub-release owner\/repo#7 /u,
  );
});

test('a parallel release keeps the label for the other claim', (t) => {
  const repo = checkout(t);
  const claimed = open({
    labels: ['in progress'],
    comments: [marker('claim', other)],
  });
  const claim = run(
    repo,
    { issues: { 7: claimed } },
    'claim',
    '7',
    '--parallel',
  );
  assert.equal(claim.status, 0, claim.stderr);
  const result = run(
    repo,
    { issues: claim.issues },
    'release',
    '7',
    '--outcome',
    'abandoned',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, ['in progress']);
});

test('release needs your own claim and a known outcome', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({ labels: ['in progress'], comments: [marker('claim', other)] }),
  };
  assert.equal(
    run(repo, { issues }, 'release', '7', '--outcome', 'merged').status,
    1,
  );
  assert.equal(
    run(repo, { issues }, 'release', '7', '--outcome', 'done').status,
    2,
  );
});

test('a rerun finishes a claim whose label edit failed', (t) => {
  const repo = checkout(t);
  const store = {
    failWrite: 'edit',
    issues: { 7: open({ parent: 3 }), 3: open() },
  };
  // The claim comment lands, then the label edit fails.
  const first = run(repo, store, 'claim', '7');
  assert.equal(first.status, 1);
  const retry = run(repo, { issues: first.issues }, 'claim', '7');
  assert.equal(retry.status, 0, retry.stderr);
  assert.equal(retry.issues[7].comments.length, 1);
  assert.equal(retry.issues[3].comments.length, 1);
  const again = run(repo, { issues: retry.issues }, 'claim', '7');
  assert.deepEqual(again.issues, retry.issues);
});

test('a rerun finishes a release whose label removal failed', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({
      labels: ['in progress'],
      comments: [marker('claim', repo.owner)],
    }),
  };
  const first = run(
    repo,
    { failWrite: 'edit', issues },
    'release',
    '7',
    '--outcome',
    'blocked',
  );
  assert.equal(first.status, 1);
  assert.deepEqual(first.issues[7].labels, ['in progress']);
  const retry = run(
    repo,
    { issues: first.issues },
    'release',
    '7',
    '--outcome',
    'blocked',
  );
  assert.equal(retry.status, 0, retry.stderr);
  assert.deepEqual(retry.issues[7].labels, []);
  assert.equal(retry.issues[7].comments.length, 2);
});

test('a failed read-back fails the release', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({
      labels: ['in progress'],
      comments: [marker('claim', repo.owner)],
    }),
  };
  const store = { failReads: 9, failAfterWrites: 1, issues };
  const result = run(repo, store, 'release', '7', '--outcome', 'merged');
  assert.notEqual(result.status, 0);
  assert.doesNotMatch(result.stdout, /released/u);
});

test('a takeover releases the previous claim', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({ labels: ['in progress'], comments: [marker('claim', other)] }),
  };
  const claim = run(repo, { issues }, 'claim', '7', '--takeover');
  assert.equal(claim.status, 0, claim.stderr);
  const result = run(
    repo,
    { issues: claim.issues },
    'release',
    '7',
    '--outcome',
    'merged',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, []);
});

test('finds its own claim past the first comment page', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({
      labels: ['in progress'],
      comments: ['first page', marker('claim', repo.owner)],
    }),
  };
  const result = run(repo, { issues }, 'release', '7', '--outcome', 'merged');
  assert.equal(result.status, 0, result.stderr);
});

test('claims again after its own release', (t) => {
  const repo = checkout(t);
  const store = { issues: { 7: open({ parent: 3 }), 3: open() } };
  const first = run(repo, store, 'claim', '7');
  const released = run(
    repo,
    { issues: first.issues },
    'release',
    '7',
    '--outcome',
    'blocked',
  );
  const result = run(repo, { issues: released.issues }, 'claim', '7');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, ['in progress']);
  assert.equal(result.issues[3].comments.length, 3);
});

test('a claim after a cleared label retires the stale owner', (t) => {
  const repo = checkout(t);
  const issues = { 7: open({ comments: [marker('claim', other)] }) };
  const claim = run(repo, { issues }, 'claim', '7');
  assert.equal(claim.status, 0, claim.stderr);
  const result = run(
    repo,
    { issues: claim.issues },
    'release',
    '7',
    '--outcome',
    'merged',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, []);
});

test('tells a parent in another repository', (t) => {
  const repo = checkout(t);
  const issues = { 7: open({ parent: 3 }), 3: open({ repo: 'owner/plans' }) };
  const result = run(repo, { issues }, 'claim', '7');
  assert.equal(result.status, 0, result.stderr);
  assert.match(
    result.issues[3].comments[0],
    /^Sub-issue owner\/repo#7 is in progress/u,
  );
});

test('rerunning a parallel claim keeps the other owner', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({ labels: ['in progress'], comments: [marker('claim', other)] }),
  };
  const claim = run(repo, { issues }, 'claim', '7', '--parallel');
  const rerun = run(repo, { issues: claim.issues }, 'claim', '7');
  assert.equal(rerun.status, 0, rerun.stderr);
  const result = run(
    repo,
    { issues: rerun.issues },
    'release',
    '7',
    '--outcome',
    'merged',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, ['in progress']);
});

test('the later of two parallel releases removes the label', (t) => {
  const repo = checkout(t);
  const issues = {
    7: open({
      labels: ['in progress'],
      comments: [
        marker('claim', other),
        marker('claim', repo.owner),
        marker('release', other),
      ],
    }),
  };
  // The other owner released after this release's first read; the fake shows
  // that by serving the other release only from the second comment read on.
  const result = run(
    repo,
    { hideLastCommentReads: 1, issues },
    'release',
    '7',
    '--outcome',
    'merged',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.issues[7].labels, []);
});
