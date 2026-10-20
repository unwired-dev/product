import type { NativeErrorReporting } from '@private-email/mail-core/error-reporting';

import type { NativeHostModule } from '../src/host.ts';

import { createHost } from '../src/host.ts';
import { defaultProfile, mailboxesOf } from '../src/registration.ts';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '../src/testing/drafts.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import {
  createSyntheticDevice,
  createSyntheticProductSyncBackend,
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
function syntheticHost(reporting?: NativeErrorReporting, productSync = false) {
  const gmail = createSyntheticGmail();
  const shared = createSyntheticDevice();
  if (productSync) {
    shared.backend.productSync = createSyntheticProductSyncBackend();
  }
  const { vault } = createSyntheticVault(shared);
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
  // This device's notification permission and previews, and what it posted.
  const device = { authorization: 'undetermined', previews: false };
  const notified: unknown[] = [];
  const titles: unknown[] = [];
  // Archive and Mark as Read native code queued for JavaScript; each send settles once completed.
  const queued: unknown[] = [];
  let reading: ((action: unknown) => void) | undefined = undefined;
  const completions = new Map<string, () => void>();
  const notificationActions = {
    send: (action: Readonly<Record<string, string> & { id: string }>) => {
      const completed = Promise.withResolvers<undefined>();
      completions.set(action.id, () => {
        completed.resolve(undefined);
      });
      const reader = reading;
      reading = undefined;
      if (reader === undefined) {
        queued.push(action);
      } else {
        reader(action);
      }
      return completed.promise;
    },
  };
  // While set, settings reads wait for it, as a slow native reply would.
  const settingsGate: { held?: Promise<void>; started?: () => void } = {};
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
    notificationSettings: async () => {
      settingsGate.started?.();
      await settingsGate.held;
      return { ...device };
    },
    requestNotifications: () => {
      device.authorization = 'authorized';
      return Promise.resolve({ ...device });
    },
    setNotificationPreviews: (previews) => {
      device.previews = previews;
      return Promise.resolve({ ...device });
    },
    openNotificationSettings: () => Promise.resolve(null),
    postNotifications: (posted, actions) => {
      notified.push(...posted);
      titles.push(actions);
      return Promise.resolve(null);
    },
    nextOpenedNotification: () => Promise.withResolvers<unknown>().promise,
    stopOpenedNotifications: () => Promise.resolve(null),
    restoreOpenedNotification: () => Promise.resolve(null),
    nextNotificationAction: () => {
      if (queued.length > 0) {
        return Promise.resolve(queued.shift());
      }
      const next = Promise.withResolvers<unknown>();
      reading = next.resolve;
      return next.promise;
    },
    completeNotificationAction: (id) => {
      completions.get(id)?.();
    },
  };
  const host = createHost(
    () => {
      counts.lookups += 1;
      return native;
    },
    { reportingNative: reporting === undefined ? undefined : () => reporting },
  );
  return {
    host,
    native,
    gmail,
    attachments: attachments.promise,
    cancelled,
    counts,
    notified,
    titles,
    notificationActions,
    settingsGate,
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

  it('posts New Mail Notifications only for a connection turned on, with generic content until previews are chosen', async () => {
    expect.hasAssertions();
    const { host, gmail, notified, titles } = syntheticHost(undefined, true);
    await host.registration.register('google');
    await host.registration.addMailbox();
    await host.gmailMailboxes.load();
    const connection = required(host.gmailMailboxes.getSnapshot()[0]).id;

    // Off by default.
    gmail.deliver({ subject: 'Before notifications' });
    await host.gmailMailboxes.load();
    await host.registration.notifyMailbox(connection, true);
    const account = host.registration.getSnapshot().snapshot;
    const scope = {
      account: 'account-synthetic-product-subject',
      epoch: required(required(mailboxesOf(account)[0]).epoch),
    };
    // Without permission nothing is posted.
    gmail.deliver({ subject: 'Before permission' });
    await host.gmailMailboxes.load();
    expect(notified).toStrictEqual([]);

    await host.notifications.request();
    const generic = gmail.deliver({ subject: 'Quarterly plan' });
    await host.gmailMailboxes.load();
    await host.notifications.setPreviews(true);
    const previewed = gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio review',
    });
    await host.gmailMailboxes.load();
    // Synchronization waits for posting after its commit.
    await vi.waitFor(() => {
      expect(notified).toHaveLength(2);
    });
    expect(notified).toStrictEqual([
      {
        id: `${connection}.${generic}`,
        title: '',
        body: 'New mail',
        connection,
        message: generic,
        ...scope,
        profile: defaultProfile,
        previews: false,
      },
      {
        id: `${connection}.${previewed}`,
        title: 'Maya Chen',
        body: 'Studio review',
        connection,
        message: previewed,
        ...scope,
        profile: defaultProfile,
        previews: true,
      },
    ]);
    // Every notification offers Reply, Archive and Mark as Read.
    expect(titles[0]).toStrictEqual({
      reply: 'Reply',
      archive: 'Archive',
      read: 'Mark as Read',
    });

    // Turned off again, the connection posts nothing.
    await host.registration.notifyMailbox(connection, false);
    gmail.deliver({ subject: 'After notifications' });
    await host.gmailMailboxes.load();
    expect(notified).toHaveLength(2);
  });

  it('archives or marks as read the message a notification names, only while its connection is the one it named', async () => {
    expect.hasAssertions();
    const { host, gmail, notificationActions } = syntheticHost(undefined, true);
    await host.registration.register('google');
    await host.registration.addMailbox();
    const archived = gmail.deliver({ subject: 'Archive me', unread: true });
    const read = gmail.deliver({ subject: 'Read me', unread: true });
    const kept = gmail.deliver({ subject: 'Keep me', unread: true });
    await host.gmailMailboxes.load();
    const mailbox = required(
      mailboxesOf(host.registration.getSnapshot().snapshot)[0],
    );
    const named = {
      account: 'account-synthetic-product-subject',
      connection: mailbox.id,
      epoch: required(mailbox.epoch),
    };
    host.followNotificationActions();

    await notificationActions.send({
      id: 'archive',
      ...named,
      message: archived,
      action: 'archive',
    });
    await notificationActions.send({
      id: 'read',
      ...named,
      message: read,
      action: 'read',
    });
    // A recreated connection or another Product Account acts on nothing, and still completes.
    await notificationActions.send({
      id: 'recreated',
      ...named,
      epoch: 'another incarnation',
      message: kept,
      action: 'archive',
    });
    await notificationActions.send({
      id: 'other account',
      ...named,
      account: 'another account',
      message: kept,
      action: 'read',
    });
    expect(gmail.labelsOf(archived)).not.toContain('INBOX');
    expect(gmail.labelsOf(read)).not.toContain('UNREAD');
    expect(gmail.labelsOf(kept)).toStrictEqual(
      expect.arrayContaining(['INBOX', 'UNREAD']),
    );
  });

  it('posts nothing for a connection turned off or removed while posting waited', async () => {
    expect.hasAssertions();
    const { host, gmail, notified, settingsGate } = syntheticHost(
      undefined,
      true,
    );
    await host.registration.register('google');
    await host.registration.addMailbox();
    await host.gmailMailboxes.load();
    const connection = required(host.gmailMailboxes.getSnapshot()[0]).id;
    await host.notifications.request();
    await host.registration.notifyMailbox(connection, true);
    const held = () => {
      const { promise, resolve } = Promise.withResolvers<undefined>();
      const started = Promise.withResolvers<undefined>();
      settingsGate.held = promise;
      settingsGate.started = () => started.resolve(undefined);
      return {
        started: started.promise,
        release: () => {
          settingsGate.held = undefined;
          settingsGate.started = undefined;
          resolve(undefined);
        },
      };
    };

    let gate = held();
    gmail.deliver({ subject: 'Turned off meanwhile' });
    let loading = host.gmailMailboxes.load();
    await gate.started;
    await host.registration.notifyMailbox(connection, false);
    gate.release();
    await loading;

    await host.registration.notifyMailbox(connection, true);
    gate = held();
    gmail.deliver({ subject: 'Removed meanwhile' });
    loading = host.gmailMailboxes.load();
    await gate.started;
    await host.registration.removeMailbox(connection);
    gate.release();
    await loading;
    expect(notified).toStrictEqual([]);
  });

  it('keeps a background freshness opportunity alive until notification posting settles', async () => {
    expect.hasAssertions();
    const { host, gmail, notified, settingsGate } = syntheticHost(
      undefined,
      true,
    );
    await host.registration.register('google');
    await host.registration.addMailbox();
    await host.gmailMailboxes.load();
    const connection = required(host.gmailMailboxes.getSnapshot()[0]).id;
    await host.notifications.request();
    await host.registration.notifyMailbox(connection, true);
    const held = Promise.withResolvers<undefined>();
    const started = Promise.withResolvers<undefined>();
    settingsGate.held = held.promise;
    settingsGate.started = () => started.resolve(undefined);
    gmail.deliver({ subject: 'Background arrival' });
    let completed = false;
    const refreshing = (async () => {
      await host.freshness.refresh();
      completed = true;
    })();
    await started.promise;
    // A registration round can complete independently while notification settings still wait.
    await host.registration.restore();
    expect(completed).toBe(false);
    held.resolve(undefined);
    await refreshing;
    expect(notified).toHaveLength(1);
    expect(completed).toBe(true);
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

  it('preserves reporting through refused sign-out preflight and withdraws at recorded removal', async () => {
    expect.hasAssertions();
    const reporting = reportingFixture();
    const { host, native } = syntheticHost(reporting.native);
    const removalConsent: boolean[] = [];
    const { recordRemoval } = native;
    vi.spyOn(native, 'recordRemoval').mockImplementation(async (operation) => {
      removalConsent.push(reporting.state().enabled);
      return recordRemoval(operation);
    });
    const preflight = vi
      .spyOn(native, 'prepareSignOut')
      .mockResolvedValue(false);
    try {
      await host.registration.register('google');
      await host.registration.addMailbox();
      await host.errorReporting.load();
      await host.errorReporting.setEnabled(true);
      reporting.offline(true);
      host.errorReporting.capture(new TypeError('Invalid time value'));
      await host.errorReporting.refresh();
      const queued = reporting.state().document;
      expect(queued).toContain('"id"');
      await host.registration.signOut();
      expect(preflight).toHaveBeenCalledWith();
      expect(removalConsent).toStrictEqual([]);
      expect(reporting.state()).toMatchObject({
        enabled: true,
        document: queued,
      });
      expect(host.registration.getSnapshot().snapshot.kind).toBe('connected');
      preflight.mockResolvedValue(true);
      await host.registration.signOut();
      // oxlint-disable-next-line vitest/max-expects -- The same journey checks preservation before admission and withdrawal before native removal.
      expect({
        removalConsent,
        enabled: reporting.state().enabled,
        document: reporting.state().document,
        registration: host.registration.getSnapshot().snapshot.kind,
      }).toMatchObject({
        removalConsent: [false],
        enabled: false,
        document: expect.not.stringContaining('"id"'),
        registration: 'signed-out',
      });
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
