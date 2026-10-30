import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('implementer-grep', import.meta.url));

const reviewerOnly = [
  'docs/architecture/README.md',
  'docs/adr/0001-decision.md',
  '.patterns/layers.md',
  '.opencodereview/rule.json',
  '.opencodereview/rules/common.md',
  'docs/research/spike.md',
  'docs/qualification/evidence.md',
  'docs/archive/old.md',
  'artifacts/review-1-round2/final-rules.json',
];
const readable = [
  'docs/guide.md',
  '.opencodereview/AGENTS.md',
  'artifacts/screenshots/inbox.md',
  'src/app.ts',
];

function repository(t) {
  const cwd = mkdtempSync(path.join(os.tmpdir(), 'implementer-grep-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  execFileSync('git', ['init', '-q'], { cwd });
  for (const file of [...reviewerOnly, ...readable]) {
    mkdirSync(path.dirname(path.join(cwd, file)), { recursive: true });
    writeFileSync(path.join(cwd, file), 'needle\n');
  }
  writeFileSync(
    path.join(cwd, 'docs/guide.md'),
    'needle\nHEAD:docs/architecture\n--\n',
  );
  execFileSync('git', ['add', '.'], { cwd });
  execFileSync(
    'git',
    [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '-qm',
      'fixture',
    ],
    { cwd },
  );
  const grep = (args, from = '.') => {
    const result = spawnSync(script, args, {
      cwd: path.join(cwd, from),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim().split('\n').toSorted();
  };
  return { cwd, grep };
}

test('never searches reviewer-only sources, even inside caller pathspecs', (t) => {
  const { grep } = repository(t);
  const everything = [...readable].toSorted();
  assert.deepEqual(grep(['-l', 'needle']), everything);
  assert.deepEqual(grep(['-l', 'needle', '--', '.']), everything);
  assert.deepEqual(grep(['-l', 'needle', '--', '*.md']), [
    '.opencodereview/AGENTS.md',
    'artifacts/screenshots/inbox.md',
    'docs/guide.md',
  ]);
  assert.deepEqual(grep(['-l', 'needle', '--', 'docs']), ['docs/guide.md']);
  assert.deepEqual(grep(['-l', 'needle', '--', '.opencodereview']), [
    '.opencodereview/AGENTS.md',
  ]);
  assert.deepEqual(grep(['-l', 'needle', '--', 'artifacts']), [
    'artifacts/screenshots/inbox.md',
  ]);
});

test('keeps the exclusions when run from a subdirectory', (t) => {
  const { grep } = repository(t);
  assert.deepEqual(grep(['-l', 'needle'], 'docs'), ['guide.md']);
});

test('rejects tree and blob selectors before they can bypass root exclusions', (t) => {
  const { cwd, grep } = repository(t);
  assert.deepEqual(
    grep(['-l', 'needle', 'HEAD']),
    readable.map((file) => `HEAD:${file}`).toSorted(),
  );
  const tree = execFileSync('git', ['rev-parse', 'HEAD:docs/architecture'], {
    cwd,
    encoding: 'utf8',
  }).trim();
  const blob = execFileSync(
    'git',
    ['rev-parse', 'HEAD:docs/architecture/README.md'],
    { cwd, encoding: 'utf8' },
  ).trim();
  execFileSync(
    'git',
    [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'tag.gpgsign=false',
      'tag',
      '-a',
      '-m',
      'fixture',
      'protected-tree',
      tree,
    ],
    { cwd },
  );
  for (const selector of [
    'HEAD:docs/architecture',
    'HEAD:docs/architecture/README.md',
    tree,
    blob,
    'protected-tree',
  ]) {
    for (const args of [
      ['needle'],
      ['-e', 'needle'],
      ['-neneedle'],
      ['-h', '-e', 'needle'],
      ['--con', '1', 'needle'],
      ['--con=1', 'needle'],
      ['-f', '.opencodereview/AGENTS.md'],
    ]) {
      const result = spawnSync(script, [...args, selector], {
        cwd,
        encoding: 'utf8',
      });
      assert.notEqual(result.status, 0, `${args} ${selector} must be rejected`);
      assert.equal(
        result.stdout,
        '',
        'A rejected selector must not print protected matches',
      );
    }
  }
});

test('preserves pattern operands, option values, and Git no-match status', (t) => {
  const { cwd, grep } = repository(t);
  assert.deepEqual(grep(['-l', 'HEAD:docs/architecture']), ['docs/guide.md']);
  assert.deepEqual(grep(['-leHEAD:docs/architecture']), ['docs/guide.md']);
  assert.deepEqual(grep(['-l', '-e', '--']), ['docs/guide.md']);
  assert.deepEqual(
    grep(['-l', '-A', '1', '--threads', '1', 'needle']),
    [...readable].toSorted(),
  );
  for (const option of [
    '--con',
    '--be',
    '--af',
    '--th',
    '--max-d',
    '--max-c',
  ]) {
    for (const args of [[option, '1'], [`${option}=1`]]) {
      assert.deepEqual(grep([...args, '-l', 'HEAD:docs/architecture']), [
        'docs/guide.md',
      ]);
    }
  }
  const result = spawnSync(script, ['not-present'], { cwd, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
});

test('protects reviewer-only sources when searching untracked files', (t) => {
  const { cwd, grep } = repository(t);
  writeFileSync(path.join(cwd, 'docs/architecture/untracked.md'), 'needle\n');
  writeFileSync(path.join(cwd, 'docs/untracked.md'), 'needle\n');
  for (const options of [
    ['--untracked'],
    ['--untracked', '--no-exclude-standard'],
    ['--no-index'],
  ]) {
    assert.deepEqual(
      grep([...options, '-l', 'needle']),
      [...readable, 'docs/untracked.md'].toSorted(),
    );
    assert.deepEqual(grep([...options, '-l', 'needle'], 'docs'), [
      'guide.md',
      'untracked.md',
    ]);
  }
  assert.deepEqual(
    grep(['--cached', '-l', 'needle']),
    [...readable].toSorted(),
  );
});

test('rejects pattern files, which Git can echo into its output', (t) => {
  const { cwd } = repository(t);
  const file = 'docs/architecture/README.md';
  writeFileSync(path.join(cwd, file), '[\nreviewer-only pattern content\n');
  for (const args of [
    ['-f', file],
    [`-f${file}`],
    ['-lf', file],
    ['--file', file],
    [`--file=${file}`],
  ]) {
    const result = spawnSync(script, args, { cwd, encoding: 'utf8' });
    assert.equal(result.status, 2, args.join(' '));
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /pattern files/u);
    assert.doesNotMatch(result.stderr, /reviewer-only pattern content/u);
  }
});

test('rejects pagers and textconv helpers that can read excluded files', (t) => {
  const { cwd, grep } = repository(t);
  const file = 'docs/architecture/README.md';
  writeFileSync(path.join(cwd, file), 'reviewer-only helper content\n');
  writeFileSync(
    path.join(cwd, '.gitattributes'),
    'docs/guide.md diff=review\n',
  );
  const helper = `cat ${file}`;
  execFileSync('git', ['config', 'diff.review.textconv', helper], { cwd });
  for (const args of [
    ['-O', 'needle'],
    [`-O${helper}`, 'needle'],
    [`-lO${helper}`, 'needle'],
    ['--open-files-in-pager', 'needle'],
    [`--open-files-in-pager=${helper}`, 'needle'],
    [`--op=${helper}`, 'needle'],
    ['--textconv', 'reviewer-only helper content'],
    ['--textc', 'reviewer-only helper content'],
  ]) {
    const result = spawnSync(script, args, {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GIT_PAGER: helper },
    });
    assert.equal(result.status, 2, args.join(' '));
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /external helpers/u);
  }
  assert.deepEqual(grep(['--text', '-l', 'needle']), [...readable].toSorted());
  assert.deepEqual(
    grep(['--no-textconv', '-l', 'needle']),
    [...readable].toSorted(),
  );
});

test('implementer-conflicts names reviewer-only conflicts without their content', (t) => {
  const { cwd } = repository(t);
  const conflicts = fileURLToPath(
    new URL('implementer-conflicts', import.meta.url),
  );
  const config = [
    '-c',
    'user.name=Test',
    '-c',
    'user.email=test@example.invalid',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'core.hooksPath=/dev/null',
  ];
  const git = (...args) =>
    execFileSync('git', [...config, ...args], { cwd, encoding: 'utf8' });
  const files = [...reviewerOnly, ...readable];
  const commitAll = (branch, text) => {
    git('checkout', '-q', '-B', branch, 'fixture');
    for (const file of files) {
      writeFileSync(path.join(cwd, file), `${text}\n`);
    }
    git('commit', '-qam', branch);
  };
  git('branch', 'fixture');
  commitAll('theirs', 'reviewer-only theirs content');
  commitAll('ours', 'reviewer-only ours content');
  const merge = spawnSync('git', [...config, 'merge', '-q', 'theirs'], {
    cwd,
    encoding: 'utf8',
  });
  assert.equal(merge.status, 1, merge.stderr);
  git('config', 'diff.relative', 'true');
  for (const from of ['.', 'docs']) {
    const result = spawnSync(conflicts, [], {
      cwd: path.join(cwd, from),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    const [implementer, reviewer] = result.stdout
      .split('Reviewer-only conflicts')
      .map((section) => section.trim().split('\n').slice(1).toSorted());
    assert.deepEqual(implementer, [...readable].toSorted());
    assert.deepEqual(reviewer, [...reviewerOnly].toSorted());
  }
  const result = spawnSync(conflicts, ['--diff'], { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(
    result.stdout
      .split('\n')
      .filter((line) => line.startsWith('diff --cc '))
      .toSorted(),
    readable.map((file) => `diff --cc ${file}`).toSorted(),
  );
});

test('implementer-show reads a reviewer fix commit and names its reviewer-only paths', (t) => {
  const { cwd } = repository(t);
  const show = fileURLToPath(new URL('implementer-show', import.meta.url));
  for (const file of [...reviewerOnly, ...readable]) {
    writeFileSync(path.join(cwd, file), 'reviewer fix\n');
  }
  execFileSync(
    'git',
    [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.invalid',
      '-c',
      'commit.gpgsign=false',
      '-c',
      'core.hooksPath=/dev/null',
      'commit',
      '-qam',
      'reviewer fix',
    ],
    { cwd },
  );
  const run = (args, from = '.') =>
    spawnSync(show, args, { cwd: path.join(cwd, from), encoding: 'utf8' });
  const heading = 'Reviewer-only paths (names only; do not open):';
  for (const [args, from, shown] of [
    [['HEAD'], '.', readable],
    [
      ['--pickaxe-all', '-S', 'fix', 'HEAD', '--', 'docs'],
      '.',
      ['docs/guide.md'],
    ],
    [['-s', 'HEAD'], '.', []],
    [['HEAD~..HEAD', '--', 'docs', '.patterns'], '.', ['docs/guide.md']],
    [['--diff', 'HEAD~', 'HEAD'], '.', readable],
    [['--diff', '--pickaxe-all', '-S', 'fix', 'HEAD~', 'HEAD'], '.', readable],
    [['--diff', 'HEAD~..HEAD', '--', '.'], 'docs', ['docs/guide.md']],
  ]) {
    const result = run(args, from);
    assert.equal(result.status, 0, result.stderr);
    const [output, names] = result.stdout.split(`${heading}\n`);
    assert.deepEqual(
      output
        .split('\n')
        .filter((line) => line.startsWith('diff --git '))
        .toSorted(),
      shown.map((file) => `diff --git a/${file} b/${file}`).toSorted(),
    );
    assert.deepEqual(
      names.trim().split('\n').toSorted(),
      [...reviewerOnly].toSorted(),
    );
  }
  const exitCode = run(['--diff', '--exit-code', 'HEAD~', 'HEAD']);
  assert.equal(exitCode.status, 1, exitCode.stderr);
  assert.ok(exitCode.stdout.includes(heading), exitCode.stdout);
  const blob = execFileSync(
    'git',
    ['rev-parse', 'HEAD:docs/architecture/README.md'],
    { cwd, encoding: 'utf8' },
  ).trim();
  for (const args of [
    ['HEAD:docs/architecture/README.md'],
    [blob],
    ['--diff', `${blob}..HEAD`],
    ['--full-diff', 'HEAD', '--', 'docs/guide.md'],
    ['--diff', '--no-index', 'docs/architecture/README.md', 'docs/guide.md'],
    ['--textconv', 'HEAD'],
  ]) {
    const result = run(args);
    assert.equal(result.status, 2, `${args.join(' ')}: ${result.stdout}`);
    assert.equal(result.stdout, '');
  }
});
