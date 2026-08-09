import { mkdtemp, realpath, rm, stat } from 'node:fs/promises';
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
    try {
      const record = createManualSandboxRecord(root, endpoints);
      await persistManualSandboxRecord({
        ...record,
        process: {
          commandMarker: path.join(root, 'java.args'),
          pid: process.pid,
        },
      });

      await expect(stopManualSandbox(root)).rejects.toThrow('unowned process');
      await expect(stat(root)).resolves.toBeDefined();
    } finally {
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
});
