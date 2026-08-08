import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { mkdtemp, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type { OwnershipRecord } from '../src/ownership.ts';

import {
  cleanupOwnedRun,
  createOwnershipRecord,
  inspectOwnedRuns,
  persistOwnershipRecord,
  runDirectoryPrefix,
} from '../src/ownership.ts';

async function createRunDirectory(): Promise<string> {
  const base = await realpath(tmpdir());
  return mkdtemp(path.join(base, runDirectoryPrefix()));
}

function spawnCancellationFixture(): { child: ChildProcess; pid: number } {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
    stdio: 'ignore',
  });
  if (child.pid === undefined) {
    throw new Error(
      'The cancellation fixture did not expose a process identifier.',
    );
  }
  return { child, pid: child.pid };
}

function childHasStopped(child: ChildProcess): boolean {
  return child.exitCode !== null || child.signalCode !== null;
}

describe('run ownership cleanup', () => {
  it('removes only a matching owned directory', async () => {
    expect.assertions(2);
    const root = await createRunDirectory();
    const record = await createOwnershipRecord(root);
    await writeFile(path.join(root, 'owned.txt'), 'owned');

    await expect(cleanupOwnedRun(record)).resolves.toStrictEqual({
      processStopped: true,
      runDirectoryRemoved: true,
    });
    await expect(stat(root)).rejects.toMatchObject({ code: 'ENOENT' });
  });

  it('fails closed on an ownership-token mismatch and preserves the directory', async () => {
    expect.assertions(2);
    const root = await createRunDirectory();
    const record = await createOwnershipRecord(root);
    const mismatched: OwnershipRecord = {
      ...record,
      token: 'not-the-recorded-token',
    };
    try {
      await expect(cleanupOwnedRun(mismatched)).rejects.toThrow(
        'ownership-record mismatch',
      );
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });

  it('terminates only its recorded child during cancellation cleanup', async () => {
    expect.assertions(2);
    const root = await createRunDirectory();
    const { child, pid } = spawnCancellationFixture();
    try {
      let record = await createOwnershipRecord(root);
      record = {
        ...record,
        process: { commandMarker: 'setInterval', pid },
      };
      await persistOwnershipRecord(record);

      await expect(cleanupOwnedRun(record, child)).resolves.toStrictEqual({
        processStopped: true,
        runDirectoryRemoved: true,
      });
      expect(childHasStopped(child)).toBe(true);
    } finally {
      child.kill('SIGKILL');
      await rm(root, { force: true, recursive: true });
    }
  });

  it('refuses a supplied child whose pid does not match the ownership record', async () => {
    expect.assertions(3);
    const root = await createRunDirectory();
    const recorded = spawnCancellationFixture();
    const supplied = spawnCancellationFixture();
    try {
      let record = await createOwnershipRecord(root);
      record = {
        ...record,
        process: { commandMarker: 'setInterval', pid: recorded.pid },
      };
      await persistOwnershipRecord(record);

      await expect(cleanupOwnedRun(record, supplied.child)).rejects.toThrow(
        'unowned process',
      );
      await expect(stat(root)).resolves.toBeDefined();
      expect({
        recordedStopped: childHasStopped(recorded.child),
        suppliedStopped: childHasStopped(supplied.child),
      }).toStrictEqual({ recordedStopped: false, suppliedStopped: false });
    } finally {
      recorded.child.kill('SIGKILL');
      supplied.child.kill('SIGKILL');
      await rm(root, { force: true, recursive: true });
    }
  });

  it('removes the run directory after simulator cleanup fails', async () => {
    expect.assertions(3);
    const root = await createRunDirectory();
    let record = await createOwnershipRecord(root);
    record = {
      ...record,
      resources: {
        ...record.resources,
        simulatorIntents: [{ name: `Unwired Mail Test ${record.runId}` }],
      },
    };
    await persistOwnershipRecord(record);
    const deleteSimulator = vi.fn<(simulator: unknown) => Promise<void>>(
      async () => {
        throw new Error('simulator deletion failed');
      },
    );

    await expect(
      cleanupOwnedRun(record, undefined, deleteSimulator),
    ).rejects.toThrow('simulator deletion failed');
    expect(deleteSimulator).toHaveBeenCalledWith({
      name: `Unwired Mail Test ${record.runId}`,
    });
    await expect(stat(root)).rejects.toMatchObject({ code: 'ENOENT' });
  });
});

describe('doctor', () => {
  it('reports a stale ownership record without deleting it', async () => {
    expect.assertions(2);
    const base = await realpath(
      await mkdtemp(path.join(await realpath(tmpdir()), 'mail-test-doctor-')),
    );
    const root = await mkdtemp(path.join(base, runDirectoryPrefix()));
    try {
      const record = await createOwnershipRecord(root);
      await expect(inspectOwnedRuns(base)).resolves.toStrictEqual([
        {
          createdAt: record.createdAt,
          root,
          runId: record.runId,
          status: 'stale',
        },
      ]);
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
      await rm(base, { force: true, recursive: true });
    }
  });

  it('treats an empty process marker as ambiguous ownership', async () => {
    expect.assertions(1);
    const base = await realpath(
      await mkdtemp(path.join(await realpath(tmpdir()), 'mail-test-doctor-')),
    );
    const root = await mkdtemp(path.join(base, runDirectoryPrefix()));
    try {
      const record = await createOwnershipRecord(root);
      await persistOwnershipRecord({
        ...record,
        process: { commandMarker: '', pid: process.pid },
      });
      await expect(inspectOwnedRuns(base)).resolves.toStrictEqual([
        { root, status: 'ambiguous' },
      ]);
    } finally {
      await rm(base, { force: true, recursive: true });
    }
  });
});
