import type { ChildProcess } from 'node:child_process';

import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, realpath, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  containsManualSandboxFixture,
  createManualSandboxRecord,
  injectManualSandbox,
  persistManualSandboxRecord,
  readVerifiedManualSandboxRecord,
  resetManualSandbox,
  statusManualSandbox,
  stopManualSandbox,
} from '../src/sandbox.ts';

async function createSandboxDirectory(): Promise<string> {
  return realpath(
    await mkdtemp(path.join(await realpath(tmpdir()), 'manual-mail-sandbox-')),
  );
}

async function spawnThrowawayProcess(): Promise<{
  child: ChildProcess;
  pid: number;
}> {
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {
    stdio: 'ignore',
  });
  await once(child, 'spawn');
  if (child.pid === undefined) {
    throw new Error('Throwaway test process did not expose a PID.');
  }
  return { child, pid: child.pid };
}

async function stopThrowawayProcess(child: ChildProcess): Promise<void> {
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGKILL');
    await once(child, 'exit');
  }
}

async function persistUnverifiedRecord(
  root: string,
  record: unknown,
): Promise<void> {
  await writeFile(
    path.join(root, 'sandbox.json'),
    `${JSON.stringify(record, null, 2)}\n`,
  );
}

const endpoints = { apiPort: 18_080, imapsPort: 1993, smtpsPort: 1465 };

describe('manual mail sandbox ownership', () => {
  it('recognizes the canonical fixture in GreenMail actual and documented shapes', () => {
    expect.assertions(3);
    expect(
      containsManualSandboxFixture([
        { 'Message-ID': '<manual-core-mail-loop@synthetic.invalid>' },
      ]),
    ).toBe(true);
    expect(
      containsManualSandboxFixture([
        { messageId: 'manual-core-mail-loop@synthetic.invalid' },
      ]),
    ).toBe(true);
    expect({
      contains: containsManualSandboxFixture([
        { 'Message-ID': '<other@synthetic.invalid>' },
      ]),
    }).toStrictEqual({ contains: false });
  });

  it('persists and verifies a sandbox-scoped ownership record', async () => {
    expect.assertions(2);
    const root = await createSandboxDirectory();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord(record);

      await expect(
        readVerifiedManualSandboxRecord(root),
      ).resolves.toStrictEqual(record);
      expect(record.resources.simulatorIntent.name).toBe(
        `Unwired Mail Manual Sandbox ${record.runId}`,
      );
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });

  it('rejects every invalid ownership-record discriminator', async () => {
    expect.assertions(11);
    const root = await createSandboxDirectory();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      const invalidRecords: unknown[] = [
        { ...record, kind: 'other-kind' },
        { ...record, schemaVersion: 2 },
        { ...record, scenario: 'other-scenario' },
        { ...record, root: `${root}-other` },
        { ...record, runId: 'not-a-uuid' },
        { ...record, token: 'not-a-uuid' },
        {
          ...record,
          process: { commandMarker: path.join(root, 'other.args'), pid: 1 },
        },
        {
          ...record,
          resources: {
            ...record.resources,
            endpoints: { ...endpoints, smtpsPort: endpoints.imapsPort },
          },
        },
        {
          ...record,
          resources: {
            ...record.resources,
            endpoints: { ...endpoints, apiPort: 70_000 },
          },
        },
        {
          ...record,
          resources: {
            ...record.resources,
            simulatorIntent: { name: 'Unwired Mail Manual Sandbox other' },
          },
        },
        {
          ...record,
          resources: {
            ...record.resources,
            simulator: {
              name: record.resources.simulatorIntent.name,
              runtime: 'iOS 26.5',
              udid: 'not-a-udid',
            },
          },
        },
      ];

      for (const invalidRecord of invalidRecords) {
        await persistUnverifiedRecord(root, invalidRecord);
        await expect(readVerifiedManualSandboxRecord(root)).rejects.toThrow(
          'ownership is uncertain',
        );
      }
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });

  it('reports a valid but inactive sandbox as stale without exposing credentials', async () => {
    expect.assertions(2);
    const root = await createSandboxDirectory();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord(record);

      const evidence = await statusManualSandbox(undefined, root);

      expect(evidence).toMatchObject({
        action: 'status',
        endpoints: {
          imaps: { host: '127.0.0.1', port: 1993 },
          smtps: { host: '127.0.0.1', port: 1465 },
        },
        kind: 'manual-mail-sandbox',
        runId: record.runId,
        scenario: 'core-mail-loop',
        status: 'stale',
      });
      expect(JSON.stringify(evidence)).not.toContain('synthetic-test-password');
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });

  it('refuses to stop a process that does not match the exact command marker', async () => {
    expect.assertions(2);
    const root = await createSandboxDirectory();
    const child = await spawnThrowawayProcess();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord({
        ...record,
        process: {
          commandMarker: path.join(root, 'java.args'),
          pid: child.pid,
        },
      });

      await expect(stopManualSandbox(root)).rejects.toThrow('unowned process');
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
      await stopThrowawayProcess(child.child);
      await rm(root, { force: true, recursive: true });
    }
  });

  it('rejects status when the live PID does not match its command marker', async () => {
    expect.assertions(1);
    const root = await createSandboxDirectory();
    const child = await spawnThrowawayProcess();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord({
        ...record,
        process: {
          commandMarker: path.join(root, 'java.args'),
          pid: child.pid,
        },
      });

      await expect(statusManualSandbox(undefined, root)).rejects.toThrow(
        'recorded PID no longer matches',
      );
    } finally {
      await stopThrowawayProcess(child.child);
      await rm(root, { force: true, recursive: true });
    }
  });

  it('fails closed when a recorded resource escapes the sandbox root', async () => {
    expect.assertions(2);
    const root = await createSandboxDirectory();
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord({
        ...record,
        resources: { ...record.resources, paths: ['/tmp/not-owned'] },
      });

      await expect(stopManualSandbox(root)).rejects.toThrow(
        'ownership is uncertain',
      );
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });

  it('keeps status and stop idempotent when no sandbox exists', async () => {
    expect.assertions(2);
    const parent = await createSandboxDirectory();
    const root = path.join(parent, 'missing');
    try {
      await expect(statusManualSandbox(undefined, root)).resolves.toMatchObject(
        {
          action: 'status',
          status: 'stopped',
        },
      );
      await expect(stopManualSandbox(root)).resolves.toMatchObject({
        action: 'stopped',
        status: 'stopped',
      });
    } finally {
      await rm(parent, { force: true, recursive: true });
    }
  });

  it('requires a running sandbox before inject or reset', async () => {
    expect.assertions(2);
    const parent = await createSandboxDirectory();
    const root = path.join(parent, 'missing');
    try {
      await expect(injectManualSandbox(undefined, root)).rejects.toThrow(
        'is stopped',
      );
      await expect(resetManualSandbox(undefined, root)).rejects.toThrow(
        'is stopped',
      );
    } finally {
      await rm(parent, { force: true, recursive: true });
    }
  });

  it('rejects reset when the owned simulator is missing', async () => {
    expect.assertions(1);
    const root = await createSandboxDirectory();
    try {
      await persistManualSandboxRecord(
        createManualSandboxRecord(root, endpoints),
      );

      await expect(resetManualSandbox(undefined, root)).rejects.toThrow(
        'owned simulator is missing',
      );
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });
});
