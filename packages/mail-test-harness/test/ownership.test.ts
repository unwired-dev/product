import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import {
  mkdtemp,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
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

vi.mock(import('node:fs/promises'), async (importOriginal) => {
  const actual = await importOriginal();
  return {
    ...actual,
    writeFile: vi.fn<typeof actual.writeFile>(actual.writeFile),
  };
});

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

  it('refuses recovery without a child while the recorded process is alive', async () => {
    expect.assertions(3);
    const root = await createRunDirectory();
    const { child, pid } = spawnCancellationFixture();
    try {
      let record = await createOwnershipRecord(root);
      record = { ...record, process: { commandMarker: 'setInterval', pid } };
      await persistOwnershipRecord(record);

      await expect(cleanupOwnedRun(record)).rejects.toThrow('unowned process');
      await expect(stat(root)).resolves.toBeDefined();
      expect(childHasStopped(child)).toBe(false);
    } finally {
      child.kill('SIGKILL');
      await rm(root, { force: true, recursive: true });
    }
  });

  it.each(['EPERM', 'EINVAL', undefined])(
    'preserves the run when the recorded process probe fails with %s',
    async (code) => {
      expect.assertions(4);
      const root = await createRunDirectory();
      const { child, pid } = spawnCancellationFixture();
      const kill = vi.spyOn(process, 'kill');
      try {
        const record = await createOwnershipRecord(root);
        record.process = { commandMarker: 'setInterval', pid };
        record.resources.simulatorIntents = [
          { name: `Unwired Mail Test ${record.runId}` },
        ];
        await persistOwnershipRecord(record);
        const original = await readFile(
          path.join(root, 'ownership.json'),
          'utf8',
        );
        const deleteSimulator = vi
          .fn<() => Promise<void>>()
          .mockResolvedValue();
        kill.mockImplementationOnce(() => {
          throw Object.assign(new Error('process probe failed'), { code });
        });

        await expect(
          cleanupOwnedRun(record, undefined, deleteSimulator),
        ).rejects.toThrow('unowned process');
        await expect(
          readFile(path.join(root, 'ownership.json'), 'utf8'),
        ).resolves.toBe(original);
        expect(deleteSimulator).not.toHaveBeenCalled();
        expect(childHasStopped(child)).toBe(false);
      } finally {
        kill.mockRestore();
        child.kill('SIGKILL');
        await rm(root, { force: true, recursive: true });
      }
    },
  );

  it('keeps the ownership record for doctor and recovery after simulator cleanup fails', async () => {
    expect.assertions(5);
    const base = await realpath(
      await mkdtemp(path.join(await realpath(tmpdir()), 'mail-test-orphan-')),
    );
    const root = await mkdtemp(path.join(base, runDirectoryPrefix()));
    const { child, pid } = spawnCancellationFixture();
    try {
      let record = await createOwnershipRecord(root);
      const simulator = { name: `Unwired Mail Test ${record.runId}` };
      record = {
        ...record,
        process: { commandMarker: 'setInterval', pid },
        resources: {
          ...record.resources,
          simulatorIntents: [simulator, simulator],
        },
      };
      await persistOwnershipRecord(record);
      const failingDelete = vi
        .fn<(simulator: unknown) => Promise<void>>()
        .mockRejectedValueOnce(new Error('simulator deletion failed'))
        .mockResolvedValueOnce();

      await expect(
        cleanupOwnedRun(record, child, failingDelete),
      ).rejects.toThrow('simulator deletion failed');
      expect(failingDelete.mock.calls).toStrictEqual([
        [simulator],
        [simulator],
      ]);
      await expect(inspectOwnedRuns(base)).resolves.toStrictEqual([
        {
          createdAt: record.createdAt,
          root,
          runId: record.runId,
          status: 'stale',
        },
      ]);

      // Explicit recovery no longer needs the original child process.
      const recoveryDelete = vi.fn<() => Promise<void>>().mockResolvedValue();
      await expect(
        cleanupOwnedRun(record, undefined, recoveryDelete),
      ).resolves.toStrictEqual({
        processStopped: true,
        runDirectoryRemoved: true,
      });
      await expect(stat(root)).rejects.toMatchObject({ code: 'ENOENT' });
    } finally {
      child.kill('SIGKILL');
      await rm(base, { force: true, recursive: true });
    }
  });

  it('preserves recovery ownership when the cleanup record update fails partway through writing', async () => {
    expect.assertions(5);
    const base = await realpath(
      await mkdtemp(path.join(await realpath(tmpdir()), 'mail-test-orphan-')),
    );
    const root = await mkdtemp(path.join(base, runDirectoryPrefix()));
    const { child, pid } = spawnCancellationFixture();
    try {
      const record = await createOwnershipRecord(root);
      record.process = { commandMarker: 'setInterval', pid };
      record.resources.simulatorIntents = [
        { name: `Unwired Mail Test ${record.runId}` },
      ];
      await persistOwnershipRecord(record);
      const original = await readFile(
        path.join(root, 'ownership.json'),
        'utf8',
      );
      const actual = await vi.importActual<{ writeFile: typeof writeFile }>(
        'node:fs/promises',
      );
      vi.mocked(writeFile).mockImplementationOnce(async (file) => {
        await actual.writeFile(file, '{');
        throw new Error('ownership write failed');
      });

      await expect(
        cleanupOwnedRun(record, child, async () => {
          throw new Error('simulator deletion failed');
        }),
      ).rejects.toThrow('ownership write failed');
      await expect(
        readFile(path.join(root, 'ownership.json'), 'utf8'),
      ).resolves.toBe(original);
      await expect(inspectOwnedRuns(base)).resolves.toStrictEqual([
        {
          createdAt: record.createdAt,
          root,
          runId: record.runId,
          status: 'stale',
        },
      ]);
      await expect(
        cleanupOwnedRun(record, undefined, () => Promise.resolve()),
      ).resolves.toStrictEqual({
        processStopped: true,
        runDirectoryRemoved: true,
      });
      await expect(stat(root)).rejects.toMatchObject({ code: 'ENOENT' });
    } finally {
      child.kill('SIGKILL');
      vi.mocked(writeFile).mockReset();
      await rm(base, { force: true, recursive: true });
    }
  });

  it('refuses a recorded simulator that is not bound to its run', async () => {
    expect.assertions(3);
    const root = await createRunDirectory();
    let record = await createOwnershipRecord(root);
    record = {
      ...record,
      resources: {
        ...record.resources,
        simulators: [
          {
            name: 'Unwired Mail Test another-run',
            runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
            udid: '00000000-0000-0000-0000-000000000000',
          },
        ],
      },
    };
    await persistOwnershipRecord(record);
    const deleteSimulator = vi.fn<() => Promise<void>>();
    try {
      await expect(
        cleanupOwnedRun(record, undefined, deleteSimulator),
      ).rejects.toThrow('invalid ownership record');
      expect(deleteSimulator).not.toHaveBeenCalled();
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
      await rm(root, { force: true, recursive: true });
    }
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
