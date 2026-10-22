import assert from 'node:assert/strict';

import * as Vitest from '@effect/vitest';

import type {
  ImapBodyState,
  ImapFolderView,
  ImapInboxState,
} from '../src/imap-inbox.ts';

import { applyFolderRead, createImapInbox } from '../src/imap-inbox.ts';
import { createMailboxes } from '../src/mailboxes.ts';
import { createRegistration, mailboxesOf } from '../src/registration.ts';
import { syntheticConnections } from '../src/testing/gmail-mailbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';
import {
  createSyntheticDevice,
  createSyntheticVault,
} from '../src/testing/registration-vault.ts';

const setup = (password: string) => ({
  address: 'alex@example.invalid',
  host: 'imap.example.invalid',
  port: 993,
  username: 'alex@example.invalid',
  password,
  smtp: {
    host: 'smtp.example.invalid',
    port: 465,
    security: 'tls' as const,
    username: 'alex@example.invalid',
  },
});

const ready = (state: ImapInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready IMAP Inbox, received ${state.kind}`);
  }
  return state;
};

// The only connection's IMAP Inbox store.
const imapInbox = (mailboxes: Readonly<ReturnType<typeof createMailboxes>>) => {
  const [entry] = mailboxes.getConnections();
  if (entry === undefined || !('openFolder' in entry.inbox)) {
    throw new Error('Expected an IMAP connection');
  }
  return entry.inbox;
};

// A read folder's first message.
const firstMessage = (view: ImapFolderView) => {
  const [message] = view.kind === 'ready' ? view.messages : [];
  if (message === undefined) {
    throw new Error('Expected a read folder with a message');
  }
  return message;
};

const readyBody = (body: ImapBodyState | undefined) => {
  if (body?.kind !== 'ready') {
    throw new Error(`Expected a ready body, received ${body?.kind}`);
  }
  return body;
};

const crlf = (lines: readonly string[]) => lines.join('\r\n');

describe('connecting IMAP mailboxes', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one IMAP path end to end. */
  it('offers IMAP as the first mailbox without Gmail, keeps the account on failure and resumes after relaunch', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const launch = () => createRegistration(createSyntheticVault(device).vault);
    const store = launch();
    await store.register('apple');
    // Signing in asks for no Gmail consent; the person chooses the first mailbox's provider.
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      signInProvider: 'apple',
    });
    expect(device.google.hints).toStrictEqual([]);

    await store.connectImap(setup('wrong-password'));
    expect(store.getSnapshot()).toMatchObject({
      snapshot: { kind: 'mailbox-needed', reason: 'imap-refused' },
      failed: false,
    });
    expect(device.device.record?.product).toBeDefined();
    expect(device.device.record?.connections).toStrictEqual([]);

    // The failure and the Product Account survive a relaunch.
    const relaunched = launch();
    await relaunched.restore();
    expect(relaunched.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      reason: 'imap-refused',
    });
    device.imap.outcome = 'imap-insecure';
    await relaunched.connectImap(setup(device.imap.password));
    expect(relaunched.getSnapshot().snapshot).toMatchObject({
      reason: 'imap-insecure',
    });
    device.imap.outcome = undefined;
    await relaunched.connectImap(setup(device.imap.password));
    const connected = relaunched.getSnapshot().snapshot;
    expect(connected.kind).toBe('connected');
    expect(mailboxesOf(connected)).toStrictEqual([
      expect.objectContaining({
        address: 'alex@example.invalid',
        provider: 'imap',
        state: 'connected',
      }),
    ]);
    // The password never reaches the snapshot hosts read.
    expect(JSON.stringify(connected)).not.toContain(device.imap.password);
    expect(device.google.hints).toStrictEqual([]);

    // Each launch logs in again; a changed password asks for it again and opens nothing.
    const again = launch();
    await again.restore();
    expect(again.getSnapshot().snapshot.kind).toBe('connected');
    device.imap.password = 'rotated-password';
    const rotated = launch();
    await rotated.restore();
    expect(mailboxesOf(rotated.getSnapshot().snapshot)).toStrictEqual([
      expect.objectContaining({ provider: 'imap', state: 'authorization' }),
    ]);
    // Offline keeps the saved Inbox open from this device.
    await rotated.connectImap(setup('rotated-password'));
    device.imap.outcome = 'offline';
    const offline = launch();
    await offline.restore();
    expect(offline.getSnapshot().snapshot.kind).toBe('cached');
  });

  it('reopens a current IMAP Inbox at the generation a proactive password repair renews', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    await store.connectImap(setup(device.imap.password));
    const [connection] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(connection);
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Saved IMAP message' });
    const opened = vi.fn<typeof imap.native.imapOpen>(imap.native.imapOpen);
    const mailboxes = createMailboxes(
      syntheticConnections(
        {},
        { [connection.id]: { ...imap.native, imapOpen: opened } },
      ),
      store,
    );
    await mailboxes.load();
    expect(ready(imapInbox(mailboxes).getSnapshot()).status).toBe('current');
    // Entering the password again while the Inbox is current renews its native generation.
    imap.cache.generation = 'generation-2';
    await store.connectImap(setup(device.imap.password));
    await vi.waitFor(() => {
      expect(ready(imapInbox(mailboxes).getSnapshot()).status).toBe('current');
    });
    expect(opened).toHaveBeenLastCalledWith(
      expect.objectContaining({ generation: 'generation-2' }),
    );
  });

  it('reads a refused IMAP Inbox again once its password is repaired, without a relaunch', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    await store.connectImap(setup(device.imap.password));
    const [connection] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(connection);
    await store.connectImap({
      ...setup(device.imap.password),
      host: 'other.example.invalid',
    });
    const [, otherConnection] = mailboxesOf(store.getSnapshot().snapshot);
    Vitest.assert.isDefined(otherConnection);
    const imap = createSyntheticImap();
    const other = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Saved IMAP message' });
    const opened = vi.fn<typeof imap.native.imapOpen>(imap.native.imapOpen);
    const mailboxes = createMailboxes(
      syntheticConnections(
        {},
        {
          [connection.id]: { ...imap.native, imapOpen: opened },
          [otherConnection.id]: other.native,
        },
      ),
      store,
    );
    await mailboxes.load();
    // A live read refuses the password while registration still lists the connection.
    imap.server.failure = 'gmail-unavailable';
    other.server.failure = 'gmail-unavailable';
    await mailboxes.load();
    expect(ready(imapInbox(mailboxes).getSnapshot()).status).toBe(
      'authentication',
    );
    // Drain each Inbox's serialized work with one explicit read so extra automatic reads count.
    let reads = imap.server.reads.length;
    await store.refreshPrivateSync();
    await mailboxes.load();
    expect(imap.server.reads).toHaveLength(reads + 1);
    reads = imap.server.reads.length;
    device.imap.outcome = 'offline';
    await store.refreshInbox(mailboxes.load, 'explicit');
    device.imap.outcome = undefined;
    expect(store.getSnapshot().snapshot.kind).toBe('cached');
    expect(imap.server.reads).toHaveLength(reads + 1);
    reads = imap.server.reads.length;
    await store.connectImap(setup('wrong-password'));
    await mailboxes.load();
    expect(imap.server.reads).toHaveLength(reads + 1);
    reads = imap.server.reads.length;
    device.imap.outcome = 'cancelled';
    await store.connectImap(setup(device.imap.password));
    device.imap.outcome = undefined;
    await mailboxes.load();
    expect(imap.server.reads).toHaveLength(reads + 1);

    const otherReads = other.server.reads.length;
    reads = imap.server.reads.length;
    const { logins } = device.imap;
    // Native password repair rotates this connection's cache generation.
    imap.cache.generation = 'generation-2';
    imap.server.failure = undefined;
    imap.deliver('INBOX', { subject: 'Read after password repair' });
    await store.connectImap({
      ...setup(device.imap.password),
      host: 'IMAP.EXAMPLE.INVALID',
    });
    await vi.waitFor(() => {
      expect(ready(imapInbox(mailboxes).getSnapshot()).status).toBe('current');
    });
    expect(ready(imapInbox(mailboxes).getSnapshot()).messages[0]?.subject).toBe(
      'Read after password repair',
    );
    expect(opened).toHaveBeenLastCalledWith(
      expect.objectContaining({ generation: 'generation-2' }),
    );
    expect(imap.server.reads).toHaveLength(reads + 3);
    expect(device.imap.logins).toBe(logins + 1);
    const otherInbox = mailboxes.getConnections()[1]?.inbox;
    Vitest.assert.isDefined(otherInbox);
    await otherInbox.load();
    expect(other.server.reads).toHaveLength(otherReads + 1);
    expect(otherInbox.getSnapshot()).toMatchObject({
      status: 'authentication',
    });
  });

  it('keeps connected mailboxes open when adding an IMAP mailbox cannot confirm sign-in offline', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('google');
    await store.addMailbox();
    const connected = store.getSnapshot().snapshot;
    expect(connected.kind).toBe('connected');
    device.backend.offline = true;
    await store.connectImap(setup(device.imap.password));
    // The form reports the failure; no setup reason is recorded and every Inbox stays listed.
    expect(store.getSnapshot()).toMatchObject({
      snapshot: connected,
      imapFailure: 'failed',
    });
    expect(device.device.record?.mailboxSetupReason).toBeUndefined();
    expect(device.imap.logins).toBe(0);
  });

  it('keeps Microsoft and IMAP connections for the same address independently removable', async () => {
    expect.hasAssertions();
    const device = createSyntheticDevice();
    const store = createRegistration(createSyntheticVault(device).vault);
    await store.register('apple');
    await store.addMailbox('microsoft-graph');
    await store.connectImap({
      ...setup(device.imap.password),
      address: device.microsoft.address,
    });
    const connected = mailboxesOf(store.getSnapshot().snapshot);
    expect(connected.map(({ provider }) => provider)).toStrictEqual([
      'microsoft-graph',
      'imap',
    ]);
    expect(new Set(connected.map(({ id }) => id)).size).toBe(2);
    const imap = connected.find(({ provider }) => provider === 'imap');
    assert.ok(imap);
    await store.removeMailbox(imap.id);
    expect(mailboxesOf(store.getSnapshot().snapshot)).toStrictEqual([
      expect.objectContaining({
        provider: 'microsoft-graph',
        state: 'connected',
      }),
    ]);
  });

  it('synchronizes the Inbox by UID, resumes from its checkpoint and relists after a UIDVALIDITY change', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const first = imap.deliver('INBOX', {
      subject: 'First',
      flags: [String.raw`\Seen`],
    });
    imap.deliver('INBOX', { subject: 'Second' });
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
              imap: {
                host: 'imap.example.invalid',
                port: 993,
                username: 'alex',
              },
              state: 'connected',
            },
          ]),
        },
      }),
      subscribe: () => () => undefined,
    };
    const mailboxes = createMailboxes(
      syntheticConnections({}, { 'imap-connection': imap.native }),
      registration,
    );
    // Only Gmail consumers read `getSnapshot`; the Inbox reads every connection.
    expect(mailboxes.getSnapshot()).toStrictEqual([]);
    const inbox = imapInbox(mailboxes);
    await mailboxes.load();
    const listed = ready(inbox.getSnapshot());
    expect(listed.imap).toBe(true);
    expect(listed.folders.map(({ name }) => name)).toStrictEqual(['INBOX']);
    expect(
      listed.messages.map(({ subject, unread }) => ({ subject, unread })),
    ).toStrictEqual([
      { subject: 'Second', unread: true },
      { subject: 'First', unread: false },
    ]);

    // Later synchronizations read only flags and arrivals since the committed checkpoint.
    imap.setFlags('INBOX', first, []);
    imap.expunge('INBOX', 2);
    imap.deliver('INBOX', { subject: 'Third' });
    imap.server.reads.length = 0;
    await mailboxes.load();
    expect(
      ready(inbox.getSnapshot()).messages.map(({ subject, unread }) => ({
        subject,
        unread,
      })),
    ).toStrictEqual([
      { subject: 'Third', unread: true },
      { subject: 'First', unread: true },
    ]);
    expect(imap.server.reads).toStrictEqual([
      'login',
      'folders',
      'synchronize INBOX',
    ]);

    // A relaunch shows the encrypted cache before the server answers, then resumes from it.
    const relaunched = createMailboxes(
      syntheticConnections({}, { 'imap-connection': imap.native }),
      registration,
    );
    imap.server.failure = 'offline';
    await relaunched.load();
    const cachedInbox = imapInbox(relaunched);
    const cached = ready(cachedInbox.getSnapshot());
    expect(cached.status).toBe('retry');
    expect(cached.messages.map(({ subject }) => subject)).toStrictEqual([
      'Third',
      'First',
    ]);
    // A refused password asks for it again and keeps the saved mail.
    imap.server.failure = 'gmail-unavailable';
    await relaunched.load();
    expect(ready(cachedInbox.getSnapshot()).status).toBe('authentication');
    imap.server.failure = undefined;

    // A new UIDVALIDITY makes every earlier UID meaningless; the folder is listed again.
    const before = new Set(
      ready(inbox.getSnapshot()).messages.map(({ id }) => id),
    );
    imap.renumber('INBOX');
    await mailboxes.load();
    const after = ready(inbox.getSnapshot()).messages;
    expect(after.map(({ subject }) => subject)).toStrictEqual([
      'Third',
      'First',
    ]);
    expect(after.some(({ id }) => before.has(id))).toBe(false);
  });

  it('refuses an unidentified folder before caching messages and retries with established UIDVALIDITY', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Established identity' });
    const unidentified = vi
      .spyOn(imap.native, 'imapSynchronize')
      .mockResolvedValue({
        uidValidity: 0,
        uidNext: 2,
        reset: true,
        messages: [
          {
            uid: 1,
            flags: [],
            received: 1,
            size: 1,
            sender: 'Synthetic Sender',
            address: 'sender@example.invalid',
            subject: 'Unidentified message',
          },
        ],
        flags: [],
      });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      status: 'retry',
      messages: [],
    });
    expect(imap.cache.commits).toBe(1);
    unidentified.mockRestore();
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      status: 'current',
      messages: [expect.objectContaining({ subject: 'Established identity' })],
    });
  });

  it('refuses a cached zero-UIDVALIDITY identity while offline instead of reopening its body', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Cached mail' });
    const previous = createImapInbox(imap.native);
    await previous.load();
    const message = firstMessage(previous.folder('INBOX'));
    await previous.readMessage(message.id);
    assert.ok(imap.cache.document);
    imap.cache.document = imap.cache.document.replaceAll(
      '"uidValidity":7',
      '"uidValidity":0',
    );
    imap.server.failure = 'offline';
    imap.server.reads.length = 0;
    const relaunched = createImapInbox(imap.native);
    await relaunched.load();
    expect(relaunched.getSnapshot()).toStrictEqual({ kind: 'failed' });
    await relaunched.readMessage(message.id);
    expect(relaunched.messageBody(message.id)).toBeUndefined();
    expect(imap.server.reads).toStrictEqual([]);
    imap.server.failure = undefined;
    const { commits } = imap.cache;
    await relaunched.load();
    expect(relaunched.getSnapshot()).toStrictEqual({ kind: 'failed' });
    expect(imap.cache.commits).toBe(commits);
  });

  it('lists folders from one server session and closes it whether the listing succeeds or fails', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const listed = vi.spyOn(imap.native, 'imapListFolders').mockResolvedValue({
      folders: [
        { name: 'inbox', attributes: [String.raw`\HasNoChildren`] },
        // A dotless ı makes no ASCII case variant of INBOX.
        { name: 'ınbox', attributes: [] },
        { name: 'Primary', attributes: [String.raw`\Inbox`] },
        {
          name: 'Sent Items',
          attributes: [String.raw`\Sent`, String.raw`\Archive`],
          delimiter: '/',
        },
        { name: '[Gmail]', attributes: [String.raw`\Noselect`] },
      ],
    });
    vi.spyOn(imap.native, 'imapCapabilities').mockResolvedValue({
      capabilities: ['IMAP4rev1', 'uidplus'],
    });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      status: 'current',
      folders: [
        { name: 'INBOX', roles: ['inbox'], selectable: true },
        { name: 'ınbox', roles: [], selectable: true },
        { name: 'Primary', roles: ['inbox'], selectable: true },
        {
          name: 'Sent Items',
          roles: ['archive', 'sent'],
          selectable: true,
          delimiter: '/',
        },
        { name: '[Gmail]', roles: [], selectable: false },
      ],
      capabilities: { moves: true, idle: false },
    });
    expect(imap.server.sessions.size).toBe(0);

    listed.mockRejectedValueOnce({ code: 'offline' });
    await inbox.load();
    expect(ready(inbox.getSnapshot()).status).toBe('retry');
    expect(imap.server.sessions.size).toBe(0);
  });

  it('reads folders on demand and opens a body once, from the server and then this device', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive', ['archive']);
    const pixel =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    const uid = imap.deliver('Archive', {
      subject: 'Report',
      raw: crlf([
        'From: Synthetic Sender <sender@example.invalid>',
        'Subject: Report',
        'MIME-Version: 1.0',
        'Content-Type: multipart/mixed; boundary="outer"',
        '',
        '--outer',
        'Content-Type: multipart/related; boundary="related"',
        '',
        '--related',
        'Content-Type: multipart/alternative; boundary="alt"',
        '',
        '--alt',
        'Content-Type: text/plain; charset=iso-8859-1',
        'Content-Transfer-Encoding: quoted-printable',
        '',
        'Caf=E9 report',
        '--alt',
        'Content-Type: text/html; charset=utf-8',
        'Content-Transfer-Encoding: base64',
        '',
        btoa(
          '<p>Café <img src="cid:chart@example.invalid"> report</p>'.replace(
            'é',
            'Ã©',
          ),
        ),
        '--alt--',
        '--related',
        'Content-Type: image/png',
        'Content-ID: <chart@example.invalid>',
        'Content-Transfer-Encoding: base64',
        '',
        pixel,
        '--related--',
        '--outer',
        'Content-Type: application/pdf; name="report.pdf"',
        'Content-Disposition: attachment; filename="report.pdf"',
        'Content-Transfer-Encoding: base64',
        '',
        'JVBERi0xLjQK',
        '--outer--',
      ]),
    });
    const registration = {
      getSnapshot: () => ({
        busy: false,
        failed: false,
        snapshot: {
          kind: 'connected' as const,
          productAccountId: 'account',
          signInProvider: 'google' as const,
          mailboxes: JSON.stringify([
            {
              id: 'imap-connection',
              address: 'alex@example.invalid',
              provider: 'imap',
              imap: {
                host: 'imap.example.invalid',
                port: 993,
                username: 'alex',
              },
              state: 'connected',
            },
          ]),
        },
      }),
      subscribe: () => () => undefined,
    };
    const mailboxes = createMailboxes(
      syntheticConnections({}, { 'imap-connection': imap.native }),
      registration,
    );
    await mailboxes.load();
    const inbox = imapInbox(mailboxes);
    expect(
      ready(inbox.getSnapshot()).folders.map(({ name }) => name),
    ).toStrictEqual(['INBOX', 'Archive']);
    // The server's hierarchy delimiter lets the Move picker nest folder names.
    expect(ready(inbox.getSnapshot()).folders).toContainEqual({
      name: 'Archive',
      roles: ['archive'],
      selectable: true,
      delimiter: '/',
    });
    expect(inbox.folder('Archive')).toStrictEqual({ kind: 'loading' });
    await inbox.openFolder('Archive');
    const message = firstMessage(inbox.folder('Archive'));
    expect(message).toMatchObject({
      folder: 'Archive',
      uid,
      subject: 'Report',
    });
    const { id } = message;
    // A listed message reads as saved only once its body is on this device, so search never
    // presents it as available offline before it is downloaded.
    await expect(inbox.savedBodies([id])).resolves.toStrictEqual(new Set());

    const release = inbox.retainMessage(id);
    await inbox.readMessage(id);
    await expect(inbox.savedBodies([id, 'unlisted'])).resolves.toStrictEqual(
      new Set([id]),
    );
    const body = readyBody(inbox.messageBody(id));
    // Listing the attachment reads nothing more from the server.
    expect(inbox.messageAttachments(id)).toStrictEqual([
      {
        locator: '0.1',
        name: 'report.pdf',
        mimeType: 'application/pdf',
        size: 9,
        state: { kind: 'available' },
      },
    ]);
    expect(body.presentation.rich?.document).toContain('Café');
    expect(body.presentation.rich?.document).toContain(
      'data:image/png;base64,',
    );
    expect(JSON.stringify(body.presentation.readable)).toContain('Café report');
    release();

    // The body is stored for the listed message; a second open reads only this device.
    imap.server.reads.length = 0;
    const again = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(inbox.messageBody(id)?.kind).toBe('ready');
    expect(imap.server.reads).toStrictEqual([]);
    again();

    // A UID read under another UIDVALIDITY is gone, never a different message.
    imap.bodies.clear();
    imap.renumber('Archive');
    const stale = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(inbox.messageBody(id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'imap-missing',
    });
    stale();
  });

  it('keeps body availability unknown for unreadable storage and drops a reply after the Inbox closes', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', { subject: 'Cached metadata' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const { id } = firstMessage(inbox.folder('INBOX'));
    const lookup = vi.spyOn(imap.native, 'listMessageBodies');
    const logs = vi.spyOn(console, 'error').mockReturnValue(undefined);
    lookup.mockRejectedValueOnce({ code: 'locked' });
    await expect(inbox.savedBodies([id])).resolves.toBeUndefined();
    expect(logs).not.toHaveBeenCalled();

    lookup.mockResolvedValueOnce({ stored: [id], excluded: [id] });
    await expect(inbox.savedBodies([id])).resolves.toStrictEqual(new Set());
    lookup.mockResolvedValueOnce({ stored: [id] });
    await expect(inbox.savedBodies([id])).resolves.toBeUndefined();
    expect(logs).toHaveBeenCalledWith(
      expect.any(String),
      'Saved IMAP bodies could not be listed:',
      'invalid at excluded',
    );

    const requested = Promise.withResolvers<undefined>();
    const answer = Promise.withResolvers<unknown>();
    lookup.mockImplementationOnce(() => {
      requested.resolve(undefined);
      return answer.promise;
    });
    const pending = inbox.savedBodies([id]);
    await requested.promise;
    inbox.forget();
    answer.resolve({ stored: [id], excluded: [] });
    await expect(pending).resolves.toStrictEqual(new Set());
    await expect(inbox.savedBodies([id])).resolves.toStrictEqual(new Set());
    lookup.mockRestore();
    logs.mockRestore();
  });

  it.each([
    {
      code: 'locked',
      state: { kind: 'locked' },
      folder: { kind: 'failed' },
      subject: undefined,
      body: undefined,
      removals: 0,
    },
    {
      code: 'mailbox-revoked',
      state: { kind: 'failed' },
      folder: { kind: 'failed' },
      subject: undefined,
      body: undefined,
      removals: 1,
    },
    {
      code: 'imap-refused',
      state: { kind: 'ready', status: 'authentication' },
      folder: { kind: 'ready', status: 'authentication' },
      subject: 'Private archive',
      body: 'ready',
      removals: 0,
    },
  ])(
    'propagates $code discovered in another folder and retries after access returns',
    async ({ code, state, folder, subject, body, removals }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.addFolder('Archive');
      imap.deliver('INBOX', { subject: 'Inbox mail' });
      imap.deliver('Archive', { subject: 'Private archive' });
      const removed = vi.fn<() => void>();
      const inbox = createImapInbox(imap.native, { removed });
      await inbox.load();
      await inbox.openFolder('Archive');
      const message = firstMessage(inbox.folder('Archive'));
      const release = inbox.retainMessage(message.id);
      await inbox.readMessage(message.id);
      expect(inbox.messageBody(message.id)?.kind).toBe('ready');
      imap.server.failure = code;
      await inbox.openFolder('Archive');
      expect(inbox.getSnapshot()).toMatchObject(state);
      expect(inbox.folder('Archive')).toMatchObject(folder);
      expect(inbox.message(message.id)?.subject).toBe(subject);
      expect(inbox.messageBody(message.id)?.kind).toBe(body);
      expect(removed).toHaveBeenCalledTimes(removals);
      imap.server.failure = undefined;
      await inbox.load();
      await inbox.openFolder('Archive');
      expect(firstMessage(inbox.folder('Archive')).subject).toBe(
        'Private archive',
      );
      expect(ready(inbox.getSnapshot()).status).toBe('current');
      release();
    },
  );

  it('reopens the cache and reads a folder again after another store committed it', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive');
    imap.deliver('Archive', { subject: 'Archived' });
    const first = createImapInbox(imap.native);
    await first.load();
    // Another window's store commits the same connection's cache after this one opened it.
    const second = createImapInbox(imap.native);
    await second.load();
    await first.openFolder('Archive');
    expect(first.folder('Archive')).toMatchObject({
      kind: 'ready',
      status: 'current',
    });
    expect(firstMessage(first.folder('Archive')).subject).toBe('Archived');
  });

  it('keeps a folder refresh failure across an Inbox reload that does not read that folder', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive');
    imap.deliver('Archive', { subject: 'Archived' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await inbox.openFolder('Archive');
    imap.server.failure = 'offline';
    await inbox.openFolder('Archive');
    expect(inbox.folder('Archive')).toMatchObject({ status: 'retry' });
    // The server answers again, but only the Inbox is read; the Archive was not refreshed.
    imap.server.failure = undefined;
    await inbox.load();
    expect(ready(inbox.getSnapshot()).status).toBe('current');
    expect(inbox.folder('Archive')).toMatchObject({
      kind: 'ready',
      status: 'retry',
    });
  });

  it('keeps rows of a folder evicted from the cache openable while they are shown', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const names = Array.from({ length: 9 }, (_, index) => `Folder ${index}`);
    for (const name of names) {
      imap.addFolder(name);
      imap.deliver(name, { subject: `In ${name}` });
    }
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    for (const name of names) {
      await inbox.openFolder(name);
    }
    // Opening the ninth folder evicts the least recently read one from the cache.
    const shown = firstMessage(inbox.folder('Folder 0'));
    expect(inbox.message(shown.id)).toStrictEqual(shown);
    const release = inbox.retainMessage(shown.id);
    await inbox.readMessage(shown.id);
    expect(inbox.messageBody(shown.id)?.kind).toBe('ready');
    expect(imap.bodies.has(shown.id)).toBe(false);
    release();
    expect(inbox.messageBody(shown.id)).toBeUndefined();
  });

  it('keeps a shown evicted folder across an Inbox reload', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const names = Array.from({ length: 9 }, (_, index) => `Folder ${index}`);
    for (const name of names) {
      imap.addFolder(name);
      imap.deliver(name, { subject: `In ${name}` });
    }
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    for (const name of names) {
      await inbox.openFolder(name);
    }
    const shown = inbox.folder('Folder 0');
    expect(firstMessage(shown).subject).toBe('In Folder 0');
    // A routine Inbox reload reopens the cache, which no longer lists the evicted folder.
    await inbox.load();
    expect(inbox.folder('Folder 0')).toBe(shown);
    // Password repair renews the native generation of this same connection, not its owner.
    imap.cache.generation = 'generation-2';
    await inbox.load();
    expect(inbox.folder('Folder 0')).toBe(shown);
    // Closing access clears even an evicted view; reopening cannot recover its former rows.
    const opening = vi
      .spyOn(imap.native, 'openMailbox')
      .mockRejectedValue({ code: 'locked' });
    await inbox.load();
    expect(inbox.folder('Folder 0')).toStrictEqual({ kind: 'failed' });
    opening.mockRestore();
    await inbox.load();
    expect(inbox.folder('Folder 0')).toStrictEqual({ kind: 'loading' });
  });

  it('reports the saved body of a row still shown from an evicted folder', async () => {
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
    // Its body is saved while the folder is still cached.
    const shown = firstMessage(inbox.folder('Folder 0'));
    const release = inbox.retainMessage(shown.id);
    await inbox.readMessage(shown.id);
    release();
    for (const name of names.slice(1)) {
      await inbox.openFolder(name);
    }
    await expect(inbox.savedBodies([shown.id])).resolves.toStrictEqual(
      new Set([shown.id]),
    );
  });

  it('keeps an uncached folder failure and stable snapshots until recovery or retirement', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive');
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.server.failure = 'offline';
    await inbox.openFolder('Archive');
    expect(inbox.folder('Archive')).toStrictEqual({ kind: 'failed' });
    // Reopening the Inbox must preserve a failed first read even without a cached folder.
    imap.server.failure = undefined;
    await inbox.load();
    expect(inbox.folder('Archive')).toStrictEqual({ kind: 'failed' });
    expect(inbox.folder('Archive')).toBe(inbox.folder('Archive'));
    imap.deliver('Archive', { subject: 'Archived' });
    await inbox.openFolder('Archive');
    await inbox.load();
    expect(inbox.folder('Archive')).toBe(inbox.folder('Archive'));
    expect(firstMessage(inbox.folder('Archive')).subject).toBe('Archived');
    expect(inbox.folder('Archive')).toMatchObject({ status: 'current' });
    imap.removeFolder('Archive');
    await inbox.load();
    expect(inbox.folder('Archive')).toStrictEqual({ kind: 'loading' });
  });

  it.each([
    { code: 'locked', state: { kind: 'locked' } },
    { code: 'mailbox-invalidated', state: { kind: 'failed' } },
    {
      code: 'imap-refused',
      state: { kind: 'ready', status: 'authentication' },
    },
  ])(
    'withholds a downloaded body when its native cache write rejects with $code',
    async ({ code, state }) => {
      expect.hasAssertions();
      const imap = createSyntheticImap();
      imap.deliver('INBOX', { subject: 'Private body' });
      const commit = vi
        .spyOn(imap.native, 'commitMessageBody')
        .mockRejectedValue({ code });
      const inbox = createImapInbox(imap.native);
      await inbox.load();
      const message = firstMessage(inbox.folder('INBOX'));
      const release = inbox.retainMessage(message.id);
      await inbox.readMessage(message.id);
      expect(inbox.messageBody(message.id)?.kind).not.toBe('ready');
      expect(inbox.getSnapshot()).toMatchObject(state);
      commit.mockRestore();
      await inbox.load();
      await inbox.readMessage(message.id);
      expect(inbox.messageBody(message.id)?.kind).toBe('ready');
      release();
    },
  );

  it('hides a selected cached folder when reopening storage discovers a lock', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive');
    imap.deliver('Archive', { subject: 'Private archive' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await inbox.openFolder('Archive');
    const opening = vi
      .spyOn(imap.native, 'openMailbox')
      .mockRejectedValue({ code: 'locked' });
    await inbox.load();
    expect(inbox.getSnapshot()).toStrictEqual({ kind: 'locked' });
    expect(inbox.folder('Archive')).toStrictEqual({ kind: 'failed' });
    expect(inbox.folder('Archive')).toBe(inbox.folder('Archive'));
    opening.mockRestore();
    await inbox.load();
    await inbox.openFolder('Archive');
    expect(firstMessage(inbox.folder('Archive')).subject).toBe(
      'Private archive',
    );
  });

  it('discards a body read from before a lock even after the same native generation reopens', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Archive');
    imap.deliver('INBOX', { subject: 'Private body' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const message = firstMessage(inbox.folder('INBOX'));
    const raw = await imap.native.imapMessage(
      { address: 'alex@example.invalid', generation: imap.cache.generation },
      {
        folder: message.folder,
        uidValidity: message.uidValidity,
        uid: message.uid,
      },
    );
    const requested = Promise.withResolvers<undefined>();
    const answer = Promise.withResolvers<unknown>();
    const reading = vi
      .spyOn(imap.native, 'imapMessage')
      .mockImplementationOnce(() => {
        requested.resolve(undefined);
        return answer.promise;
      });
    const release = inbox.retainMessage(message.id);
    const pending = inbox.readMessage(message.id);
    await requested.promise;
    imap.server.failure = 'locked';
    await inbox.openFolder('Archive');
    imap.server.failure = undefined;
    await inbox.load();
    answer.resolve(raw);
    await pending;
    expect(inbox.messageBody(message.id)).toBeUndefined();
    expect(imap.bodies.size).toBe(0);
    reading.mockRestore();
    await inbox.readMessage(message.id);
    expect(inbox.messageBody(message.id)?.kind).toBe('ready');
    release();
  });

  it('keeps known messages only while their UIDVALIDITY holds', () => {
    expect.hasAssertions();
    const read = (uidValidity: number, uids: readonly number[]) => ({
      uidValidity,
      uidNext: Math.max(0, ...uids) + 1,
      reset: false,
      messages: uids.map((uid) => ({
        uid,
        flags: [],
        received: uid * 1000,
        size: 1,
        sender: '',
        address: 'sender@example.invalid',
        subject: `Message ${uid}`,
      })),
      flags: [],
    });
    const first = applyFolderRead('INBOX', undefined, read(7, [1, 2]));
    // An empty sender name shows the address.
    expect(first.messages[0]?.sender).toBe('sender@example.invalid');
    // Without flags for a known UID, it left the folder.
    const next = applyFolderRead('INBOX', first, read(7, [3]));
    expect(next.messages.map(({ uid }) => uid)).toStrictEqual([3]);
    const renumbered = applyFolderRead('INBOX', first, {
      ...read(8, [1]),
      flags: [{ uid: 2, flags: [] }],
    });
    expect(renumbered.messages.map(({ id }) => id)).toStrictEqual([
      '8.1.INBOX',
    ]);
  });
});

/* oxlint-enable vitest/max-expects */
