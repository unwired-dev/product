import type { ImapFolderView, ImapInboxState } from '../src/imap-inbox.ts';

import { createImapInbox, imapFolderName } from '../src/imap-inbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const ready = (state: ImapInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready IMAP Inbox, received ${state.kind}`);
  }
  return state;
};

// A read folder's first message.
const firstMessage = (view: ImapFolderView) => {
  const [message] = view.kind === 'ready' ? view.messages : [];
  if (message === undefined) {
    throw new Error('Expected a read folder with a message');
  }
  return message;
};

describe('imap body-cache pruning', () => {
  it.each([
    {
      reason: 'deleted',
      folders: [{ name: 'INBOX', attributes: [] }],
    },
    {
      reason: 'non-selectable',
      folders: [
        { name: 'INBOX', attributes: [] },
        { name: 'Archive', attributes: [String.raw`\Noselect`] },
      ],
    },
  ])(
    'drops the cache and saved bodies of a $reason folder',
    async ({ folders }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.addFolder('Archive');
      imap.deliver('Archive', { subject: 'Archived' });
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      await inbox.openFolder('Archive');
      const archived = firstMessage(inbox.folder('Archive'));
      const release = inbox.retainMessage(archived.id);
      await inbox.readMessage(archived.id);
      release();
      expect(imap.bodies.has(archived.id)).toBe(true);
      imap.removeFolder('Archive');
      vi.spyOn(imap.native, 'imapListFolders').mockResolvedValue({ folders });
      await inbox.load();
      expect(inbox.message(archived.id)).toBeUndefined();
      expect(imap.bodies.has(archived.id)).toBe(false);
      expect(inbox.folder('Archive')).toStrictEqual({ kind: 'loading' });
      expect(imapFolderName(inbox.getSnapshot(), 'Archive')).toBe('INBOX');
    },
  );

  it.each([
    { operation: 'commitMailbox', code: 'unavailable' },
    { operation: 'commitMailbox', code: 'conflict' },
    { operation: 'imapListFolders', code: 'offline' },
  ] as const)(
    'keeps an evicted folder view when $operation fails with $code',
    async ({ operation, code }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      const names = Array.from({ length: 9 }, (_, index) => `Folder ${index}`);
      for (const name of names) {
        imap.addFolder(name);
        imap.deliver(name, { subject: `In ${name}` });
      }
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      await inbox.openFolder('Folder 0');
      const archived = firstMessage(inbox.folder('Folder 0'));
      const release = inbox.retainMessage(archived.id);
      await inbox.readMessage(archived.id);
      release();
      for (const name of names.slice(1)) {
        await inbox.openFolder(name);
      }
      const shown = inbox.folder('Folder 0');
      imap.removeFolder('Folder 0');
      const failed = vi
        .spyOn(imap.native, operation)
        .mockRejectedValue({ code });
      await inbox.load();
      expect(imapFolderName(inbox.getSnapshot(), 'Folder 0')).toBe('Folder 0');
      expect(inbox.folder('Folder 0')).toBe(shown);
      expect(inbox.message(archived.id)).toStrictEqual(archived);
      expect(imap.bodies.has(archived.id)).toBe(true);
      failed.mockRestore();
      await inbox.load();
      expect({
        folder: imapFolderName(inbox.getSnapshot(), 'Folder 0'),
        message: inbox.message(archived.id),
        saved: imap.bodies.has(archived.id),
      }).toStrictEqual({ folder: 'INBOX', message: undefined, saved: false });
    },
  );

  it('removes the saved body of a message the server expunged and keeps the others', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const gone = imap.deliver('INBOX', { subject: 'Expunged later' });
    imap.deliver('INBOX', { subject: 'Still listed' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const ids = ready(inbox.getSnapshot()).messages.map(({ id }) => id);
    for (const id of ids) {
      const release = inbox.retainMessage(id);
      await inbox.readMessage(id);
      release();
    }
    expect([...imap.bodies.keys()].toSorted()).toStrictEqual(ids.toSorted());
    imap.expunge('INBOX', gone);
    await inbox.load();
    const [kept] = ready(inbox.getSnapshot()).messages;
    expect(kept?.subject).toBe('Still listed');
    expect([...imap.bodies.keys()]).toStrictEqual([kept?.id]);
  });

  it.each(['conflict', 'unavailable'])(
    'retries skipped body pruning after $code on the next synchronization',
    async (code) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      const gone = imap.deliver('INBOX', { subject: 'Expunged later' });
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      const { id } = firstMessage(inbox.folder('INBOX'));
      const release = inbox.retainMessage(id);
      await inbox.readMessage(id);
      release();
      imap.expunge('INBOX', gone);
      const pruning = vi
        .spyOn(imap.native, 'retainMessageBodies')
        .mockRejectedValueOnce({ code });
      await inbox.load();
      expect(inbox.getSnapshot()).toMatchObject({
        kind: 'ready',
        status: 'current',
        messages: [],
      });
      expect(imap.bodies.has(id)).toBe(true);
      await inbox.load();
      expect(imap.bodies.has(id)).toBe(false);
      pruning.mockRestore();
    },
  );

  it.each([
    {
      code: 'locked',
      state: { kind: 'locked' },
      folder: { kind: 'failed' },
      body: undefined,
      removals: 0,
    },
    {
      code: 'mailbox-revoked',
      state: { kind: 'failed' },
      folder: { kind: 'failed' },
      body: undefined,
      removals: 1,
    },
    {
      code: 'imap-refused',
      state: { kind: 'ready', status: 'authentication' },
      folder: { kind: 'ready', status: 'authentication' },
      body: 'ready',
      removals: 0,
    },
  ])(
    'recovers access when pruning a selected folder rejects with $code',
    async ({ code, state, folder, body, removals }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.addFolder('Archive');
      imap.deliver('Archive', { subject: 'Cached archive' });
      const removed = vi.fn<() => void>();
      const inbox = createImapInbox(imap.native, { removed });
      await inbox.load();
      await inbox.openFolder('Archive');
      const message = firstMessage(inbox.folder('Archive'));
      const release = inbox.retainMessage(message.id);
      await inbox.readMessage(message.id);
      const pruning = vi
        .spyOn(imap.native, 'retainMessageBodies')
        .mockRejectedValueOnce({ code });
      await inbox.openFolder('Archive');
      expect(inbox.getSnapshot()).toMatchObject(state);
      expect(inbox.folder('Archive')).toMatchObject(folder);
      expect(inbox.messageBody(message.id)?.kind).toBe(body);
      expect(removed).toHaveBeenCalledTimes(removals);
      pruning.mockRestore();
      release();
    },
  );
});
