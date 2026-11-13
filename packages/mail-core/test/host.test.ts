import type { NativeErrorReporting } from '@private-email/mail-core/error-reporting';

import { allMail } from '@private-email/mail-core/gmail-actions';
import { unifiedFolders } from '@private-email/mail-core/mailboxes';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';

import type { NativeHostModule } from '../src/host.ts';

import { createDrafts } from '../src/drafts.ts';
import { createHost } from '../src/host.ts';
import { undoSendWindow } from '../src/outbox.ts';
import {
  defaultProfile,
  mailboxesOf,
  profilesOf,
} from '../src/registration.ts';
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
  // Controlled IMAP servers by connection, added once a test connects one.
  const imapServers: Record<
    string,
    ReturnType<typeof createSyntheticImap>['native']
  > = {};
  const base = syntheticConnections(
    {
      [syntheticMailboxes['alex@example.invalid']]: gmail,
    },
    imapServers,
  );
  const drafts = createSyntheticDrafts(
    () => 'account-synthetic-product-subject',
    {
      server: createSyntheticProductSync(),
    },
  );
  const held = new Map<string, () => void>();
  const attachments = Promise.withResolvers<string>();
  const cancelled: string[] = [];
  const counts = { lookups: 0, registration: 0, settings: 0, wakes: 0 };
  // This device's notification permission and previews, and what it posted.
  const device = { authorization: 'undetermined', previews: false };
  const notified: unknown[] = [];
  const titles: unknown[] = [];
  // The notifications a typed reply posted, and those withdrawn.
  const replied: unknown[] = [];
  const withdrawn: string[] = [];
  // How often an earlier context's sending notifications were withdrawn.
  const sweeps = { count: 0 };
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
    requestUnsubscribe: () => Promise.resolve({ outcome: 'failed' }),
    openMailTemplates: () =>
      Promise.resolve({ owner: 'account', revision: 0, document: null }),
    commitMailTemplates: (owner, expectedRevision) =>
      Promise.resolve({ owner, revision: expectedRevision + 1 }),
    pullMailTemplates: (owner) =>
      Promise.resolve({ owner, records: [], unreadable: [] }),
    pushMailTemplate: (owner) => Promise.resolve({ owner, committed: false }),
    openSendReminders: () =>
      Promise.resolve({ owner: 'account', revision: 0, document: null }),
    commitSendReminders: (owner, expectedRevision) =>
      Promise.resolve({ owner, revision: expectedRevision + 1 }),

    openBlockedSenders: () =>
      Promise.resolve({ owner: 'account', revision: 0, document: null }),
    commitBlockedSenders: (owner, expectedRevision) =>
      Promise.resolve({ owner, revision: expectedRevision + 1 }),
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
    postReplyNotification: (posted, actions) => {
      replied.push({ ...posted, actions });
      return Promise.resolve(null);
    },
    withdrawNotification: (id) => {
      withdrawn.push(id);
      return Promise.resolve(null);
    },
    withdrawSendingReplies: () => {
      sweeps.count += 1;
      return Promise.resolve(null);
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
    shared,
    imapServers,
    attachments: attachments.promise,
    cancelled,
    counts,
    notified,
    titles,
    replied,
    withdrawn,
    sweeps,
    draftStorage: drafts,
    notificationActions,
    settingsGate,
  };
}

// A synthetic host following notification actions, with an answerable and a removable message in
// its Gmail Inbox, previews on, and the Drafts and Open Draft requests it holds.
async function replyingHost() {
  const synthetic = syntheticHost(undefined, true);
  const { host, gmail } = synthetic;
  await host.registration.register('google');
  await host.registration.addMailbox();
  const answered = gmail.deliver({
    subject: 'Studio review',
    headers: { 'Message-ID': '<review@example.invalid>' },
  });
  const gone = gmail.deliver({ subject: 'Gone' });
  await host.gmailMailboxes.load();
  await host.notifications.request();
  await host.notifications.setPreviews(true);
  const mailbox = required(
    mailboxesOf(host.registration.getSnapshot().snapshot)[0],
  );
  const opened: unknown[] = [];
  host.followNotificationActions((draft, profile) => {
    opened.push({ draft, profile });
  });
  const named = {
    account: 'account-synthetic-product-subject',
    connection: mailbox.id,
    epoch: required(mailbox.epoch),
  };
  const reply = (id: string, message: string, text: string) =>
    synthetic.notificationActions.send({
      id,
      ...named,
      message,
      action: 'reply',
      text,
    });
  const drafts = () => {
    const state = host.drafts.getSnapshot();
    return state.kind === 'ready' ? state.drafts : [];
  };
  return { ...synthetic, answered, gone, named, opened, reply, drafts };
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
        reply: 'Reply from alex@example.invalid',
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
        reply: 'Reply from alex@example.invalid',
      },
    ]);
    // Every notification offers Reply, Archive and Mark as Read.
    expect(titles[0]).toStrictEqual({
      reply: 'Reply',
      send: 'Send',
      archive: 'Archive',
      read: 'Mark as Read',
    });

    // Turned off again, the connection posts nothing.
    await host.registration.notifyMailbox(connection, false);
    gmail.deliver({ subject: 'After notifications' });
    await host.gmailMailboxes.load();
    expect(notified).toHaveLength(2);
  });

  it('logs why New Mail Notifications were or were not posted, never what or whose', async () => {
    expect.hasAssertions();
    const notes = vi.spyOn(console, 'log').mockReturnValue(undefined);
    const { host, gmail, notified } = syntheticHost(undefined, true);
    await host.registration.register('google');
    await host.registration.addMailbox();
    await host.gmailMailboxes.load();
    const connection = required(host.gmailMailboxes.getSnapshot()[0]).id;
    await host.registration.notifyMailbox(connection, true);
    gmail.deliver({ subject: 'Before permission' });
    await host.gmailMailboxes.load();
    await host.notifications.request();
    await host.notifications.setPreviews(true);
    const previewed = gmail.deliver({
      from: 'Maya Chen <maya@example.invalid>',
      subject: 'Studio review',
    });
    await host.gmailMailboxes.load();
    await vi.waitFor(() => {
      expect(notified).toHaveLength(1);
    });
    await host.registration.notifyMailbox(connection, false);
    gmail.deliver({ subject: 'After notifications' });
    await host.gmailMailboxes.load();

    const logged = notes.mock.calls.map((call) => call.join(' ')).join('\n');
    expect(
      [
        'not posted: authorization undetermined',
        'not posted: connection closed or its notifications off',
        'unread in the Inbox: 1',
        'handed to the host: 1',
      ].filter((note) => !logged.includes(note)),
    ).toStrictEqual([]);
    expect(logged).not.toMatch(
      new RegExp(
        `Maya|example\\.invalid|Studio|permission|${connection}|${previewed}`,
        'u',
      ),
    );
  });

  it('archives or marks as read the message a notification names after a cold launch, only while its connection is the one it named', async () => {
    expect.hasAssertions();
    const { host, native, gmail, notificationActions } = syntheticHost(
      undefined,
      true,
    );
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
    // A notification can launch a fresh host before Registration restores the saved account.
    const launched = createHost(() => native);
    expect(launched.registration.getSnapshot().snapshot.kind).toBe(
      'signed-out',
    );
    launched.followNotificationActions();

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

  it('sends a reply typed into a Mac notification from the receiving connection, with only the typed text', async () => {
    expect.hasAssertions();
    const { host, answered, named, reply, replied, sweeps } =
      await replyingHost();

    await reply('reply', answered, 'Thursday works.\nSee you then.');
    // Sending notifications an earlier launch left are withdrawn before any action.
    expect(sweeps.count).toBe(1);
    const [queued] = host.outbox.getSnapshot();
    expect(queued?.draft).toMatchObject({
      connection: named.connection,
      from: 'alex@example.invalid',
      to: [{ name: 'Maya Chen', address: 'maya@example.invalid' }],
      subject: 'Re: Studio review',
      response: { kind: 'reply', inReplyTo: '<review@example.invalid>' },
    });
    // No quote and no signature: a paragraph per typed line.
    expect({
      quoted: queued?.draft.quoted,
      body: queued?.draft.body,
    }).toStrictEqual({
      quoted: undefined,
      body: [
        { kind: 'paragraph', spans: [{ text: 'Thursday works.' }] },
        { kind: 'paragraph', spans: [{ text: 'See you then.' }] },
      ],
    });
    const draft = required(queued).id;
    expect(replied).toStrictEqual([
      {
        ...named,
        message: answered,
        id: `${named.connection}.reply.${draft}`,
        draft,
        profile: defaultProfile,
        previews: true,
        kind: 'sending',
        title: 'Reply to Maya Chen',
        body: 'Sending in 10 seconds from alex@example.invalid',
        actions: { undo: 'Undo', openDraft: 'Open Draft' },
      },
    ]);
  });

  it('returns a typed reply to Drafts on Undo, and otherwise withdraws its notification once the Undo Send Window ends', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    onTestFinished(() => {
      vi.useRealTimers();
    });
    const {
      host,
      answered,
      named,
      reply,
      drafts,
      withdrawn,
      notificationActions,
    } = await replyingHost();

    await reply('reply', answered, 'Thursday works.');
    const undone = required(host.outbox.getSnapshot()[0]).id;
    await notificationActions.send({
      id: 'undo',
      ...named,
      message: answered,
      action: 'undo',
      draft: undone,
    });
    expect({
      outbox: host.outbox.getSnapshot(),
      drafts: drafts().some(({ id }) => id === undone),
      withdrawn,
    }).toStrictEqual({
      outbox: [],
      drafts: true,
      withdrawn: [`${named.connection}.reply.${undone}`],
    });

    await reply('again', answered, 'Thursday still works.');
    const sending = required(host.outbox.getSnapshot()[0]).id;
    await vi.advanceTimersByTimeAsync(10_000);
    expect(withdrawn).toContain(`${named.connection}.reply.${sending}`);
  });

  it('undoes a typed reply while another reply still reads its message', async () => {
    expect.hasAssertions();
    const {
      host,
      gmail,
      answered,
      gone,
      named,
      reply,
      drafts,
      notificationActions,
    } = await replyingHost();
    await reply('first', answered, 'Thursday works.');
    const first = required(host.outbox.getSnapshot()[0]).id;
    // Gmail reads, as the second reply's, wait for `read`.
    const read = Promise.withResolvers<undefined>();
    const request = gmail.native.gmailRequest;
    gmail.native.gmailRequest = async (...args) => {
      await read.promise;
      return request(...args);
    };

    const second = reply('second', gone, 'Friday too.');
    await notificationActions.send({
      id: 'undo',
      ...named,
      message: answered,
      action: 'undo',
      draft: first,
    });
    expect({
      outbox: host.outbox.getSnapshot(),
      drafts: drafts().map(({ id }) => id),
    }).toStrictEqual({ outbox: [], drafts: [first] });
    read.resolve(undefined);
    await second;
  });

  it('keeps offering Undo on a typed reply whose return to Drafts could not be saved', async () => {
    expect.hasAssertions();
    const {
      host,
      answered,
      named,
      reply,
      replied,
      withdrawn,
      draftStorage,
      notificationActions,
    } = await replyingHost();

    await reply('reply', answered, 'Thursday works.');
    const draft = required(host.outbox.getSnapshot()[0]).id;
    draftStorage.failNextCommit('unavailable');
    await notificationActions.send({
      id: 'undo',
      ...named,
      message: answered,
      action: 'undo',
      draft,
    });
    expect({
      outbox: host.outbox.getSnapshot().map(({ id }) => id),
      withdrawn,
    }).toStrictEqual({ outbox: [draft], withdrawn: [] });
    expect(replied).toMatchObject([
      { draft, kind: 'sending' },
      { draft, kind: 'sending', title: 'Reply to Maya Chen' },
    ]);
  });

  it('withdraws a repeated Undo offer that lands after the Undo Send Window ended', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    onTestFinished(() => {
      vi.useRealTimers();
    });
    const {
      host,
      native,
      answered,
      named,
      reply,
      withdrawn,
      draftStorage,
      notificationActions,
    } = await replyingHost();

    await reply('reply', answered, 'Thursday works.');
    const draft = required(host.outbox.getSnapshot()[0]).id;
    draftStorage.failNextCommit('unavailable');
    // The Undo offer posted again waits until the window has ended.
    const post = native.postReplyNotification;
    const posting = Promise.withResolvers<undefined>();
    const held = Promise.withResolvers<undefined>();
    vi.spyOn(native, 'postReplyNotification').mockImplementationOnce(
      async (...args) => {
        posting.resolve(undefined);
        await held.promise;
        return post(...args);
      },
    );
    const undoing = notificationActions.send({
      id: 'undo',
      ...named,
      message: answered,
      action: 'undo',
      draft,
    });
    await posting.promise;
    await vi.advanceTimersByTimeAsync(10_000);
    held.resolve(undefined);
    await undoing;
    expect(withdrawn).toStrictEqual([
      `${named.connection}.reply.${draft}`,
      `${named.connection}.reply.${draft}`,
    ]);
  });

  it('leaves a typed reply whose delivery became uncertain to the Outbox on Undo', async () => {
    expect.hasAssertions();
    vi.useFakeTimers({ toFake: ['Date'] });
    onTestFinished(() => {
      vi.useRealTimers();
    });
    const {
      host,
      gmail,
      answered,
      named,
      reply,
      drafts,
      withdrawn,
      notificationActions,
    } = await replyingHost();

    await reply('reply', answered, 'Thursday works.');
    const draft = required(host.outbox.getSnapshot()[0]).id;
    vi.setSystemTime(Date.now() + undoSendWindow);
    // Gmail takes the reply but its answer is lost, and the opportunity ends before a Sent check.
    gmail.failSend({ lost: true });
    const submit = gmail.native.gmailSend;
    gmail.native.gmailSend = async (...args) => {
      try {
        return await submit(...args);
      } finally {
        host.outbox.pause();
      }
    };
    await host.outbox.resume();
    await notificationActions.send({
      id: 'undo',
      ...named,
      message: answered,
      action: 'undo',
      draft,
    });
    expect({
      outbox: host.outbox.getSnapshot().map(({ id, state }) => ({ id, state })),
      drafts: drafts().map(({ id }) => id),
      withdrawn,
    }).toStrictEqual({
      outbox: [{ id: draft, state: 'unknown' }],
      drafts: [],
      withdrawn: [`${named.connection}.reply.${draft}`],
    });
  });

  it('says a typed reply that storage refused is not saved, and sends nothing', async () => {
    expect.hasAssertions();
    const { host, answered, reply, replied, draftStorage } =
      await replyingHost();
    // Refuses the save of the typed text, after its empty Draft was stored.
    const { fill } = host.drafts;
    host.drafts.fill = async (...args) => {
      draftStorage.failNextCommit('unavailable');
      return fill(...args);
    };

    await reply('reply', answered, 'Thursday works.');
    expect({ outbox: host.outbox.getSnapshot(), replied }).toMatchObject({
      outbox: [],
      replied: [
        {
          kind: 'saved',
          title: 'Couldn’t reply',
          body: 'Your text couldn’t be saved. Open the Draft to try again.',
        },
      ],
    });
  });

  it('sends the typed reply as prepared when its Draft changes while notification settings are read', async () => {
    expect.hasAssertions();
    const { host, answered, reply, drafts, settingsGate } =
      await replyingHost();
    const settings = Promise.withResolvers<undefined>();
    const reading = Promise.withResolvers<undefined>();
    settingsGate.held = settings.promise;
    settingsGate.started = () => {
      reading.resolve(undefined);
    };

    const replying = reply('reply', answered, 'Thursday works.');
    await reading.promise;
    // Another editor changes any Draft still listed meanwhile.
    await Promise.all(
      drafts().map(({ id }) =>
        host.drafts.fill(id, (each) => ({ ...each, subject: 'Edited' }), []),
      ),
    );
    settingsGate.held = undefined;
    settingsGate.started = undefined;
    settings.resolve(undefined);
    await replying;
    expect(
      host.outbox.getSnapshot().map(({ draft }) => draft.subject),
    ).toStrictEqual(['Re: Studio review']);
  });

  it('says a typed reply was not kept when its Draft cannot be created', async () => {
    expect.hasAssertions();
    const { host, answered, named, reply, replied } = await replyingHost();
    host.drafts.create = async () => undefined;

    await reply('reply', answered, 'Thursday works.');
    expect({ outbox: host.outbox.getSnapshot(), replied }).toMatchObject({
      outbox: [],
      replied: [
        {
          id: `${named.connection}.reply.${answered}`,
          draft: '',
          kind: 'failed',
          title: 'Couldn’t reply',
          body: 'Your text couldn’t be saved. Open the message to reply again.',
        },
      ],
    });
  });

  it('keeps another editor’s change to the new Draft and sends nothing', async () => {
    expect.hasAssertions();
    const { host, answered, reply, drafts, replied } = await replyingHost();
    // Another editor completes the Draft while its creation saves.
    const { create } = host.drafts;
    host.drafts.create = async (...args) => {
      const id = required(await create(...args));
      await host.drafts.fill(id, (each) => ({ ...each, subject: 'Mine' }), []);
      return id;
    };

    await reply('reply', answered, 'Thursday works.');
    expect({
      outbox: host.outbox.getSnapshot(),
      drafts: drafts().map(({ subject, body }) => ({ subject, body })),
      replied,
    }).toMatchObject({
      outbox: [],
      drafts: [{ subject: 'Mine', body: [{ kind: 'paragraph', spans: [] }] }],
      replied: [
        {
          kind: 'saved',
          body: 'Your text couldn’t be saved. Open the Draft to try again.',
        },
      ],
    });
  });

  it('keeps another editor’s change made while the typed reply saves, and sends nothing', async () => {
    expect.hasAssertions();
    const { host, native, answered, reply, drafts } = await replyingHost();
    // The reply's save waits once the Draft exists, while another editor changes it.
    const commit = native.commitDrafts;
    const saving = Promise.withResolvers<undefined>();
    const held = Promise.withResolvers<undefined>();
    const { create } = host.drafts;
    host.drafts.create = async (...args) => {
      const id = await create(...args);
      vi.spyOn(native, 'commitDrafts').mockImplementationOnce(
        async (...saved) => {
          saving.resolve(undefined);
          await held.promise;
          return commit(...saved);
        },
      );
      return id;
    };

    const replying = reply('reply', answered, 'Thursday works.');
    await saving.promise;
    const editing = host.drafts.fill(
      required(drafts()[0]).id,
      (each) => ({ ...each, subject: 'Mine' }),
      [],
    );
    held.resolve(undefined);
    await Promise.all([replying, editing]);
    expect({
      outbox: host.outbox.getSnapshot(),
      subjects: drafts().map(({ subject }) => subject),
    }).toStrictEqual({ outbox: [], subjects: ['Mine'] });
  });

  it('keeps a reply to a message no longer listed in Drafts, and opens it from Couldn’t reply', async () => {
    expect.hasAssertions();
    const {
      host,
      gmail,
      gone,
      named,
      reply,
      drafts,
      replied,
      opened,
      notificationActions,
    } = await replyingHost();
    gmail.remove(gone);
    await host.gmailMailboxes.load();

    await reply('gone', gone, 'Is this still on?');
    const saved = required(drafts()[0]);
    expect({
      body: saved.body,
      outbox: host.outbox.getSnapshot(),
    }).toStrictEqual({
      body: [{ kind: 'paragraph', spans: [{ text: 'Is this still on?' }] }],
      outbox: [],
    });
    expect(replied).toMatchObject([
      {
        draft: saved.id,
        kind: 'saved',
        title: 'Couldn’t reply',
        body: 'That message was deleted on another device. Your text is saved in Drafts.',
      },
    ]);
    await notificationActions.send({
      id: 'open',
      ...named,
      message: gone,
      action: 'open-draft',
      draft: saved.id,
    });
    expect(opened).toStrictEqual([
      { draft: saved.id, profile: defaultProfile },
    ]);
  });

  it('opens a typed reply’s Draft chosen on a notification before the Drafts opened', async () => {
    expect.hasAssertions();
    const { host, gone, named, opened, draftStorage, notificationActions } =
      await replyingHost();
    // Stored by an earlier launch; this one has not opened its Drafts yet.
    const earlier = createDrafts(draftStorage.native, host.registration);
    await earlier.load();
    const draft = required(
      await earlier.create({
        id: named.connection,
        address: 'alex@example.invalid',
      }),
    );
    await earlier.fill(draft, (each) => ({ ...each, subject: 'Later' }), []);

    await notificationActions.send({
      id: 'open',
      ...named,
      message: gone,
      action: 'open-draft',
      draft,
    });
    expect(opened).toStrictEqual([{ draft, profile: defaultProfile }]);
  });

  it('archives nothing when the connection is recreated while a notification action opens the Drafts', async () => {
    expect.hasAssertions();
    const { host, gmail, answered, named, notificationActions } =
      await replyingHost();
    const { load } = host.drafts;
    host.drafts.load = async () => {
      host.drafts.load = load;
      await host.registration.removeMailbox(named.connection);
      await host.registration.addMailbox();
      await host.gmailMailboxes.load();
      return load();
    };

    await notificationActions.send({
      id: 'archive',
      ...named,
      message: answered,
      action: 'archive',
    });
    expect(gmail.labelsOf(answered)).toContain('INBOX');
  });

  it('sends and saves nothing from a notification of a recreated connection or another account', async () => {
    expect.hasAssertions();
    const { host, answered, named, drafts, replied, notificationActions } =
      await replyingHost();
    await host.drafts.load();
    expect(host.drafts.getSnapshot().kind).toBe('ready');

    await notificationActions.send({
      id: 'recreated',
      ...named,
      epoch: 'another incarnation',
      message: answered,
      action: 'reply',
      text: 'Not this one.',
    });
    await notificationActions.send({
      id: 'other account',
      ...named,
      account: 'another account',
      message: answered,
      action: 'reply',
      text: 'Not this one either.',
    });
    expect({ replied, drafts: drafts() }).toStrictEqual({
      replied: [],
      drafts: [],
    });
  });

  it('applies Spam and Trash folders chosen through Product Sync to the open IMAP Inbox, and reports a refused choice on its row', async () => {
    expect.hasAssertions();
    const { host, shared, imapServers } = syntheticHost(undefined, true);
    const imap = createSyntheticImap();
    imap.addFolder('Spam');
    imap.addFolder('Bin');
    await host.registration.register('google');
    await host.registration.connectImap({
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      port: 993,
      username: 'alex',
      password: shared.imap.password,
      smtp: {
        host: 'smtp.example.invalid',
        port: 465,
        security: 'tls',
        username: 'alex',
      },
    });
    const mailbox = required(
      mailboxesOf(host.registration.getSnapshot().snapshot)[0],
    );
    imapServers[mailbox.id] = imap.native;
    await host.gmailMailboxes.load();
    const allMailFolders = () => {
      const connection = required(host.gmailMailboxes.getConnections()[0]);
      return unifiedFolders(
        { ...connection, state: connection.inbox.getSnapshot() },
        allMail,
      );
    };
    expect(allMailFolders()).toBeUndefined();

    await host.registration.chooseFolders(mailbox.id, {
      junk: 'Spam',
      trash: 'Bin',
    });
    expect(
      mailboxesOf(host.registration.getSnapshot().snapshot)[0]?.folders,
    ).toStrictEqual({ junk: 'Spam', trash: 'Bin' });
    expect({
      folders: allMailFolders(),
      failure: host.registration.getSnapshot().foldersFailure,
    }).toStrictEqual({ folders: ['INBOX'], failure: undefined });

    // One folder cannot be both, so the choice is refused and the previous one stays.
    await host.registration.chooseFolders(mailbox.id, {
      junk: 'Bin',
      trash: 'Bin',
    });
    expect({
      folders: allMailFolders(),
      failure: host.registration.getSnapshot().foldersFailure,
    }).toStrictEqual({ folders: ['INBOX'], failure: mailbox.id });
  });

  it('posts New Mail Notifications for an IMAP connection turned on, and archives or marks as read from them', async () => {
    expect.hasAssertions();
    const at = (hour: number) => Date.UTC(2026, 9, 1, hour);
    vi.useFakeTimers({ now: at(9), toFake: ['Date'] });
    onTestFinished(() => {
      vi.useRealTimers();
    });
    const { host, shared, imapServers, notified, notificationActions } =
      syntheticHost(undefined, true);
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    await host.registration.register('google');
    await host.registration.connectImap({
      address: 'alex@example.invalid',
      host: 'imap.example.invalid',
      port: 993,
      username: 'alex',
      password: shared.imap.password,
      smtp: {
        host: 'smtp.example.invalid',
        port: 465,
        security: 'tls',
        username: 'alex',
      },
    });
    const mailbox = required(
      mailboxesOf(host.registration.getSnapshot().snapshot)[0],
    );
    imapServers[mailbox.id] = imap.native;
    await host.gmailMailboxes.load();
    await host.notifications.request();
    await host.registration.notifyMailbox(mailbox.id, true);
    host.followNotificationActions();

    vi.setSystemTime(at(11));
    const archived = imap.deliver('INBOX', {
      subject: 'Archive me',
      received: at(9),
    });
    const read = imap.deliver('INBOX', {
      subject: 'Read me',
      received: at(10),
    });
    await host.gmailMailboxes.load();
    const id = (uid: number) => `7.${uid}.INBOX`;
    expect(notified).toStrictEqual([
      expect.objectContaining({
        body: 'New mail',
        connection: mailbox.id,
        epoch: mailbox.epoch,
        message: id(read),
      }),
      expect.objectContaining({ message: id(archived) }),
    ]);

    const named = {
      account: 'account-synthetic-product-subject',
      connection: mailbox.id,
      epoch: required(mailbox.epoch),
    };
    await notificationActions.send({
      id: 'archive',
      ...named,
      message: id(archived),
      action: 'archive',
    });
    await notificationActions.send({
      id: 'read',
      ...named,
      message: id(read),
      action: 'read',
    });
    expect(imap.server.changes).toStrictEqual([
      `move INBOX ${archived} Archive`,
      `read INBOX ${read}`,
    ]);
  });

  it('posts nothing for a connection turned off or removed while posting waited, and groups a moved one under its new Profile', async () => {
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

    // Moved to another Profile meanwhile, it groups with that Profile's notifications.
    await host.registration.notifyMailbox(connection, true);
    await host.notifications.setPreviews(true);
    await host.registration.createProfile('Work');
    const work = required(
      profilesOf(host.registration.getSnapshot().snapshot).find(
        ({ name }) => name === 'Work',
      ),
    ).id;
    gate = held();
    gmail.deliver({ subject: 'Moved meanwhile' });
    loading = host.gmailMailboxes.load();
    await gate.started;
    await host.registration.moveMailbox(connection, work);
    gate.release();
    await loading;
    expect(notified).toStrictEqual([
      expect.objectContaining({ body: 'Moved meanwhile', profile: work }),
    ]);

    gate = held();
    gmail.deliver({ subject: 'Removed meanwhile' });
    loading = host.gmailMailboxes.load();
    await gate.started;
    await host.registration.removeMailbox(connection);
    gate.release();
    await loading;
    expect(notified).toHaveLength(1);
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
