import { setTimeout as sleep } from 'node:timers/promises';

import { english as t } from '@private-email/localization';

import type {
  ImapInboxState,
  ImapMessage,
  ImapSearchPage,
  NativeImapMailbox,
  ImapFolderView,
} from '../src/imap-inbox.ts';

import {
  imapMoveTargets,
  imapQuickActions,
  searchedFolders,
} from '../src/imap-actions.ts';
import { createImapInbox } from '../src/imap-inbox.ts';
import { createMailboxes, searchGmail } from '../src/mailboxes.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const ready = (state: ImapInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready IMAP Inbox, received ${state.kind}`);
  }
  return state;
};

const foundMessages = (page: ImapSearchPage) => {
  if (page.kind !== 'found') {
    throw new Error(`Expected search results, received ${page.reason}`);
  }
  return page.messages;
};

const first = <T>(items: readonly T[]) => {
  const [item] = items;
  if (item === undefined) {
    throw new Error('Expected an item');
  }
  return item;
};

const blockedId = (state: ImapInboxState) => {
  const { blocked } = ready(state);
  if (blocked === undefined) {
    throw new Error('Expected a blocked move');
  }
  return blocked;
};
const folderMessages = (view: ImapFolderView) => {
  if (view.kind !== 'ready') {
    throw new Error('Expected a ready folder');
  }
  return view.messages;
};
const interruption = () =>
  Object.assign(new Error('Synthetic interruption'), {
    code: 'imap-interrupted',
  });
const heldCommit = (native: NativeImapMailbox) => {
  const entered = Promise.withResolvers<undefined>();
  const release = Promise.withResolvers<undefined>();
  let remaining = 0;
  return {
    entered,
    release,
    hold: (count: number) => {
      remaining = count;
    },
    commitMailbox: async (
      ...args: Parameters<NativeImapMailbox['commitMailbox']>
    ) => {
      if (remaining > 0) {
        remaining -= 1;
        if (remaining === 0) {
          entered.resolve(undefined);
          await release.promise;
        }
      }
      return native.commitMailbox(...args);
    },
  };
};
const lossyCommit = (native: NativeImapMailbox) => {
  let loseReply = false;
  return {
    lose: (value: boolean) => {
      loseReply = value;
    },
    commitMailbox: async (
      ...args: Parameters<NativeImapMailbox['commitMailbox']>
    ) => {
      const result = await native.commitMailbox(...args);
      if (loseReply) {
        loseReply = false;
        throw Object.assign(new Error('Synthetic lost save reply'), {
          code: 'unavailable',
        });
      }
      return result;
    },
  };
};
const interruptDeletion = (native: NativeImapMailbox) => {
  let interrupted = false;
  return async (
    scope: Parameters<NativeImapMailbox['imapModify']>[0],
    change: Parameters<NativeImapMailbox['imapModify']>[1],
  ) => {
    if (change.copied !== undefined && !interrupted) {
      interrupted = true;
      throw interruption();
    }
    return native.imapModify(scope, change);
  };
};
const interruptIdle = (native: NativeImapMailbox) => {
  let interrupted = false;
  return async (
    scope: Parameters<NativeImapMailbox['imapIdle']>[0],
    request: Parameters<NativeImapMailbox['imapIdle']>[1],
  ) => {
    if (!interrupted) {
      interrupted = true;
      throw Object.assign(new Error('Synthetic outage'), { code: 'offline' });
    }
    return native.imapIdle(scope, request);
  };
};

// The only connection's IMAP Inbox store.
const imapInbox = (mailboxes: Readonly<ReturnType<typeof createMailboxes>>) => {
  const { inbox } = first(mailboxes.getConnections());
  if (!('watch' in inbox)) {
    throw new Error('Expected an IMAP connection');
  }
  return inbox;
};

const subjects = (state: ImapInboxState) =>
  ready(state).messages.map(({ subject }) => subject);

const inboxMessage = (state: ImapInboxState, subject: string) => {
  const message = ready(state).messages.find(
    (item) => item.subject === subject,
  );
  if (message === undefined) {
    throw new Error(`Expected ${subject} in the Inbox`);
  }
  return message;
};

// A connection with Archive, Trash and Junk declared by role, and a folder of the person's own.
const organizedServer = () => {
  const imap = createSyntheticImap();
  imap.addFolder('Archive', ['archive']);
  imap.addFolder('Deleted Messages', ['trash']);
  imap.addFolder('Junk', ['junk']);
  imap.addFolder('Projects');
  return imap;
};

const action = (state: ImapInboxState, message: ImapMessage, name: string) => {
  const found = imapQuickActions(t, message, ready(state)).find(
    (item) => item.name === name,
  );
  if (found === undefined) {
    throw new Error(`Expected the ${name} action`);
  }
  return found.action;
};

describe('organizing IMAP mail', () => {
  it('maps archive, Trash and Spam to declared folder roles and offers moves only when the server can move', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const state = ready(inbox.getSnapshot());
    const message = inboxMessage(state, 'Hello');
    expect(
      imapQuickActions(t, message, state).map(({ action: change }) => change),
    ).toStrictEqual([
      { kind: 'read' },
      { kind: 'archive', destination: 'Archive' },
      { kind: 'trash', destination: 'Deleted Messages' },
      { kind: 'spam', destination: 'Junk' },
    ]);
    expect(
      imapMoveTargets(message, state).map(({ name }) => name),
    ).toStrictEqual(['Archive', 'Deleted Messages', 'Junk', 'Projects']);

    // A server without MOVE and UIDPLUS, or without declared roles, offers only read state.
    imap.server.capabilities = { moves: false, idle: false };
    await inbox.load();
    const limited = ready(inbox.getSnapshot());
    expect(
      imapQuickActions(t, message, limited).map(({ name }) => name),
    ).toStrictEqual(['read']);
    expect(imapMoveTargets(message, limited)).toStrictEqual([]);
    expect(
      imapQuickActions(t, message, {
        folders: [],
        capabilities: { moves: true, idle: true },
      }).map(({ name }) => name),
    ).toStrictEqual(['read']);
  });

  it('shows read state at once, applies it at the server and keeps it after the next synchronization', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    const uid = imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const message = inboxMessage(inbox.getSnapshot(), 'Hello');
    const read = inbox.organize(message, { kind: 'read' });
    expect(inbox.message(message.id)?.unread).toBe(false);
    await read;
    expect(imap.server.changes).toStrictEqual([`read INBOX ${uid}`]);
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
    await inbox.load();
    expect(inboxMessage(inbox.getSnapshot(), 'Hello').unread).toBe(false);
    expect(ready(inbox.getSnapshot()).notice).toStrictEqual({
      kind: 'done',
      action: { kind: 'read' },
      message: { subject: 'Hello' },
    });
  });

  it('archives at once and Undo moves the message back to the Inbox from where the server put it', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves each step of the change's life. */
    expect.hasAssertions();
    const imap = organizedServer();
    const uid = imap.deliver('INBOX', { subject: 'Hello' });
    imap.deliver('INBOX', { subject: 'Stays' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const state = inbox.getSnapshot();
    const message = inboxMessage(state, 'Hello');
    const archived = inbox.organize(message, action(state, message, 'archive'));
    expect(subjects(inbox.getSnapshot())).toStrictEqual(['Stays']);
    await archived;
    expect(imap.server.changes).toStrictEqual([`move INBOX ${uid} Archive`]);
    expect(ready(inbox.getSnapshot()).undo).toBe(true);
    await inbox.undo();
    expect(imap.server.changes).toStrictEqual([
      `move INBOX ${uid} Archive`,
      'move Archive 1 INBOX',
    ]);
    // The Inbox reads the returned message as the server numbered it.
    expect(subjects(inbox.getSnapshot()).toSorted()).toStrictEqual([
      'Hello',
      'Stays',
    ]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      notice: { kind: 'done', action: { kind: 'restore' } },
      undo: false,
    });
  });
  /* oxlint-enable vitest/max-expects */

  it('saves a change made offline across relaunch, withdraws it on Undo before it is sent, and sends the rest once', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves each step of the change's life. */
    expect.hasAssertions();
    const imap = organizedServer();
    const uid = imap.deliver('INBOX', { subject: 'Hello' });
    const other = imap.deliver('INBOX', { subject: 'Other' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.server.failure = 'offline';
    const state = inbox.getSnapshot();
    const hello = inboxMessage(state, 'Hello');
    await inbox.organize(hello, action(state, hello, 'trash'));
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      undo: true,
      status: 'retry',
    });
    await inbox.undo();
    expect(subjects(inbox.getSnapshot()).toSorted()).toStrictEqual([
      'Hello',
      'Other',
    ]);
    const otherMessage = inboxMessage(inbox.getSnapshot(), 'Other');
    await inbox.organize(otherMessage, {
      kind: 'move',
      destination: 'Projects',
    });
    inbox.forget();

    // A relaunch reads the saved change from the encrypted cache and sends it once reachable.
    const relaunched = createImapInbox(imap.native);
    await relaunched.load();
    expect(subjects(relaunched.getSnapshot())).toStrictEqual(['Hello']);
    expect(ready(relaunched.getSnapshot()).pending).toBe(1);
    imap.server.failure = undefined;
    await relaunched.load();
    expect(imap.server.changes).toStrictEqual([`move INBOX ${other} Projects`]);
    expect(ready(relaunched.getSnapshot()).pending).toBe(0);
    await relaunched.load();
    expect(imap.server.changes).toHaveLength(1);
    expect(subjects(relaunched.getSnapshot())).toStrictEqual(['Hello']);
    expect(imap.server.changes).not.toContain(
      `move INBOX ${uid} Deleted Messages`,
    );
  });
  /* oxlint-enable vitest/max-expects */

  it.each(['received', 'lost'])(
    'withdraws Undo durably during a pending-action save whose reply is %s',
    async (reply) => {
      expect.hasAssertions();
      const imap = organizedServer();
      imap.deliver('INBOX', { subject: 'Hello' });
      const replies = lossyCommit(imap.native);
      const held = heldCommit({
        ...imap.native,
        commitMailbox: replies.commitMailbox,
      });
      const inbox = createImapInbox({
        ...imap.native,
        commitMailbox: held.commitMailbox,
      });
      await inbox.load();
      replies.lose(reply === 'lost');
      held.hold(1);
      const organizing = inbox.organize(
        inboxMessage(inbox.getSnapshot(), 'Hello'),
        {
          kind: 'archive',
          destination: 'Archive',
        },
      );
      try {
        await held.entered.promise;
        const undoing = inbox.undo();
        expect(subjects(inbox.getSnapshot())).toStrictEqual(['Hello']);
        held.release.resolve(undefined);
        await Promise.all([organizing, undoing]);
        inbox.forget();
        const reopened = createImapInbox(imap.native);
        await reopened.load();
        expect(subjects(reopened.getSnapshot())).toStrictEqual(['Hello']);
        expect(ready(reopened.getSnapshot()).pending).toBe(0);
        expect(imap.server.changes).toStrictEqual([]);
      } finally {
        held.release.resolve(undefined);
        await organizing;
        inbox.forget();
      }
    },
  );

  it('ends withdrawal eligibility before move dispatch persistence begins', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('INBOX', { subject: 'Hello' });
    const held = heldCommit(imap.native);
    const inbox = createImapInbox({
      ...imap.native,
      commitMailbox: held.commitMailbox,
    });
    await inbox.load();
    held.hold(2);
    const organizing = inbox.organize(
      inboxMessage(inbox.getSnapshot(), 'Hello'),
      {
        kind: 'archive',
        destination: 'Archive',
      },
    );
    try {
      await held.entered.promise;
      expect(ready(inbox.getSnapshot()).undo).toBe(false);
      await inbox.undo();
      held.release.resolve(undefined);
      await organizing;
      expect(ready(inbox.getSnapshot()).undo).toBe(true);
      await inbox.undo();
      expect(subjects(inbox.getSnapshot())).toStrictEqual(['Hello']);
    } finally {
      held.release.resolve(undefined);
      await organizing;
      inbox.forget();
    }
  });

  it('blocks a lost move reply across relaunch until it is explicitly discarded, without replaying', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    const uid = imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const state = inbox.getSnapshot();
    const message = inboxMessage(state, 'Hello');
    imap.server.loseReply = true;
    await inbox.organize(message, action(state, message, 'archive'));
    expect(ready(inbox.getSnapshot()).pending).toBe(1);
    await inbox.load();
    expect(imap.server.changes).toStrictEqual([`move INBOX ${uid} Archive`]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      notice: { kind: 'blocked', action: { kind: 'archive' } },
    });
    const blocked = blockedId(inbox.getSnapshot());
    inbox.forget();
    const reopened = createImapInbox(imap.native);
    await reopened.load();
    await reopened.discardPending(blocked);
    expect(ready(reopened.getSnapshot()).pending).toBe(0);
    expect(imap.server.changes).toHaveLength(1);
  });

  it('settles read state and removal in an opened non-Inbox folder', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('Archive', { subject: 'Filed' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await inbox.openFolder('Archive');
    const message = first(folderMessages(inbox.folder('Archive')));
    await inbox.organize(message, { kind: 'read' });
    expect(inbox.folder('Archive')).toMatchObject({
      messages: [{ unread: false }],
    });
    await inbox.organize(message, { kind: 'move', destination: 'Projects' });
    expect(inbox.folder('Archive')).toMatchObject({ messages: [] });
    expect(ready(inbox.getSnapshot()).pending).toBe(0);
  });

  it('withholds ambiguous roles and refuses queued actions whose role mapping changed', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const message = inboxMessage(inbox.getSnapshot(), 'Hello');
    const state = ready(inbox.getSnapshot());
    expect(
      imapQuickActions(t, message, {
        ...state,
        folders: [
          ...state.folders,
          { name: 'Other Archive', selectable: true, roles: ['archive'] },
        ],
      }).map(({ name }) => name),
    ).not.toContain('archive');
    imap.server.failure = 'offline';
    await inbox.organize(message, { kind: 'archive', destination: 'Archive' });
    imap.removeFolder('Archive');
    imap.addFolder('Archive', ['trash']);
    imap.addFolder('New Archive', ['archive']);
    imap.server.failure = undefined;
    await inbox.load();
    expect(imap.server.changes).toStrictEqual([]);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 0,
      notice: { kind: 'rejected' },
    });
  });

  it('reuses a durable COPYUID after an interrupted source deletion instead of copying again', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.server.copyOnly = true;
    imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox({
      ...imap.native,
      imapModify: interruptDeletion(imap.native),
    });
    await inbox.load();
    const message = inboxMessage(inbox.getSnapshot(), 'Hello');
    await inbox.organize(message, { kind: 'archive', destination: 'Archive' });
    expect(ready(inbox.getSnapshot()).pending).toBe(1);
    inbox.forget();
    const reopened = createImapInbox(imap.native);
    await reopened.load();
    await reopened.openFolder('Archive');
    expect(imap.server.changes).toStrictEqual([
      'copy INBOX 1 Archive',
      'delete INBOX 1',
    ]);
    expect(reopened.folder('Archive')).toMatchObject({
      messages: [{ subject: 'Hello' }],
    });
    expect(ready(reopened.getSnapshot()).pending).toBe(0);
  });

  it('never treats an external deletion after an interrupted move as proof of its destination', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    const uid = imap.deliver('INBOX', { subject: 'Hello' });
    const inbox = createImapInbox({
      ...imap.native,
      imapModify: () => Promise.reject(interruption()),
    });
    await inbox.load();
    await inbox.organize(inboxMessage(inbox.getSnapshot(), 'Hello'), {
      kind: 'archive',
      destination: 'Archive',
    });
    imap.expunge('INBOX', uid);
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      pending: 1,
      notice: { kind: 'blocked' },
    });
    expect(imap.server.changes).toStrictEqual([]);
  });

  it.each([
    {
      change: 'another client removed the message',
      external: (imap: ReturnType<typeof organizedServer>, uid: number) => {
        imap.expunge('INBOX', uid);
      },
    },
    {
      change: 'the folder was recreated with a new UIDVALIDITY',
      external: (imap: ReturnType<typeof organizedServer>) => {
        imap.renumber('INBOX');
      },
    },
    {
      change: 'the destination folder was removed',
      external: (imap: ReturnType<typeof organizedServer>) => {
        imap.removeFolder('Archive');
      },
    },
  ])(
    'refuses a change when $change before it was sent, and shows the message as the server has it',
    async ({ external }) => {
      expect.hasAssertions();
      const imap = organizedServer();
      const uid = imap.deliver('INBOX', { subject: 'Hello' });
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      const state = inbox.getSnapshot();
      const message = inboxMessage(state, 'Hello');
      imap.server.failure = 'offline';
      await inbox.organize(message, action(state, message, 'archive'));
      external(imap, uid);
      imap.server.failure = undefined;
      await inbox.load();
      expect(imap.server.changes).toStrictEqual([]);
      expect(ready(inbox.getSnapshot())).toMatchObject({
        pending: 0,
        notice: { kind: 'rejected', action: { kind: 'archive' } },
        undo: false,
      });
      await inbox.load();
      expect(imap.server.changes).toStrictEqual([]);
    },
  );
});

describe('searching IMAP mail at the server', () => {
  it('asks the Inbox first, leaves out Trash and Spam, and bounds the folders it asks about', () => {
    expect.hasAssertions();
    const folder = (name: string, roles: string[] = []) => ({
      name,
      roles,
      selectable: true,
    });
    expect(
      searchedFolders([
        folder('Projects'),
        folder('INBOX', ['inbox']),
        folder('Trash', ['trash']),
        folder('Sent', ['sent']),
        folder('Junk', ['junk']),
        { ...folder('Parent'), selectable: false },
      ]),
    ).toStrictEqual(['INBOX', 'Sent', 'Projects']);
  });

  it('keeps an online-only reader’s read state current after the server confirms it', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('Projects', { subject: 'Online only' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const result = await inbox.searchGmail('Online only');
    const message = first(foundMessages(result));
    await inbox.organize(message, { kind: 'read' });
    expect(inbox.message(message.id)?.unread).toBe(false);
    await inbox.organize(message, { kind: 'unread' });
    expect(inbox.message(message.id)?.unread).toBe(true);
  });

  it('lists every searched folder newest first, says when folders were left out, and opens results without saving them', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('INBOX', {
      subject: 'Invoice in Inbox',
      received: Date.UTC(2026, 9, 1),
    });
    imap.deliver('Archive', {
      subject: 'Archived invoice',
      received: Date.UTC(2026, 9, 2),
    });
    imap.deliver('Deleted Messages', { subject: 'Deleted invoice' });
    for (let index = 0; index < 50; index += 1) {
      imap.addFolder(`Folder ${index}`);
    }
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const page = await inbox.searchGmail('invoice');
    expect(page).toMatchObject({ kind: 'found', limited: true });
    const messages = foundMessages(page);
    expect(messages.map(({ subject }) => subject)).toStrictEqual([
      'Archived invoice',
      'Invoice in Inbox',
    ]);
    const archived = first(messages);
    expect(inbox.message(archived.id)).toStrictEqual(archived);
    const release = inbox.retainMessage(archived.id);
    await inbox.readMessage(archived.id);
    release();
    expect(imap.bodies.size).toBe(0);

    imap.server.failure = 'offline';
    await expect(inbox.searchGmail('invoice')).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'offline',
    });
  });

  it('joins the unified online search beside other mailboxes and reports a limited IMAP search', async () => {
    expect.hasAssertions();
    const imap = organizedServer();
    imap.deliver('INBOX', { subject: 'Invoice' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const mailbox = { id: 'imap-connection', inbox };
    const found = await searchGmail([mailbox], 'invoice');
    expect(found.results.map(({ message }) => message.subject)).toStrictEqual([
      'Invoice',
    ]);
    expect(found.limited).toStrictEqual([]);
    expect(found.next.size).toBe(0);
    // More matches than one folder lists say the search was limited too.
    for (let index = 0; index < 50; index += 1) {
      imap.deliver('INBOX', { subject: `Invoice ${index}` });
    }
    const more = await searchGmail([mailbox], 'invoice');
    expect(more.limited).toStrictEqual([mailbox]);
  });
});

describe('keeping IMAP mail fresh with IDLE', () => {
  const registration = {
    getSnapshot: () => ({
      busy: false,
      failed: false,
      snapshot: {
        kind: 'connected' as const,
        productAccountId: 'account',
        signInProvider: 'apple' as const,
        mailboxes: JSON.stringify([
          {
            id: 'imap-connection',
            address: 'alex@example.invalid',
            provider: 'imap',
            imap: { host: 'imap.example.invalid', port: 993, username: 'alex' },
            state: 'connected',
          },
        ]),
      },
    }),
    subscribe: () => () => undefined,
  };

  it('reads the Inbox again when the server reports a change while watched, and stops waiting when unwatched', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const mailboxes = createMailboxes(
      syntheticConnections({}, { 'imap-connection': imap.native }),
      registration,
    );
    await mailboxes.load();
    const stop = mailboxes.watch();
    await vi.waitFor(() => {
      expect(imap.idling()).toBe(1);
    });
    imap.deliver('INBOX', { subject: 'Arrived' });
    imap.notify();
    const inbox = imapInbox(mailboxes);
    await vi.waitFor(() => {
      expect(subjects(inbox.getSnapshot())).toStrictEqual(['Arrived']);
    });
    await vi.waitFor(() => {
      expect(imap.idling()).toBe(1);
    });
    stop();
    imap.notify(false);
    await sleep(20);
    expect(imap.idling()).toBe(0);
  });

  it('reconnects after an IDLE interruption and catches up subsequent external mail', async () => {
    expect.hasAssertions();
    vi.useFakeTimers();
    const imap = createSyntheticImap();
    const inbox = createImapInbox({
      ...imap.native,
      imapIdle: interruptIdle(imap.native),
    });
    let stop: (() => void) | undefined = undefined;
    try {
      await inbox.load();
      stop = inbox.watch();
      await vi.advanceTimersByTimeAsync(0);
      expect(imap.idling()).toBe(0);
      await vi.advanceTimersByTimeAsync(5000);
      expect(imap.idling()).toBe(1);
      imap.deliver('INBOX', { subject: 'After reconnect' });
      imap.notify();
      await vi.advanceTimersByTimeAsync(0);
      expect(subjects(inbox.getSnapshot())).toStrictEqual(['After reconnect']);
    } finally {
      stop?.();
      imap.notify(false);
      inbox.forget();
      vi.useRealTimers();
    }
  });

  it('leaves a server without IDLE to polling and foreground catch-up', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.server.capabilities = { moves: true, idle: false };
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const stop = inbox.watch();
    await sleep(20);
    expect(
      imap.server.reads.filter((read) => read.startsWith('idle')),
    ).toStrictEqual([]);
    stop();
  });
});
