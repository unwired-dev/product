import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('implementer-grep.sh', import.meta.url));

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
  execFileSync('git', ['add', '.'], { cwd });
  return (args, from = '.') => {
    const result = spawnSync(script, args, {
      cwd: path.join(cwd, from),
      encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim().split('\n').toSorted();
  };
}

test('never searches reviewer-only sources, even inside caller pathspecs', (t) => {
  const grep = repository(t);
  const everything = [...readable].toSorted();
  assert.deepEqual(grep(['-l', 'needle']), everything);
  assert.deepEqual(grep(['-l', 'needle', '--', '.']), everything);
  assert.deepEqual(grep(['-l', 'needle', '--', '*.md']), [
    '.opencodereview/AGENTS.md',
    'artifacts/screenshots/inbox.md',
    'docs/guide.md',
  ]);
  assert.deepEqual(grep(['-l', 'needle', '--', 'docs']), ['docs/guide.md']);
});

test('keeps the exclusions when run from a subdirectory', (t) => {
  const grep = repository(t);
  assert.deepEqual(grep(['-l', 'needle'], 'docs'), ['guide.md']);
});
