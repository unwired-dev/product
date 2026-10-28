import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const script = fileURLToPath(new URL('stale-claims', import.meta.url));

// A fake `gh` over a JSON store of issues, pull requests and branch commit
// dates; `--jq` filters run through the real jq.
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
// One item per page, so anything past the first page needs --paginate --slurp.
const pages = (items) => args.includes('--paginate') && args.includes('--slurp') ? out(items.map((item) => [item])) : process.exit(1);
if (args[0] === 'repo') out({ nameWithOwner: 'owner/repo' });
else if (args[0] === 'pr' && args[1] === 'list') out(store.prs ?? []);
else if (args[0] === 'issue' && args[1] === 'list')
  out(Object.entries(store.issues).filter(([, it]) => it.labels.includes(flag('--label'))).map(([number]) => ({ number: Number(number) })));
else if (args[0] === 'api' && args[1] === 'graphql') {
  const committedDate = (store.branches ?? {})[flag('-f').replace(/^ref=refs\/heads\//, '')];
  out({ data: { repository: { ref: committedDate ? { target: { committedDate } } : null } } });
} else if (args[0] === 'api') {
  const [, , , , number, kind] = args[1].split('/');
  const it = store.issues[number];
  if (kind === 'comments') pages(it.comments);
  else if (kind === 'events') pages(it.events ?? []);
  else process.exit(1);
} else if (args[0] === 'issue' && args[1] === 'comment')
  store.issues[args[2]].comments.push({ body: flag('--body'), created_at: new Date().toISOString() });
else process.exit(1);
fs.writeFileSync(file, JSON.stringify(store));
`;

const daysAgo = (days) =>
  new Date(Date.now() - days * 86_400_000)
    .toISOString()
    .replace(/\.\d+Z$/u, 'Z');
const claim = (branch, days) => ({
  body: `Claimed.\n\n<!-- issue-claim ${JSON.stringify({ branch, worktree: '/w' })} -->`,
  created_at: daysAgo(days),
});
const claimed = (fields = {}) => ({
  labels: ['in progress'],
  comments: [],
  ...fields,
});

// Runs the real script and jq; only the GitHub CLI is a fake boundary.
function run(t, store, ...args) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'stale-claims-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(path.join(directory, 'gh'), fakeGh, { mode: 0o755 });
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
  return { ...result, store: parseJson(readFileSync(storeFile, 'utf8')) };
}

test('flags a stale claim once, keeping the label', (t) => {
  const store = {
    issues: { 7: claimed({ comments: [claim('t3/seven', 5)] }) },
    branches: { 't3/seven': daysAgo(4) },
  };
  const first = run(t, store);
  assert.equal(first.status, 0, first.stderr);
  assert.match(first.stdout, /#7: flagged/u);
  assert.deepEqual(first.store.issues[7].labels, ['in progress']);
  assert.match(
    first.store.issues[7].comments[1].body,
    /no claim-branch commit since .*\n\n<!-- issue-stale-claim /u,
  );
  const again = run(t, first.store);
  assert.equal(again.status, 0, again.stderr);
  assert.match(again.stdout, /#7: already flagged/u);
  assert.equal(again.store.issues[7].comments.length, 2);
});

test('an open pull request or a recent commit keeps a claim active', (t) => {
  const store = {
    issues: {
      1: claimed({ comments: [claim('t3/one', 9)] }),
      2: claimed({ comments: [claim('t3/two', 9)] }),
      3: claimed({ comments: [claim('t3/three', 9)] }),
    },
    prs: [
      { headRefName: 't3/one', closingIssuesReferences: [] },
      {
        headRefName: 't3/elsewhere',
        closingIssuesReferences: [
          {
            number: 2,
            repository: { name: 'repo', owner: { login: 'owner' } },
          },
        ],
      },
    ],
    branches: { 't3/three': daysAgo(1) },
  };
  const result = run(t, store);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(
    Object.values(result.store.issues).map((it) => it.comments.length),
    [1, 1, 1],
  );
  assert.match(result.stdout, /#3: active since/u);
});

test('a released claim falls back to the label date', (t) => {
  const owner = { branch: 't3/old', worktree: '/w' };
  const store = {
    issues: {
      7: claimed({
        comments: [
          claim('t3/old', 9),
          {
            body: `<!-- issue-release ${JSON.stringify(owner)} -->`,
            created_at: daysAgo(8),
          },
        ],
        events: [
          {
            event: 'labeled',
            label: { name: 'in progress' },
            created_at: daysAgo(9),
          },
          {
            event: 'labeled',
            label: { name: 'in progress' },
            created_at: daysAgo(2),
          },
        ],
      }),
      8: claimed({
        events: [
          {
            event: 'labeled',
            label: { name: 'in progress' },
            created_at: daysAgo(4),
          },
        ],
      }),
    },
  };
  const result = run(t, store);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /#7: active since/u);
  assert.match(result.stdout, /#8: flagged/u);
});

test('--days sets the threshold', (t) => {
  const store = {
    issues: { 7: claimed({ comments: [claim('t3/seven', 5)] }) },
  };
  const result = run(t, store, '--days', '7');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /#7: active since/u);
  assert.equal(run(t, store, '--days', 'x').status, 2);
});
