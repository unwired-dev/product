import type ChildProcessModule from 'node:child_process';
import type OS from 'node:os';

import { spawn } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import type { OwnershipRecord } from '../src/ownership.ts';

import { deleteOwnedSimulator } from '../src/apple.ts';
import { runCategorizationScenario } from '../src/harness.ts';
import { cleanupOwnedRun, inspectOwnedRuns } from '../src/ownership.ts';
import { runCommand } from '../src/process.ts';

vi.mock(import('../src/artifact.ts'), async (importOriginal) => ({
  ...(await importOriginal()),
  resolveGreenMailArtifact: async () => 'synthetic-greenmail.jar',
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Promise-based built-in mocks do not preserve spawn's overloads in this Vitest version.
vi.mock('node:child_process', async () => {
  const actual =
    await vi.importActual<typeof ChildProcessModule>('node:child_process');
  return { ...actual, spawn: vi.fn<typeof actual.spawn>() };
});

vi.mock(import('node:os'), async (importOriginal) => ({
  ...(await importOriginal()),
  tmpdir: vi.fn<() => string>(),
}));

vi.mock(import('../src/process.ts'), async (importOriginal) => ({
  ...(await importOriginal()),
  runCommand: vi.fn<typeof runCommand>(),
}));

vi.mock(import('../src/protocol.ts'), async (importOriginal) => ({
  ...(await importOriginal()),
  readIMAPMessage: async (
    _endpoint: unknown,
    _credentials: unknown,
    messageId: string,
  ) => ({
    raw: `Message-ID: <${messageId}>`,
    sequence: 1,
    tlsVersion: 'TLSv1.3',
  }),
  sendSMTPSMessage: async () => 'TLSv1.3',
  waitForMailServer: async () => undefined,
  waitForSMTPServer: async () => undefined,
}));

vi.mock(import('../src/apple.ts'), async (importOriginal) => ({
  ...(await importOriginal()),
  createMailTestSimulator: async (runId: string) => ({
    name: `Unwired Mail Test ${runId}`,
    runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
    udid: '00000000-0000-0000-0000-000000000000',
  }),
  deleteOwnedSimulator: vi.fn<typeof deleteOwnedSimulator>(),
  prepareMailTestSimulator: async () => undefined,
  runMailTestApplication: async () => 'performed' as const,
}));

describe('scenario cleanup ownership', () => {
  it('keeps the reported orphan until explicit recovery after a transient simulator cleanup failure', async () => {
    expect.assertions(4);
    const os = await vi.importActual<typeof OS>('node:os');
    const base = await realpath(
      await mkdtemp(path.join(os.tmpdir(), 'mail-test-lifecycle-')),
    );
    const childProcess =
      await vi.importActual<typeof ChildProcessModule>('node:child_process');
    const child = childProcess.spawn(process.execPath, [
      '-e',
      'setInterval(() => {}, 1000)',
    ]);
    vi.mocked(tmpdir).mockReturnValue(base);
    vi.mocked(spawn).mockReturnValue(child);
    vi.mocked(runCommand).mockImplementation(fakeJavaCommand);
    vi.mocked(deleteOwnedSimulator)
      .mockRejectedValueOnce(new Error('transient simulator deletion failure'))
      .mockResolvedValue();
    try {
      await expect(runCategorizationScenario()).rejects.toThrow(
        'cleanup preserved',
      );
      const orphans = await inspectOwnedRuns(base);
      expect(orphans).toMatchObject([{ status: 'stale' }]);
      const { root } = orphans[0]!;
      const record: OwnershipRecord = JSON.parse(
        await readFile(path.join(root, 'ownership.json'), 'utf8'),
      );
      await expect(cleanupOwnedRun(record)).resolves.toStrictEqual({
        processStopped: true,
        runDirectoryRemoved: true,
      });
      await expect(inspectOwnedRuns(base)).resolves.toStrictEqual([]);
    } finally {
      child.kill('SIGKILL');
      vi.mocked(deleteOwnedSimulator).mockReset();
      vi.mocked(spawn).mockReset();
      vi.mocked(tmpdir).mockReset();
      vi.mocked(runCommand).mockReset();
      await rm(base, { force: true, recursive: true });
    }
  });
});

async function fakeJavaCommand(
  _command: string,
  args: readonly string[],
): Promise<{ stderr: string; stdout: string }> {
  const fileIndex = args.indexOf('-file');
  if (fileIndex !== -1) {
    await writeFile(args[fileIndex + 1]!, 'synthetic certificate');
  }
  return { stderr: '', stdout: 'java version "21"' };
}
