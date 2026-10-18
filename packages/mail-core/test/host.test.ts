import type { NativeErrorReporting } from '@private-email/mail-core/error-reporting';

import type { NativeHostModule } from '../src/host.ts';

import { createHost } from '../src/host.ts';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '../src/testing/drafts.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import {
  createSyntheticVault,
  syntheticMailboxes,
} from '../src/testing/registration-vault.ts';
import { reportingFixture } from './error-reporting-fixture.ts';

const required = <Value>(value: Value | undefined): Value => {
  if (value === undefined) {
    throw new Error('Expected a value');
  }
  return value;
};

// A host over a native module whose vault, Gmail and Drafts are synthetic. Attachment reads wait
// until native code cancels them by name; the counts are the native reads the host made.
function syntheticHost(reporting?: NativeErrorReporting) {
  const gmail = createSyntheticGmail();
  const { vault } = createSyntheticVault();
  const base = syntheticConnections({
    [syntheticMailboxes['alex@example.invalid']]: gmail,
  });
  const drafts = createSyntheticDrafts(() => undefined, {
    server: createSyntheticProductSync(),
  });
  const held = new Map<string, () => void>();
  const attachments = Promise.withResolvers<string>();
  const cancelled: string[] = [];
  const counts = { lookups: 0, registration: 0, settings: 0, wakes: 0 };
  const native: NativeHostModule = {
    ...vault,
    ...base,
    ...drafts.native,
    ...required(drafts.sync),
    ...required(drafts.delivery),
    registration: () => {
      counts.registration += 1;
      return vault.registration();
    },
    gmailRequest: async (path, query, scope) => {
      if (!path.includes('/attachments/')) {
        return base.gmailRequest(path, query, scope);
      }
      // The host names each read it can cancel.
      const request = 'request' in scope ? String(scope.request) : '';
      const { promise, reject } = Promise.withResolvers<unknown>();
      held.set(request, () => {
        reject(new Error('cancelled'));
      });
      attachments.resolve(request);
      return promise;
    },
    cancelGmailRequest: (request) => {
      cancelled.push(request);
      held.get(request)?.();
    },
    nextWake: () => {
      counts.wakes += 1;
      return Promise.withResolvers<unknown>().promise;
    },
    mailboxRoutes: () => Promise.resolve({ routes: [] }),
    completeWake: () => undefined,
    remoteContentSettings: () => {
      counts.settings += 1;
      return Promise.resolve({ settings: null });
    },
    setRemoteContentSettings: () => Promise.resolve(null),
    clearRemoteContent: () => Promise.resolve(null),
  };
  const host = createHost(
    () => {
      counts.lookups += 1;
      return native;
    },
    reporting === undefined ? undefined : () => reporting,
  );
  return {
    host,
    native,
    gmail,
    attachments: attachments.promise,
    cancelled,
    counts,
  };
}

describe('the host assembly', () => {
  it('looks up nothing native to assemble, and cancels an aborted Gmail read by its request name', async () => {
    expect.hasAssertions();
    const { host, gmail, attachments, cancelled, counts } = syntheticHost();
    expect(counts.lookups).toBe(0);
    const id = gmail.deliver({ content: { text: 'Notes attached.' } });
    await host.registration.register('google');
    await host.registration.addMailbox();
    await host.gmailMailboxes.load();
    const inbox = required(host.gmailMailboxes.getSnapshot()[0]?.inbox);
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    const locator = required(inbox.messageAttachments(id)?.[0]?.locator);
    const download = inbox.downloadAttachment(id, locator);
    const request = await attachments;
    inbox.cancelAttachment(id, locator);
    await download;
    close();
    expect(cancelled).toStrictEqual([request]);
  });

  it('reports resolved provider HTTP failures without changing send or synchronization outcomes', async () => {
    expect.hasAssertions();
    const reporting = reportingFixture();
    const { host, native } = syntheticHost(reporting.native);
    try {
      await host.errorReporting.load();
      await host.errorReporting.setEnabled(true);
      await host.registration.register('google');
      await host.registration.addMailbox();
      await host.gmailMailboxes.load();
      const inbox = required(host.gmailMailboxes.getSnapshot()[0]?.inbox);
      vi.spyOn(native, 'gmailSend').mockResolvedValue({
        status: 503,
        body: 'private mail subject',
      });
      await expect(
        inbox.send({ segments: [{ text: 'private mail body' }] }),
      ).resolves.toStrictEqual({ kind: 'unknown' });
      vi.spyOn(native, 'gmailRequest').mockResolvedValue({
        status: 503,
        body: 'private mailbox address',
      });
      await inbox.load();
      await host.errorReporting.refresh();
      const captures = reporting.requests
        .filter((request) => request.operation === 'capture')
        .map((request) => request.body)
        .join('');
      expect(captures).toContain('send-failed');
      expect(captures).toContain('sync-failed');
      expect(captures).toContain('"status":503');
      expect(captures).not.toContain('private');
      const before = reporting.requests.filter(
        (request) => request.operation === 'capture',
      ).length;
      vi.mocked(native.gmailRequest).mockRejectedValue({ code: 'offline' });
      await inbox.load();
      vi.mocked(native.gmailRequest).mockRejectedValue({ code: 'cancelled' });
      await inbox.load();
      vi.mocked(native.gmailRequest).mockRejectedValue({ code: 'unavailable' });
      await inbox.load();
      await host.errorReporting.refresh();
      // oxlint-disable-next-line vitest/max-expects -- This public journey proves outcomes and payload privacy together.
      expect(
        reporting.requests.filter((request) => request.operation === 'capture'),
      ).toHaveLength(before);
    } finally {
      host.errorReporting.dispose();
      vi.restoreAllMocks();
    }
  });

  it('reports a failed backend envelope even when its HTTP transport succeeded', async () => {
    expect.hasAssertions();
    const reporting = reportingFixture();
    const { host, native } = syntheticHost(reporting.native);
    try {
      await host.errorReporting.load();
      await host.errorReporting.setEnabled(true);
      await host.registration.register('google');
      vi.spyOn(native, 'call').mockResolvedValue({
        status: 200,
        body: '{"status":"error","errorMessage":"private account value"}',
      });
      await host.registration.resume();
      await host.errorReporting.refresh();
      const captures = reporting.requests
        .filter((request) => request.operation === 'capture')
        .map((request) => request.body)
        .join('');
      expect(captures).toMatch(/(?:backend|sync)-failed/u);
      expect(captures).not.toContain('private account value');
      expect(host.registration.getSnapshot().busy).toBe(false);
    } finally {
      host.errorReporting.dispose();
      vi.restoreAllMocks();
    }
  });

  it('starts once however often and concurrently it is asked, and follows wakes once', async () => {
    expect.hasAssertions();
    const { host, counts } = syntheticHost();
    const starting = host.start();
    expect(host.start()).toBe(starting);
    await starting;
    const once = { ...counts };
    await host.start();
    host.followWakes();
    host.followWakes();
    await Promise.resolve();
    expect(host.registration.getSnapshot().busy).toBe(false);
    expect(once.settings).toBe(1);
    expect(counts).toStrictEqual({
      ...once,
      lookups: once.lookups + 1,
      wakes: 1,
    });
  });
});
