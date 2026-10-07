import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

import * as Schema from 'effect/Schema';

const root = fileURLToPath(new URL('../', import.meta.url));
const parseJson = Schema.decodeUnknownSync(Schema.UnknownFromJsonString);
const head = '0123456789abcdef0123456789abcdef01234567';
const now = Date.parse('2026-10-07T12:00:00Z') / 1000;
const hoursAgo = (hours) =>
  new Date((now - hours * 3600) * 1000).toISOString().replace('.000', '');

// A pull request both reviewers cleared three hours ago.
function cleared() {
  return {
    title: 'Ship a feature',
    state: 'OPEN',
    isDraft: false,
    isCrossRepository: false,
    headRefName: 'feature',
    headRefOid: head,
    mergeable: 'MERGEABLE',
    labels: { nodes: [] },
    reactions: { nodes: [{ user: { login: 'chatgpt-codex-connector[bot]' } }] },
    comments: {
      nodes: [
        {
          author: { login: 'chatgpt-codex-connector' },
          body: "Codex Review: Didn't find any major issues. :tada:\n\n**Reviewed commit:** `0123456789`\n",
          createdAt: hoursAgo(3),
        },
      ],
    },
    reviews: {
      nodes: [
        {
          databaseId: 41,
          author: { login: 'coderabbitai' },
          state: 'CHANGES_REQUESTED',
          submittedAt: hoursAgo(5),
        },
        {
          databaseId: 42,
          author: { login: 'coderabbitai' },
          state: 'APPROVED',
          submittedAt: hoursAgo(3),
        },
      ],
    },
    reviewThreads: {
      totalCount: 1,
      nodes: [
        { isResolved: true, comments: { nodes: [{ createdAt: hoursAgo(4) }] } },
      ],
    },
    commits: {
      nodes: [
        {
          commit: {
            committedDate: hoursAgo(4),
            statusCheckRollup: {
              contexts: {
                nodes: [
                  { name: 'TypeScript', conclusion: 'SUCCESS' },
                  { name: 'Fallow', conclusion: 'SKIPPED' },
                  { context: 'CodeRabbit', state: 'SUCCESS' },
                ],
              },
            },
          },
        },
      ],
    },
  };
}

// Runs the real script and jq; only the GitHub API is a fake boundary.
function run(pr, env = {}) {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(path.join(root, 'scratchpad/auto-merge-'));
  try {
    writeFileSync(
      path.join(directory, 'pr.json'),
      JSON.stringify({ data: { repository: { pullRequest: pr } } }),
    );
    writeFileSync(
      path.join(directory, 'gh'),
      `#!/usr/bin/env node
import fs from 'node:fs';
const a = process.argv.slice(2), dir = ${JSON.stringify(directory)};
fs.appendFileSync(dir + '/gh.log', JSON.stringify(a) + '\\n');
if (a[0] === 'pr' && a[1] === 'list') { console.log('[{"number":7}]'); process.exit(0); }
if (a[0] === 'api' && a[1] === 'graphql') { process.stdout.write(fs.readFileSync(dir + '/pr.json')); process.exit(0); }
if (a[0] === 'api' && a[1].endsWith('/rules/branches/main')) {
  console.log(JSON.stringify([{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'TypeScript' }, { context: 'Fallow' }] } }]));
  process.exit(0);
}
if (a[0] === 'api' && a[1] === '-X' && a[2] === 'PUT') process.exit(0);
if (a[0] === 'pr' && a[1] === 'merge') process.exit(0);
process.exit(2);
`,
      { mode: 0o755 },
    );
    const result = spawnSync(
      'bash',
      [path.join(root, 'scripts/auto-merge.sh')],
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${directory}:${process.env.PATH}`,
          GITHUB_REPOSITORY: 'unwired-dev/product',
          AUTO_MERGE_NOW: String(now),
          DRY_RUN: '',
          ...env,
        },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    const calls = readFileSync(path.join(directory, 'gh.log'), 'utf8')
      .trim()
      .split('\n')
      .map((line) => parseJson(line))
      .filter((args) => args[1] === 'merge' || args[2] === 'PUT');
    return { output: result.stdout.trim(), calls };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const merge = [
  'pr',
  'merge',
  '7',
  '--repo',
  'unwired-dev/product',
  '--squash',
  '--match-head-commit',
  head,
];

test('merges the reviewed head once Codex and CodeRabbit cleared it', () => {
  assert.deepEqual(run(cleared()), { output: '#7: merge', calls: [merge] });
});

test('reports decisions without acting in a dry run', () => {
  assert.deepEqual(run(cleared(), { DRY_RUN: '1' }), {
    output: '#7: merge',
    calls: [],
  });
});

test('dismisses a stale CodeRabbit change request after two quiet hours', () => {
  const pr = cleared();
  pr.reviews.nodes.pop();
  const { output, calls } = run(pr);
  assert.equal(output, '#7: dismiss 41');
  assert.deepEqual(calls[0].slice(0, 4), [
    'api',
    '-X',
    'PUT',
    'repos/unwired-dev/product/pulls/7/reviews/41/dismissals',
  ]);
  assert.deepEqual(calls[1], merge);
});

const blocked = [
  ['no Codex 👍', (pr) => (pr.reactions.nodes = [])],
  [
    'a Codex clearance of an older commit',
    (pr) => (pr.headRefOid = 'fedcba9876543210fedcba9876543210fedcba98'),
  ],
  ['no Codex clearance comment', (pr) => (pr.comments.nodes = [])],
  ['no CodeRabbit review', (pr) => (pr.reviews.nodes = [])],
  [
    'an unresolved review thread',
    (pr) => (pr.reviewThreads.nodes[0].isResolved = false),
  ],
  [
    'a failed required check',
    (pr) =>
      (pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].conclusion =
        'FAILURE'),
  ],
  [
    'a missing required check',
    (pr) => pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes.shift(),
  ],
  ['a merge conflict', (pr) => (pr.mergeable = 'CONFLICTING')],
  ['a draft', (pr) => (pr.isDraft = true)],
  ['a fork head', (pr) => (pr.isCrossRepository = true)],
  [
    'the release pull request',
    (pr) => (pr.headRefName = 'changeset-release/main'),
  ],
  [
    'the do-not-review label',
    (pr) => (pr.labels.nodes = [{ name: 'do-not-review' }]),
  ],
  ['a [skip review] title', (pr) => (pr.title = 'Tidy [skip review]')],
  [
    'a CodeRabbit change request with activity in the last two hours',
    (pr) => {
      pr.reviews.nodes.pop();
      pr.comments.nodes.push({
        author: { login: 'rajzik' },
        body: 'Fixed',
        createdAt: hoursAgo(1),
      });
    },
  ],
];

for (const [name, change] of blocked) {
  test(`does not merge with ${name}`, () => {
    const pr = cleared();
    change(pr);
    const { output, calls } = run(pr);
    assert.match(output, /^#7: (?:wait|skip): /u);
    assert.deepEqual(calls, []);
  });
}
