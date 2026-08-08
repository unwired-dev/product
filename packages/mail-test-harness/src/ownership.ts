import type { ChildProcess } from 'node:child_process';

import { randomUUID } from 'node:crypto';
import { readFile, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { waitForExit } from './process.ts';

const RUN_DIRECTORY_PREFIX = 'unwired-mail-test-';
const OWNERSHIP_FILE = 'ownership.json';

export interface OwnershipRecord {
  createdAt: string;
  process: null | {
    commandMarker: string;
    pid: number;
  };
  resources: {
    paths: string[];
    ports: number[];
  };
  root: string;
  runId: string;
  schemaVersion: 1;
  token: string;
}

export interface CleanupResult {
  processStopped: boolean;
  runDirectoryRemoved: boolean;
}

export interface DoctorFinding {
  createdAt?: string;
  root: string;
  runId?: string;
  status: 'ambiguous' | 'running-owned' | 'stale';
}

export async function createOwnershipRecord(
  root: string,
): Promise<OwnershipRecord> {
  const record: OwnershipRecord = {
    createdAt: new Date().toISOString(),
    process: null,
    resources: { paths: [], ports: [] },
    root,
    runId: randomUUID(),
    schemaVersion: 1,
    token: randomUUID(),
  };
  await persistOwnershipRecord(record);
  return record;
}

export async function persistOwnershipRecord(
  record: Readonly<OwnershipRecord>,
): Promise<void> {
  await writeFile(
    path.join(record.root, OWNERSHIP_FILE),
    `${JSON.stringify(record, null, 2)}\n`,
    {
      mode: 0o600,
    },
  );
}

export async function cleanupOwnedRun(
  expected: Readonly<OwnershipRecord>,
  child?: ChildProcess,
): Promise<CleanupResult> {
  const actual = await readVerifiedOwnershipRecord(
    expected.root,
    path.dirname(expected.root),
  );
  if (actual.runId !== expected.runId || actual.token !== expected.token) {
    throw new Error('Mail test cleanup refused an ownership-record mismatch.');
  }

  let processStopped = actual.process === null;
  if (actual.process !== null) {
    if (child?.pid !== actual.process.pid) {
      throw new Error('Mail test cleanup refused an unowned process.');
    }
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      const exited = await Promise.race([
        waitForExit(child).then(() => true),
        new Promise<false>((resolve) => {
          setTimeout(() => {
            resolve(false);
          }, 2000);
        }),
      ]);
      if (!exited) {
        child.kill('SIGKILL');
        await waitForExit(child);
      }
    }
    processStopped = true;
  }

  await rm(actual.root, { force: true, recursive: true });
  return { processStopped, runDirectoryRemoved: true };
}

export async function inspectOwnedRuns(
  baseDirectory = tmpdir(),
): Promise<DoctorFinding[]> {
  const resolvedBaseDirectory = await realpath(baseDirectory);
  const entries = await readdir(resolvedBaseDirectory, { withFileTypes: true });
  const findings: DoctorFinding[] = [];
  for (const entry of entries) {
    if (entry.isDirectory() && entry.name.startsWith(RUN_DIRECTORY_PREFIX)) {
      const root = path.join(resolvedBaseDirectory, entry.name);
      try {
        const record = await readVerifiedOwnershipRecord(
          root,
          resolvedBaseDirectory,
        );
        findings.push({
          createdAt: record.createdAt,
          root,
          runId: record.runId,
          status: await ownershipStatus(record),
        });
      } catch {
        findings.push({ root, status: 'ambiguous' });
      }
    }
  }
  return findings;
}

export function runDirectoryPrefix(): string {
  return RUN_DIRECTORY_PREFIX;
}

async function readVerifiedOwnershipRecord(
  root: string,
  expectedBaseDirectory: string,
): Promise<OwnershipRecord> {
  if (
    path.dirname(root) !== expectedBaseDirectory ||
    !path.basename(root).startsWith(RUN_DIRECTORY_PREFIX)
  ) {
    throw new Error(
      'Mail test cleanup refused a path outside the run directory boundary.',
    );
  }
  const resolvedRoot = await realpath(root);
  if (resolvedRoot !== root) {
    throw new Error('Mail test cleanup refused a redirected run directory.');
  }
  const parsed: unknown = JSON.parse(
    await readFile(path.join(root, OWNERSHIP_FILE), 'utf8'),
  );
  if (
    !isOwnershipRecord(parsed) ||
    parsed.root !== root ||
    parsed.resources.paths.some(
      (ownedPath) => !ownedPath.startsWith(`${root}${path.sep}`),
    )
  ) {
    throw new Error('Mail test cleanup refused an invalid ownership record.');
  }
  return parsed;
}

async function ownershipStatus(
  record: Readonly<OwnershipRecord>,
): Promise<DoctorFinding['status']> {
  if (record.process === null) {
    return 'stale';
  }
  if (
    await processMatchesMarker(record.process.pid, record.process.commandMarker)
  ) {
    return 'running-owned';
  }
  return isProcessAlive(record.process.pid) ? 'ambiguous' : 'stale';
}

function isOwnershipRecord(value: unknown): value is OwnershipRecord {
  if (typeof value !== 'object' || value === null) {
    return false;
  }
  const candidate = value as Partial<OwnershipRecord>;
  return (
    hasOwnershipMetadata(candidate) &&
    hasOwnershipIdentity(candidate) &&
    isOwnershipResources(candidate.resources) &&
    isOwnershipProcess(candidate.process)
  );
}

function hasOwnershipMetadata(value: Partial<OwnershipRecord>): boolean {
  return (
    value.schemaVersion === 1 &&
    typeof value.createdAt === 'string' &&
    typeof value.root === 'string'
  );
}

function hasOwnershipIdentity(value: Partial<OwnershipRecord>): boolean {
  return typeof value.runId === 'string' && typeof value.token === 'string';
}

function isOwnershipProcess(
  value: OwnershipRecord['process'] | undefined,
): value is OwnershipRecord['process'] {
  return (
    value === null ||
    (isOwnershipProcessObject(value) && hasOwnershipProcessFields(value))
  );
}

function isOwnershipProcessObject(
  value: OwnershipRecord['process'] | undefined,
): value is NonNullable<OwnershipRecord['process']> {
  return typeof value === 'object' && value !== null;
}

function hasOwnershipProcessFields(
  value: NonNullable<OwnershipRecord['process']>,
): boolean {
  return (
    typeof value.commandMarker === 'string' &&
    value.commandMarker.length > 0 &&
    typeof value.pid === 'number'
  );
}

function isOwnershipResources(
  value: OwnershipRecord['resources'] | undefined,
): value is OwnershipRecord['resources'] {
  return (
    value !== undefined &&
    Array.isArray(value.paths) &&
    value.paths.every((ownedPath) => typeof ownedPath === 'string') &&
    Array.isArray(value.ports) &&
    value.ports.every(
      (port) => Number.isSafeInteger(port) && port > 0 && port <= 65_535,
    )
  );
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function processMatchesMarker(
  pid: number,
  marker: string,
): Promise<boolean> {
  if (!isProcessAlive(pid)) {
    return false;
  }
  const { runCommand } = await import('./process.ts');
  try {
    const result = await runCommand('ps', [
      '-p',
      String(pid),
      '-o',
      'command=',
    ]);
    return result.stdout.includes(marker);
  } catch {
    return false;
  }
}
