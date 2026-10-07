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
const checkRule = (context, integration_id = 15_368) => ({
  type: 'required_status_checks',
  parameters: { required_status_checks: [{ context, integration_id }] },
});
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
    baseRefName: 'main',
    author: { login: 'maintainer', __typename: 'User' },
    headRefName: 'feature',
    headRefOid: head,
    mergeable: 'MERGEABLE',
    labels: { totalCount: 0, nodes: [] },
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
                totalCount: 3,
                nodes: [
                  {
                    name: 'TypeScript',
                    status: 'COMPLETED',
                    conclusion: 'SUCCESS',
                    checkSuite: { app: { databaseId: 15_368 } },
                  },
                  {
                    name: 'Fallow',
                    status: 'COMPLETED',
                    conclusion: 'SKIPPED',
                    checkSuite: { app: { databaseId: 15_368 } },
                  },
                  {
                    context: 'CodeRabbit',
                    state: 'SUCCESS',
                    description: 'Review completed',
                  },
                ],
              },
            },
          },
        },
      ],
    },
  };
}

// Writes the pull request snapshots, ruleset pages and a fake `gh` binary.
function fakeGitHub(directory, pr, options) {
  writeFileSync(
    path.join(directory, 'pr.json'),
    JSON.stringify([pr, ...(options.snapshots ?? [])]),
  );
  const required = [checkRule('TypeScript'), checkRule('Fallow')];
  writeFileSync(
    path.join(directory, 'rules.json'),
    JSON.stringify(options.rulePages ?? [required]),
  );
  writeFileSync(
    path.join(directory, 'gh'),
    `#!/usr/bin/env node
import fs from 'node:fs';
const a = process.argv.slice(2), dir = ${JSON.stringify(directory)};
fs.appendFileSync(dir + '/gh.log', JSON.stringify(a) + '\\n');
if (a[0] === 'pr' && a[1] === 'list') { console.log('[{"number":7}]'); process.exit(0); }
if (a[0] === 'api' && a[1] === 'graphql') {
const count = fs.readFileSync(dir + '/gh.log', 'utf8').trim().split('\\n').map(JSON.parse).filter(call => call[1] === 'graphql').length;
const snapshots = JSON.parse(fs.readFileSync(dir + '/pr.json'));
console.log(JSON.stringify({ data: { repository: { pullRequest: snapshots[Math.min(count - 1, snapshots.length - 1)] } } }));
process.exit(0);
}
if (a[0] === 'api' && a[1].endsWith('/rules/branches/main')) {
const pages = JSON.parse(fs.readFileSync(dir + '/rules.json'));
console.log(JSON.stringify(a.includes('--slurp') ? pages : pages[0]));
process.exit(0);
}
if (a[0] === 'api' && a[1] === '-X' && a[2] === 'PUT') {
if (${Boolean(options.failDismiss)}) process.exit(1);
const id = Number(a[3].split('/').at(-2));
const snapshots = JSON.parse(fs.readFileSync(dir + '/pr.json'));
for (const snapshot of snapshots) for (const review of snapshot.reviews.nodes) if (review.databaseId === id) review.state = 'DISMISSED';
fs.writeFileSync(dir + '/pr.json', JSON.stringify(snapshots));
process.exit(0);
}
if (a[0] === 'pr' && a[1] === 'merge') process.exit(${options.failMerge ? 1 : 0});
process.exit(2);
`,
    { mode: 0o755 },
  );
}

// Runs the real script and jq; only the GitHub API is a fake boundary.
function run(pr, env = {}, options = {}) {
  mkdirSync(path.join(root, 'scratchpad'), { recursive: true });
  const directory = mkdtempSync(path.join(root, 'scratchpad/auto-merge-'));
  try {
    fakeGitHub(directory, pr, options);
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
    assert.equal(result.status, options.expectedStatus ?? 0, result.stderr);
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

const coderabbitStatus = (pr) =>
  pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes.find(
    (node) => node.context === 'CodeRabbit',
  );

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
  [
    'a bot author',
    (pr) => (pr.author = { login: 'automation', __typename: 'Bot' }),
  ],
  ['an unavailable author', (pr) => (pr.author = null)],
  ['a different base branch', (pr) => (pr.baseRefName = 'release')],
  ['a [WIP] title', (pr) => (pr.title = '[WIP] Ship a feature')],
  [
    'a mixed-case skip title',
    (pr) => (pr.title = 'Ship a feature [Skip Review]'),
  ],
  ['a Version packages title', (pr) => (pr.title = 'Version packages')],
  ['an incomplete label page', (pr) => (pr.labels.totalCount = 51)],
  [
    'an incomplete check page',
    (pr) =>
      (pr.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount = 101),
  ],
  ['more than 100 review threads', (pr) => (pr.reviewThreads.totalCount = 101)],
  [
    'a required check from the wrong app',
    (pr) =>
      (pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].checkSuite.app.databaseId = 999),
  ],
  [
    'an app-bound required check replaced by a status',
    (pr) =>
      (pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0] = {
        context: 'TypeScript',
        state: 'SUCCESS',
      }),
  ],
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
  [
    'a required check still in progress',
    (pr) =>
      (pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].status =
        'IN_PROGRESS'),
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
    'a CodeRabbit approval of an older commit and activity in the last two hours',
    (pr) => {
      coderabbitStatus(pr).description = 'Review paused';
      pr.commits.nodes[0].commit.committedDate = hoursAgo(1);
    },
  ],
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
  [
    'a CodeRabbit change request at exactly two quiet hours',
    (pr) => {
      pr.reviews.nodes.pop();
      pr.comments.nodes[0].createdAt = hoursAgo(2);
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

test('merges a CodeRabbit approval of an older commit after two quiet hours', () => {
  const pr = cleared();
  coderabbitStatus(pr).description = 'Review rate limited';
  assert.deepEqual(run(pr), { output: '#7: merge', calls: [merge] });
});

test('includes required checks from later rules pages', () => {
  const { output, calls } = run(
    cleared(),
    {},
    { rulePages: [[checkRule('TypeScript')], [checkRule('Expo mobile')]] },
  );
  assert.match(output, /wait: required checks/u);
  assert.deepEqual(calls, []);
});

test('accepts a successful status when the ruleset does not bind its app', () => {
  const pr = cleared();
  pr.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0] = {
    context: 'TypeScript',
    state: 'SUCCESS',
  };
  assert.deepEqual(
    run(pr, {}, { rulePages: [[checkRule('TypeScript', null)]] }).calls,
    [merge],
  );
});

test('does not merge if dismissal fails', () => {
  const pr = cleared();
  pr.reviews.nodes.pop();
  const { calls } = run(pr, {}, { failDismiss: true, expectedStatus: 1 });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][2], 'PUT');
});

test('returns a failure when the head-fenced merge fails', () => {
  assert.deepEqual(
    run(cleared(), {}, { failMerge: true, expectedStatus: 1 }).calls,
    [merge],
  );
});

test('revalidates unresolved feedback arriving during dismissal', () => {
  const pr = cleared();
  pr.reviews.nodes.pop();
  const changed = structuredClone(pr);
  changed.reviewThreads.nodes[0].isResolved = false;
  changed.reviewThreads.nodes[0].comments.nodes[0].createdAt = hoursAgo(0);
  const { calls } = run(pr, {}, { snapshots: [pr, changed] });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][2], 'PUT');
});

test('revalidates changed exclusions before merging', () => {
  const changed = cleared();
  changed.labels = { totalCount: 1, nodes: [{ name: 'do-not-review' }] };
  assert.deepEqual(run(cleared(), {}, { snapshots: [changed] }).calls, []);
});
