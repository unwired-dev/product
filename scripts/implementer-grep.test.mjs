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
