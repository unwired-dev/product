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

const required = <Value>(value: Value | undefined): Value => {
  if (value === undefined) {
    throw new Error('Expected a value');
  }
  return value;
};

// A host over a native module whose vault, Gmail and Drafts are synthetic. Attachment reads wait
// until native code cancels them by name; the counts are the native reads the host made.
function syntheticHost() {
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
  const host = createHost(() => {
    counts.lookups += 1;
    return native;
  });
  return { host, gmail, attachments: attachments.promise, cancelled, counts };
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
