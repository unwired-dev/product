import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';

import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

const oid = Schema.String.check(Schema.isPattern(/^[0-9a-f]{40,64}$/u));
const identity = {
  schema: Schema.Literal(1),
  task: Schema.NonEmptyString,
  branch: Schema.NonEmptyString,
  base: oid,
  mergeBase: oid,
  head: oid,
  policy: Schema.NonEmptyString,
};
const checkpointSchema = Schema.fromJsonString(
  Schema.Struct({
    ...identity,
    report: Schema.String.check(Schema.isPattern(/\S/u)),
  }),
);
const planSchema = Schema.fromJsonString(
  Schema.Struct({
    ...identity,
    baseRef: Schema.NonEmptyString,
    forceFull: Schema.Boolean,
    mode: Schema.Literals(['full', 'incremental']),
    reason: Schema.NonEmptyString,
    from: oid,
    to: oid,
    previousReport: Schema.NullOr(Schema.String),
  }),
);

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const digest = (value) => createHash('sha256').update(value).digest('hex');
const commit = (ref) =>
  git('rev-parse', '--verify', '--end-of-options', `${ref}^{commit}`);
const isAncestor = (from, to) => {
  try {
    git('merge-base', '--is-ancestor', from, to);
    return true;
  } catch {
    return false;
  }
};

// The real-Git CLI tests cover this through subprocesses, outside Fallow's static coverage graph.
// fallow-ignore-next-line complexity
function loadCheckpoint(statePath, task, branch) {
  let previous = undefined;
  let reason = 'missing_checkpoint';
  try {
    previous = Option.getOrUndefined(
      Schema.decodeOption(checkpointSchema)(readFileSync(statePath, 'utf8')),
    );
    if (previous?.task !== task || previous?.branch !== branch) {
      previous = undefined;
    }
    reason = 'invalid_checkpoint';
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  return { previous, reason };
}

// Subprocess integration tests exercise each range-selection and invalidation branch.
// fallow-ignore-next-line complexity
function plan(task, baseRef, forceFull = false) {
  if (!task || !baseRef) {
    throw new Error('A stable task ID and target base ref are required.');
  }
  if (git('status', '--porcelain', '--untracked-files=all')) {
    throw new Error(
      'Commit task-owned changes first; use a separate clean worktree for unrelated changes.',
    );
  }
  const branch = git('symbolic-ref', '--quiet', 'HEAD');
  const head = commit('HEAD');
  const base = commit(baseRef);
  const mergeBase = git('merge-base', base, head);
  // Hash object identities, without loading reviewer-only rule bodies.
  const policy = digest(
    git('ls-tree', '-rz', head)
      .split('\0')
      .filter((entry) => {
        const file = entry.slice(entry.indexOf('\t') + 1);
        return (
          /(?:^|\/)AGENTS\.md$/u.test(file) ||
          /^(?:\.agents\/|\.opencodereview\/|\.patterns\/|docs\/(?:agents|architecture|adr|research|qualification|archive)\/)/u.test(
            file,
          ) ||
          file === 'scripts/ocr-checkpoint.mjs'
        );
      })
      .join('\n'),
  );
  const statePath = path.join(
    git('rev-parse', '--path-format=absolute', '--git-common-dir'),
    'ocr-checkpoints',
    `${digest(JSON.stringify([task, branch]))}.json`,
  );
  const checkpoint = loadCheckpoint(statePath, task, branch);
  const { previous } = checkpoint;
  let { reason } = checkpoint;
  if (previous) {
    if (previous.base !== base || previous.mergeBase !== mergeBase) {
      reason = 'base_changed';
    } else if (previous.policy !== policy) {
      reason = 'policy_changed';
    } else if (isAncestor(previous.head, head)) {
      reason = previous.head === head ? 'unchanged' : 'checkpoint';
    } else {
      reason = 'not_ancestor';
    }
  }
  if (forceFull) {
    reason = 'requested_full_review';
  }
  const incremental = reason === 'checkpoint' || reason === 'unchanged';
  return {
    statePath,
    review: {
      schema: 1,
      task,
      branch,
      baseRef,
      base,
      mergeBase,
      head,
      policy,
      forceFull,
      mode: incremental ? 'incremental' : 'full',
      reason,
      from: incremental ? previous.head : mergeBase,
      to: head,
      previousReport: previous?.report ?? null,
    },
  };
}

const [command, first, second, flag, ...extra] = process.argv.slice(2);
try {
  if (
    extra.length ||
    (flag !== undefined && (command !== 'plan' || flag !== '--full'))
  ) {
    throw new Error('Unexpected arguments.');
  }
  if (command === 'plan') {
    const { review } = plan(first, second, flag === '--full');
    process.stdout.write(`${JSON.stringify(review, null, 2)}\n`);
  } else if (command === 'complete' && first && second) {
    const reviewed = Schema.decodeSync(planSchema)(
      readFileSync(first, 'utf8'),
    );
    const { review, statePath } = plan(
      reviewed.task,
      reviewed.baseRef,
      reviewed.forceFull,
    );
    if (!isDeepStrictEqual(reviewed, review)) {
      throw new Error(
        'Review plan is stale. Generate a new plan and review it before completing.',
      );
    }
    const report = readFileSync(second, 'utf8');
    if (!report.trim()) {
      throw new Error('A completed OCR review report is required.');
    }
    mkdirSync(path.dirname(statePath), { recursive: true });
    const temporary = `${statePath}.${randomUUID()}.tmp`;
    writeFileSync(
      temporary,
      `${JSON.stringify({ ...review, report }, null, 2)}\n`,
    );
    renameSync(temporary, statePath);
    process.stdout.write(`Recorded OCR checkpoint ${review.head}\n`);
  } else {
    throw new Error(
      'Usage: node scripts/ocr-checkpoint.mjs plan <task-id> <base-ref> [--full] | complete <plan.json> <report.md>',
    );
  }
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
