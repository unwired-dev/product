import type { NativeBlockedSenders } from '../src/blocked-senders.ts';

import { createBlockedSenders } from '../src/blocked-senders.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { defaultProfile } from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const blocked = 'offers@growthleads.io';

// A Gmail, a Microsoft and an IMAP connection of the Default Profile, each with New Mail
// Notifications on, and this device's Blocked Senders, which block `blocked` there.
const setup = async () => {
  const gmail = createSyntheticGmail({ address: 'alex@example.invalid' });
  const graph = createSyntheticGraph();
  const imap = createSyntheticImap();
  imap.addFolder('Trash', ['trash']);
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
            id: 'gmail',
            address: 'alex@example.invalid',
            provider: 'gmail',
            state: 'connected',
            notifications: true,
          },
          {
            id: 'graph',
            address: 'casey@example.invalid',
            provider: 'microsoft-graph',
            state: 'connected',
            notifications: true,
          },
          {
            id: 'imap',
            address: 'alex@example.invalid',
            provider: 'imap',
            imap: { host: 'imap.example.invalid', port: 993, username: 'alex' },
            state: 'connected',
            notifications: true,
          },
        ]),
      },
    }),
    subscribe: () => () => undefined,
  };
  const storage = {
    revision: 0,
    document: null as string | null,
    locked: false,
  };
  const locked = () =>
    Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
  const native: NativeBlockedSenders = {
    openBlockedSenders: () =>
      storage.locked
        ? locked()
        : Promise.resolve({
            owner: 'account',
            revision: storage.revision,
            document: storage.document,
          }),
    commitBlockedSenders: (owner, _revision, document) => {
      storage.revision += 1;
      storage.document = document;
      return Promise.resolve({ owner, revision: storage.revision });
    },
  };
  const blockedSenders = createBlockedSenders(native, registration);
  await blockedSenders.block(defaultProfile, blocked);
  // Another Profile's block changes nothing here.
  await blockedSenders.block('work', 'maya@example.invalid');
  const notified: string[] = [];
  const mailboxes = createMailboxes(
    syntheticConnections({ gmail, graph }, { imap: imap.native }),
    registration,
    {
      arrived: (_mailbox, messages) => {
        notified.push(...messages.map(({ subject }) => subject));
      },
      screen: blockedSenders.screen,
    },
  );
  await mailboxes.load();
  return { gmail, graph, imap, storage, notified, mailboxes };
};

describe("enforcing a Profile's Blocked Senders on new mail", () => {
  it('moves new Inbox mail from a Blocked Sender to Trash, without a notification', async () => {
    expect.hasAssertions();
    const { gmail, graph, imap, notified, mailboxes } = await setup();
    const fromGmail = gmail.deliver({
      from: `Growth Leads <${blocked}>`,
      subject: 'Gmail offer',
    });
    gmail.deliver({ subject: 'Gmail note' });
    const fromGraph = graph.deliver({
      from: { name: 'Growth Leads', address: 'Offers@GrowthLeads.io' },
      subject: 'Microsoft offer',
    });
    graph.deliver({
      from: { name: 'Maya Chen', address: 'maya@example.invalid' },
      subject: 'Microsoft note',
    });
    imap.deliver('INBOX', {
      subject: 'IMAP offer',
      address: blocked,
      received: Date.now(),
    });
    imap.deliver('INBOX', { subject: 'IMAP note', received: Date.now() });
    await mailboxes.load();

    expect(notified.toSorted()).toStrictEqual([
      'Gmail note',
      'IMAP note',
      'Microsoft note',
    ]);
    await vi.waitFor(() => {
      expect(gmail.modifies).toStrictEqual([
        { id: fromGmail, add: ['TRASH'], remove: ['INBOX'] },
      ]);
      expect(graph.modifies).toStrictEqual([
        { message: fromGraph, folder: 'deleteditems' },
      ]);
      expect(imap.server.changes).toStrictEqual(['move INBOX 1 Trash']);
    });
  });

  it('leaves a Blocked Sender’s mail unnotified where no Trash takes it, and notifies all while unreadable', async () => {
    expect.hasAssertions();
    const { imap, storage, notified, mailboxes } = await setup();
    imap.removeFolder('Trash');
    await mailboxes.load();
    imap.deliver('INBOX', {
      subject: 'Kept offer',
      address: blocked,
      received: Date.now(),
    });
    await mailboxes.load();
    expect(notified).toStrictEqual([]);

    storage.locked = true;
    vi.spyOn(console, 'error').mockReturnValue();
    imap.deliver('INBOX', {
      subject: 'Unscreened offer',
      address: blocked,
      received: Date.now(),
    });
    await mailboxes.load();
    expect(notified).toStrictEqual(['Unscreened offer']);
    expect(imap.server.changes).toStrictEqual([]);
  });
});
