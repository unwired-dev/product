import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const root = path.resolve(import.meta.dirname, '..');
const rulePath = '.opencodereview/rule.json';

test('delegation covers test sources and uses trusted-base rules for a clean PR range', (t) => {
  const scratchpad = path.join(root, 'scratchpad');
  mkdirSync(scratchpad, { recursive: true });
  const fixture = mkdtempSync(path.join(scratchpad, 'ocr-regression-'));
  t.after(() => rmSync(fixture, { recursive: true, force: true }));

  function git(...args) {
    return execFileSync(
      'git',
      ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', ...args],
      { cwd: fixture, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    ).trim();
  }

  function write(relativePath, content) {
    const target = path.join(fixture, relativePath);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, content);
  }

  function ocr(command, ...args) {
    return JSON.parse(
      execFileSync('pnpm', ['--silent', command, ...args], {
        cwd: root,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }),
    );
  }

  const selectedPaths = [
    'apps/unwired-mail/unwired-mailTests/TestRendezvous.swift',
    'apps/unwired-mail/unwired-mailTests/MailAssistanceQualificationCorpus.swift',
    'apps/unwired-mail/unwired-mailTests/MailAssistanceQualificationEvaluator.swift',
    'apps/unwired-mail/unwired-mailTests/Nested/Support.swift',
    'apps/unwired-mail/unwired-mailMailTestUITests/UIHelper.swift',
    'tools/swiftmail-provider-qualification/Tests/SwiftMailProviderQualificationTests/QualificationTests.swift',
    'tools/swiftmail-provider-qualification/Tests/SwiftMailProviderQualificationTests/Support.swift',
    'packages/convex/test/access.test.ts',
    'docs/review context.md',
  ];
  const excludedPath = 'packages/convex/convex/_generated/api.ts';
  git('init', '-q');
  git('config', 'user.name', 'OCR regression');
  git('config', 'user.email', 'ocr-regression@example.invalid');
  write(rulePath, readFileSync(path.join(root, rulePath)));
  for (const file of [...selectedPaths, excludedPath]) write(file, 'before\n');
  git('add', '.');
  git('commit', '-qm', 'trusted base');
  const base = git('rev-parse', 'HEAD');

  for (const file of [...selectedPaths, excludedPath]) write(file, 'after\n');
  write(
    rulePath,
    JSON.stringify({
      exclude: ['**'],
      rules: [{ path: '**', rule: 'PR-controlled rule marker' }],
    }),
  );
  git('add', '.');
  git('commit', '-qm', 'PR changes including its own review rules');
  const head = git('rev-parse', 'HEAD');
  git('checkout', '--detach', base);
  assert.equal(git('status', '--porcelain'), '');

  const trustedArgs = [
    '--repo',
    fixture,
    '--rule',
    path.join(fixture, rulePath),
  ];
  const preview = ocr(
    'review:preview',
    ...trustedArgs,
    '--from',
    base,
    '--to',
    head,
  );
  assert.equal(preview.mode, 'range');
  assert.equal(preview.merge_base, base);
  assert.equal(preview.to, head);
  const paths = preview.reviewable_files.map((file) => file.path);
  assert.deepEqual(new Set(paths), new Set([...selectedPaths, rulePath]));
  assert.deepEqual(
    preview.excluded_files.map(({ path: file, exclude_reason: reason }) => [
      file,
      reason,
    ]),
    [[excludedPath, 'user_exclude']],
  );

  const rules = ocr('review:rules', ...trustedArgs, '--', ...paths);
  assert.deepEqual(
    new Set(rules.groups.flatMap((group) => group.files)),
    new Set(paths),
  );
  for (const group of rules.groups) {
    assert.ok(!group.rule.includes('PR-controlled rule marker'));
    assert.match(group.rule, /User-Specific Rules/);
  }
  assert.equal(git('rev-parse', 'HEAD'), base);
  assert.equal(git('status', '--porcelain'), '');
});
