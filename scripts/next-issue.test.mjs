import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const script = fileURLToPath(new URL('next-issue', import.meta.url));

// A read-only fake `gh` over a JSON store; it logs every call and serves two
// issues and one blocker per page, so later pages need --paginate.
const fakeGh = String.raw`#!/usr/bin/env node
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const store = JSON.parse(fs.readFileSync(process.env.FAKE_GH_STORE, 'utf8'));
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_GH_LOG, JSON.stringify(args) + '\n');
const out = (value) => {
  const json = JSON.stringify(value);
  const filter = args.includes('--jq') ? args[args.indexOf('--jq') + 1] : undefined;
  process.stdout.write(filter ? execFileSync('jq', ['-r', filter], { input: json }) : json + '\n');
};
const pages = (items, size) => {
  const all = [];
  for (let i = 0; i < items.length; i += size) all.push(items.slice(i, i + size));
  if (!args.includes('--paginate')) return all[0] ?? [];
  return args.includes('--slurp') ? all : process.exit(1);
};
const [resource, query] = (args.slice(1).find((arg) => !arg.startsWith('-')) ?? '').split('?');
const blocked = resource.match(/^repos\/owner\/repo\/issues\/(\d+)\/dependencies\/blocked_by$/);
if (args[0] === 'repo') out({ nameWithOwner: 'owner/repo' });
else if (args[0] === 'pr' && args[1] === 'list') out(store.prs ?? []);
else if (args[0] !== 'api' || args.includes('--method') || args.includes('-X')) process.exit(1);
else if (resource === 'orgs/owner/issue-fields') out(store.fields);
else if (resource === 'repos/owner/repo/issues' && query.startsWith('state=open&labels=ready-for-agent&')) out(pages(store.issues, 2));
else if (resource === 'repos/owner/repo/issues' && query.startsWith('state=all&sort=updated&')) out(store.recent ?? []);
else if (blocked) out(pages(store.blockers?.[blocked[1]] ?? [], 1));
else process.exit(1);
`;

const priorityField = {
  id: 10,
  name: 'Priority',
  data_type: 'single_select',
  options: [
    { id: 102, name: 'High', priority: 2 },
    { id: 104, name: 'Low', priority: 4 },
    { id: 103, name: 'Medium', priority: 3 },
    { id: 101, name: 'Urgent', priority: 1 },
  ],
};
const fields = [
  { id: 9, name: 'Effort', data_type: 'single_select', options: [] },
  priorityField,
];

// An open ready-for-agent issue as the REST list returns it.
function issue(
  number,
  { labels = [], option, created = '2026-01-01', blockers = 0, ...rest } = {},
) {
  return {
    number,
    title: `Issue ${number}`,
    html_url: `https://github.com/owner/repo/issues/${number}`,
    created_at: `${created}T00:00:00Z`,
    labels: ['ready-for-agent', ...labels].map((name) => ({ name })),
    issue_field_values: option
      ? [{ issue_field_id: 10, data_type: 'single_select', value: option }]
      : [],
    issue_dependencies_summary: { total_blocked_by: blockers },
    ...rest,
  };
}

const blocker = (number, state, stateReason = null) => ({
  number,
  state,
  state_reason: stateReason,
  repository_url: 'https://api.github.com/repos/owner/repo',
});

// Runs the real script and jq; only the GitHub CLI is a fake boundary.
function run(t, store, ...args) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'next-issue-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  writeFileSync(path.join(directory, 'gh'), fakeGh, { mode: 0o755 });
  const storeFile = path.join(directory, 'store.json');
  const log = path.join(directory, 'calls.log');
  writeFileSync(storeFile, JSON.stringify({ fields, ...store }));
  writeFileSync(log, '');
  const result = spawnSync(script, args, {
    cwd: directory,
    encoding: 'utf8',
    env: {
      ...process.env,
      FAKE_GH_STORE: storeFile,
      FAKE_GH_LOG: log,
      PATH: `${directory}:${process.env.PATH}`,
    },
  });
  const calls = readFileSync(log, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => parseJson(line));
  return {
    ...result,
    calls,
    output: result.status === 0 ? parseJson(result.stdout) : undefined,
  };
}

const ranking = (output) =>
  output.candidates.map(({ number, priority, priority_source }) => [
    number,
    priority,
    priority_source,
  ]);

test('ranks the most urgent signal first, unprioritized last, then oldest', (t) => {
  const result = run(
    t,
    {
      issues: [
        issue(1, { created: '2026-01-01' }),
        issue(2, { labels: ['priority: low'], created: '2026-01-01' }),
        issue(3, { option: 102, created: '2026-03-01' }),
        // The label is more urgent than the field, so the label wins.
        issue(4, {
          option: 104,
          labels: ['priority: high'],
          created: '2026-02-01',
        }),
        issue(5, { option: 101, created: '2026-05-01' }),
        issue(6, { labels: ['priority: high'], created: '2026-02-01' }),
      ],
    },
    '--limit',
    '10',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(ranking(result.output), [
    [5, 'Urgent', 'field'],
    [4, 'High', 'label'],
    [6, 'High', 'label'],
    [3, 'High', 'field'],
    [2, 'Low', 'label'],
    [1, null, 'unset'],
  ]);
  assert.equal(result.output.control, null);
  assert.match(result.stderr, /^#5 Urgent \(field\) 2026-05-01 Issue 5$/mu);
});

test('excludes claimed, human, test, wontfix, pull request and open-PR issues', (t) => {
  const result = run(t, {
    issues: [
      issue(1, { labels: ['in progress'] }),
      issue(2, { labels: ['ready-for-human'] }),
      issue(3, { labels: ['ready-for-test'] }),
      issue(4, { labels: ['human needed'] }),
      issue(5, { labels: ['wontfix'] }),
      issue(6, { pull_request: { url: 'pr' } }),
      issue(7, { option: 101 }),
      issue(8, { option: 102 }),
    ],
    prs: [
      {
        number: 40,
        closingIssuesReferences: [
          { url: 'https://github.com/owner/repo/issues/7' },
        ],
      },
    ],
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(ranking(result.output), [[8, 'High', 'field']]);
  assert.deepEqual(result.output.skipped, [
    { number: 7, reason: 'open PR #40' },
  ]);
});

test('an open blocker on a later page skips the issue; closed ones are reported', (t) => {
  const result = run(
    t,
    {
      issues: [
        issue(1, { option: 101, blockers: 2 }),
        issue(2, { option: 102, blockers: 1 }),
        issue(3, { option: 103 }),
        issue(4, { option: 104 }),
      ],
      blockers: {
        1: [blocker(20, 'closed', 'completed'), blocker(21, 'open')],
        2: [blocker(22, 'closed', 'not_planned')],
      },
    },
    '--limit',
    '2',
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(ranking(result.output), [
    [2, 'High', 'field'],
    [3, 'Medium', 'field'],
  ]);
  assert.deepEqual(result.output.candidates[0].blockers, [
    { issue: 'owner/repo#22', state: 'closed', state_reason: 'not_planned' },
  ]);
  assert.deepEqual(result.output.skipped, [
    { number: 1, reason: 'open blocker owner/repo#21' },
  ]);
  // Issues without blockers and past the limit cost no dependency read.
  const dependencyReads = result.calls.filter((call) =>
    call.some((arg) => arg.includes('/dependencies/')),
  );
  assert.equal(dependencyReads.length, 2);
});

test('follows every page of the issue list and only reads', (t) => {
  const issues = Array.from({ length: 5 }, (_, index) => issue(index + 1));
  issues.push(issue(6, { option: 104 }));
  const result = run(t, { issues }, '--limit', '1');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(ranking(result.output), [[6, 'Low', 'field']]);
  for (const call of result.calls) {
    assert.ok(['api', 'repo', 'pr'].includes(call[0]), call.join(' '));
  }
});

test('an all-unset backlog passes the control when a recent issue reads a priority', (t) => {
  const result = run(t, {
    issues: [
      issue(2, { created: '2026-02-01' }),
      issue(1, { created: '2026-03-01' }),
    ],
    recent: [issue(9), issue(8, { state: 'closed', option: 102 })],
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.output.control, {
    number: 8,
    priority: { name: 'High', rank: 2, source: 'field' },
  });
  assert.deepEqual(
    result.output.candidates.map(({ number }) => number),
    [2, 1],
  );
});

test('a control that also reads unset reports priority unknown', (t) => {
  const result = run(t, { issues: [issue(1)], recent: [issue(9)] });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /treat priority as unknown/u);
  assert.equal(result.stdout, '');
});

test('a priority label with no matching option stops the ranking', (t) => {
  const result = run(t, {
    issues: [issue(1, { labels: ['priority: someday'] })],
  });
  assert.equal(result.status, 1);
  assert.match(
    result.stderr,
    /`priority: someday` on #1 names no Priority option/u,
  );
});
