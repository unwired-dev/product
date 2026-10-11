import { english } from '@private-email/localization';

import type { GmailInboxState, MessageBodyState } from '../src/gmail-inbox.ts';

import { sendingMailboxes } from '../src/drafts.ts';
import { quickActions } from '../src/gmail-actions.ts';
import { createGmailInbox, threadMessages } from '../src/gmail-inbox.ts';
import {
  createGmailSearch,
  createMailboxes,
  inboxMessages,
} from '../src/mailboxes.ts';
import {
  createRegistration,
  defaultProfile,
  mailboxesOf,
  registrationCopy,
} from '../src/registration.ts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '../src/testing/gmail-mailbox.ts';
import { createSyntheticGraph } from '../src/testing/graph-mailbox.ts';
import {
  createMockRegistrationSession,
  syntheticMailboxes,
} from '../src/testing/registration-session.ts';
import { png } from './remote-content-fixture.ts';

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const rich = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
    throw new Error(`Expected a rich body, received ${state?.kind}`);
  }
  return state.presentation.rich;
};

const microsoftInbox = (graph: ReturnType<typeof createSyntheticGraph>) =>
  createGmailInbox(graph.native, { provider: 'microsoft-graph' });

// The Graph reads by kind: Inbox lists, delta rounds from the start, and delta links.
const interceptGraph = (
  graph: ReturnType<typeof createSyntheticGraph>,
  reply: (url: string) => { status: number; body: string } | undefined,
) => ({
  ...graph.native,
  graphRequest: (
    url: string,
    scope: Parameters<typeof graph.native.graphRequest>[1],
  ) => {
    const intercepted = reply(url);
    return intercepted === undefined
      ? graph.native.graphRequest(url, scope)
      : Promise.resolve(intercepted);
  },
});

const pair = <A>(values: readonly A[]): readonly [A, A] => {
  const [first, second] = values;
  if (first === undefined || second === undefined) {
    throw new Error('Expected two messages');
  }
  return [first, second];
};

const deltaReply = (url: string, value: readonly unknown[] | undefined) =>
  value !== undefined && url.includes('$deltatoken')
    ? {
        status: 200,
        body: JSON.stringify({
          value,
          '@odata.deltaLink':
            "https://graph.microsoft.com/v1.0/me/mailfolders('inbox')/messages/delta?$deltatoken=4",
        }),
      }
    : undefined;

const unavailableMetadata = (url: string, status: number) =>
  /\/attachments(?:\?|$)/u.test(url) ? { status, body: '{}' } : undefined;

const metadataSync = (status: number) =>
  status === 401 ? 'authentication' : 'current';

const unavailableImage = (url: string) =>
  url.includes('/attachments/') ? { status: 503, body: '{}' } : undefined;

// Message reads in order; the folders organizing lists with each synchronization are left out.
const messageReads = (graph: ReturnType<typeof createSyntheticGraph>) =>
  graph.requests.filter(
    (url) => !/\/mailfolders(?:\/[^/]+)?$/u.test(url.pathname.toLowerCase()),
  );
const reads = (graph: ReturnType<typeof createSyntheticGraph>) =>
  messageReads(graph).map((url) => {
    if (url.pathname.toLowerCase().endsWith('/mailfolders/inbox/messages')) {
      return 'list';
    }
    if (url.searchParams.has('$deltatoken')) {
      return 'changes';
    }
    return url.pathname.includes('/delta') ? 'delta' : 'message';
  });

const repeatingDelta = (
  graph: ReturnType<typeof createSyntheticGraph>,
  state: { pages: number; repeated: boolean; requested: string[] },
  link: string,
) =>
  interceptGraph(graph, (url) => {
    if (!url.includes('/delta')) {
      return undefined;
    }
    state.requested.push(url);
    if (!state.repeated) {
      return {
        status: 200,
        body: JSON.stringify({
          value: [],
          '@odata.deltaLink': link.replace(
            '$skiptoken=repeated',
            '$deltatoken=done',
          ),
        }),
      };
    }
    state.pages += 1;
    // A final refusal makes the unfenced implementation settle rather than hang this regression.
    return state.pages > 200
      ? { status: 503, body: '{}' }
      : {
          status: 200,
          body: JSON.stringify({ value: [], '@odata.nextLink': link }),
        };
  });

describe('reading Microsoft mail through Graph', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one synchronization path end to end. */
  it('keeps messages without a conversation identity separate and orders shared conversations after relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 4 });
    const native = {
      ...graph.native,
      graphRequest: async (
        url: string,
        scope: Parameters<typeof graph.native.graphRequest>[1],
      ) => {
        const reply = await graph.native.graphRequest(url, scope);
        return {
          ...reply,
          body: reply.body
            .replaceAll(
              '"conversationId":"conversation-1"',
              '"conversationId":""',
            )
            .replaceAll(
              '"conversationId":"conversation-2"',
              '"conversationId":""',
            )
            .replaceAll(
              '"conversationId":"conversation-4"',
              '"conversationId":"conversation-3"',
            ),
        };
      },
    };
    const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
    await inbox.load();
    const state = ready(inbox.getSnapshot());
    const [newest, earlier] = pair(state.messages);
    expect(threadMessages(state, newest.id).map(({ id }) => id)).toStrictEqual([
      newest.id,
      earlier.id,
    ]);
    for (const message of state.messages.slice(2)) {
      expect(threadMessages(state, message.id)).toStrictEqual([message]);
    }
    // An older cache may already contain blank identities; offline reopening must isolate them too.
    const reopened = createGmailInbox(
      {
        ...native,
        openMailbox: async () => {
          const cached = await native.openMailbox();
          return {
            ...cached,
            availability: 'retry',
            document: cached.document?.replaceAll(
              /"threadId":"AAMk[^"]+"/gu,
              '"threadId":""',
            ),
          };
        },
      },
      { provider: 'microsoft-graph' },
    );
    await reopened.load();
    expect(threadMessages(reopened.getSnapshot(), newest.id)).toStrictEqual(
      threadMessages(state, newest.id),
    );
    for (const message of ready(reopened.getSnapshot()).messages.slice(2)) {
      expect(threadMessages(reopened.getSnapshot(), message.id)).toStrictEqual([
        message,
      ]);
    }
  });

  it('bounds repeated delta continuation pages and resumes the saved checkpoint on retry', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 1 });
    const link =
      'https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?$skiptoken=repeated';
    const requested: string[] = [];
    const state = { pages: 0, repeated: true, requested };
    const native = repeatingDelta(graph, state, link);
    const inbox = createGmailInbox(native, { provider: 'microsoft-graph' });
    await inbox.load();
    expect(state.pages).toBeLessThanOrEqual(200);
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'retry',
      messages: [{ subject: 'Synthetic message 0' }],
    });
    expect(graph.commits.at(-1)).toContain(link);
    const completed = state.requested.length;
    state.repeated = false;
    const resumed = createGmailInbox(native, { provider: 'microsoft-graph' });
    await resumed.load();
    expect(state.requested[completed]).toBe(link);
    expect(ready(resumed.getSnapshot())).toMatchObject({
      sync: 'current',
      messages: [{ subject: 'Synthetic message 0' }],
    });
  });

  it('lists the Inbox, completes its delta round and applies later changes after relaunch', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 4, pageSize: 2 });
    const latest = graph.deliver({
      from: { name: 'Maya Chen', address: 'maya@example.invalid' },
      subject: 'Studio review',
      preview: 'Bring your notes',
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();

    const synced = ready(inbox.getSnapshot());
    expect(synced).toMatchObject({
      address: 'casey@example.invalid',
      sync: 'current',
    });
    expect(synced.messages).toHaveLength(5);
    expect(synced.messages[0]).toStrictEqual({
      id: latest,
      threadId: 'conversation-5',
      sender: 'Maya Chen',
      address: 'maya@example.invalid',
      subject: 'Studio review',
      preview: 'Bring your notes',
      receivedAt: expect.stringMatching(/^2026-09-01T\d\d:\d\d:00\.000Z$/u),
      unread: true,
      labels: ['INBOX', 'UNREAD'],
    });
    // Microsoft mail offers Graph's actions, without Gmail's star.
    expect(
      synced.messages
        .slice(0, 1)
        .flatMap((message) => quickActions(english, message, 'microsoft-graph'))
        .map(({ name }) => name),
    ).toStrictEqual(['read', 'archive', 'trash', 'spam']);
    // The Inbox shows after one list; the delta round walks every page, then the Inbox is
    // listed again so nothing changed during the round is missed, and the round's link finds
    // nothing newer.
    expect(reads(graph)).toStrictEqual([
      'list',
      'list',
      'list',
      'delta',
      'delta',
      'delta',
      'list',
      'list',
      'list',
      'changes',
    ]);
    expect(graph.commits.at(-1)).toContain('"kind":"graph-current"');

    const arrived = graph.deliver({ subject: 'New arrival' });
    const [, read = '', removed = ''] = synced.messages.map(({ id }) => id);
    graph.markRead(read);
    graph.remove(removed);
    graph.requests.length = 0;

    const relaunched = microsoftInbox(graph);
    await relaunched.load();
    const updated = ready(relaunched.getSnapshot());
    // One delta page carries every change; its new link then finds nothing newer.
    expect(reads(graph)).toStrictEqual([
      'changes',
      'message',
      'message',
      'message',
      'changes',
    ]);
    expect(updated.messages.map(({ id }) => id)).toContain(arrived);
    expect(updated.messages.map(({ id }) => id)).not.toContain(removed);
    expect(updated.messages.find(({ id }) => id === read)?.unread).toBe(false);
    expect(updated.messages).toHaveLength(5);

    // An unchanged Inbox returning the same link commits nothing.
    const commits = graph.commits.length;
    await relaunched.load();
    expect(graph.commits).toHaveLength(commits);
    expect(ready(relaunched.getSnapshot()).sync).toBe('current');

    // A fresh link from an empty round is saved, once per synchronization, and used next time.
    graph.rotateDelta();
    graph.requests.length = 0;
    await relaunched.load();
    expect(reads(graph)).toStrictEqual(['changes']);
    expect(graph.commits).toHaveLength(commits + 1);
    expect(graph.commits.at(-1)).toContain('$deltatoken=');
    expect(graph.commits.at(-1)).toContain('r1');
    await relaunched.load();
    expect(reads(graph)).toStrictEqual(['changes', 'changes']);
    expect(messageReads(graph).at(-1)?.searchParams.get('$deltatoken')).toMatch(
      /r1$/u,
    );
    expect(graph.commits).toHaveLength(commits + 2);
    expect(ready(relaunched.getSnapshot()).sync).toBe('current');
  });

  it('lists again when Graph expires the delta link, showing saved mail meanwhile', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 3, pageSize: 2 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const saved = ready(inbox.getSnapshot()).messages;
    graph.expireDelta();
    const arrived = graph.deliver({ subject: 'After expiry' });
    graph.requests.length = 0;
    const published: GmailInboxState[] = [];
    inbox.subscribe(() => {
      published.push(inbox.getSnapshot());
    });

    await inbox.load();
    expect(reads(graph)).toStrictEqual([
      'changes',
      'list',
      'list',
      'delta',
      'delta',
      'list',
      'list',
      'changes',
    ]);
    expect(published[0]).toMatchObject({ messages: saved, sync: 'syncing' });
    const relisted = ready(inbox.getSnapshot());
    expect(relisted.sync).toBe('current');
    expect(relisted.messages.map(({ id }) => id)).toStrictEqual([
      arrived,
      ...saved.map(({ id }) => id),
    ]);
  });

  it('fills a full cache again from Graph when a cached message leaves the Inbox', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 201, pageSize: 100 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const listed = ready(inbox.getSnapshot()).messages;
    expect(listed).toHaveLength(200);
    const [{ id: first } = { id: '' }] = listed;
    graph.remove(first);
    graph.requests.length = 0;

    await inbox.load();
    const refilled = ready(inbox.getSnapshot()).messages;
    expect(reads(graph)).toStrictEqual([
      'changes',
      'message',
      'list',
      'list',
      'changes',
    ]);
    expect(refilled).toHaveLength(200);
    expect(refilled.map(({ id }) => id)).not.toContain(first);
    // The oldest Inbox message, beyond the cache before, now fits.
    expect(refilled.at(-1)?.subject).toBe('Synthetic message 0');
  });

  it('reconciles partial and repeated delta identities against their current Inbox state', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 2 });
    let delta: readonly unknown[] | undefined = undefined;
    const inbox = createGmailInbox(
      interceptGraph(graph, (url) => {
        const reply = deltaReply(url, delta);
        delta = undefined;
        return reply;
      }),
      { provider: 'microsoft-graph' },
    );
    await inbox.load();
    const [read, removed] = pair(ready(inbox.getSnapshot()).messages);
    graph.markRead(read.id);
    graph.remove(removed.id);
    delta = [
      { id: read.id, isRead: true },
      {
        id: removed.id,
        receivedDateTime: removed.receivedAt,
        subject: 'Stale change',
      },
      { id: removed.id, '@removed': { reason: 'deleted' } },
    ];
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({ sync: 'current' });
    expect(ready(inbox.getSnapshot()).messages).toStrictEqual([
      { ...read, unread: false },
    ]);
  });

  it('reads an HTML body with its inline image, answers it, and downloads an attachment by its own size', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const logo = [...Buffer.from(png(40, 30), 'base64')];
    const notes = [...Buffer.from('Notes here.\n')];
    const id = graph.deliver({
      subject: 'Plans',
      body: {
        contentType: 'html',
        content: '<p>Garden plans ✿</p><img src="cid:logo@example" alt="Logo">',
      },
      attachments: [
        {
          name: 'logo.png',
          contentType: 'image/png',
          bytes: logo,
          isInline: true,
          contentId: 'logo@example',
        },
        { name: 'notes.txt', contentType: 'text/plain', bytes: notes },
      ],
      headers: [{ name: 'References', value: '<earlier@example.invalid>' }],
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);

    const body = rich(inbox.messageBody(id));
    expect(body.document).toContain('Garden plans ✿');
    expect(body.document).toContain('src="data:image/png;base64,');
    // The inline image is not offered as a file; Graph's approximate size is shown until download.
    expect(inbox.messageAttachments(id)).toStrictEqual([
      {
        locator: '0.1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: notes.length + 120,
        state: { kind: 'available' },
      },
    ]);
    expect(inbox.responseSource(id)?.headers).toStrictEqual({
      from: '"Rowan Hale" <rowan@example.invalid>',
      to: '"Casey" <casey@example.invalid>',
      messageId: `<${id}@example.invalid>`,
      references: '<earlier@example.invalid>',
    });

    await inbox.downloadAttachment(id, '0.1');
    expect(inbox.messageAttachments(id)?.[0]?.state).toStrictEqual({
      kind: 'downloaded',
    });
    expect([...graph.savedFiles.values()]).toStrictEqual([
      { name: 'notes.txt', bytes: Uint8Array.from(notes) },
    ]);
    close();
  });

  it('pages attachment metadata and downloads only visible inline references', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ pageSize: 1 });
    const image = [...Buffer.from(png(40, 30), 'base64')];
    const id = graph.deliver({
      body: {
        contentType: 'html',
        content:
          '<p>Visible</p><img hidden src="cid:hidden"><img src="cid:shown">',
      },
      attachments: [
        {
          name: 'hidden.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'hidden',
        },
        {
          name: 'unused.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'unused',
        },
        {
          name: 'shown.png',
          contentType: 'image/png',
          bytes: image,
          isInline: true,
          contentId: 'shown',
        },
        { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
      ],
    });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox.messageBody(id)).document).toContain(
      'data:image/png;base64,',
    );
    expect(
      graph.requests
        .filter((url) => /\/attachments\//u.test(url.pathname))
        .map((url) => url.pathname),
    ).toStrictEqual([`/v1.0/me/messages/${id}/attachments/${id}-attachment-2`]);
    expect(inbox.messageAttachments(id)?.map(({ name }) => name)).toStrictEqual(
      ['notes.txt'],
    );
    close();
  });

  it('keeps readable body text when an optional inline image is temporarily unavailable', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph();
    const id = graph.deliver({
      body: {
        contentType: 'html',
        content: '<p>Important text</p><img src="cid:logo">',
      },
      attachments: [
        {
          name: 'logo.png',
          contentType: 'image/png',
          bytes: [...Buffer.from(png(40, 30), 'base64')],
          isInline: true,
          contentId: 'logo',
        },
      ],
    });
    const inbox = createGmailInbox(interceptGraph(graph, unavailableImage), {
      provider: 'microsoft-graph',
    });
    await inbox.load();
    const close = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(rich(inbox.messageBody(id)).document).toContain('Important text');
    expect(rich(inbox.messageBody(id)).document).not.toContain(
      'data:image/png;base64,',
    );
    close();
  });

  it.each([503, 401])(
    'keeps text and retries attachment metadata after Graph responds %s',
    async (status) => {
      expect.hasAssertions();
      vi.useFakeTimers({ now: Date.UTC(2026, 8, 1, 1), toFake: ['Date'] });
      try {
        const graph = createSyntheticGraph();
        const id = graph.deliver({
          body: {
            contentType: 'text',
            content: 'Readable despite metadata failure',
          },
          attachments: [
            { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
          ],
        });
        const inbox = createGmailInbox(
          interceptGraph(graph, (url) => unavailableMetadata(url, status)),
          { provider: 'microsoft-graph' },
        );
        await inbox.load();
        const close = inbox.retainMessage(id);
        await inbox.readMessage(id);
        expect(inbox.messageBody(id)).toMatchObject({
          kind: 'ready',
          presentation: {
            readable: {
              paragraphs: [[{ text: 'Readable despite metadata failure' }]],
            },
          },
        });
        expect(ready(inbox.getSnapshot()).sync).toBe(metadataSync(status));
        close();
        inbox.forget();

        const relaunched = microsoftInbox(graph);
        await relaunched.load();
        const release = relaunched.retainMessage(id);
        await relaunched.readMessage(id);
        expect(relaunched.messageBody(id)).toMatchObject({
          kind: 'ready',
          presentation: {
            readable: {
              paragraphs: [[{ text: 'Readable despite metadata failure' }]],
            },
          },
        });
        expect(relaunched.messageAttachments(id)).toMatchObject([
          { name: 'notes.txt' },
        ]);
        release();
        relaunched.forget();
      } finally {
        vi.useRealTimers();
      }
    },
  );

  it.each([
    { status: 200, reason: 'failed', reply: () => undefined },
    {
      status: 401,
      reason: 'authentication',
      reply: (url: string) => unavailableMetadata(url, 401),
    },
    {
      status: 503,
      reason: 'failed',
      reply: (url: string) => unavailableMetadata(url, 503),
    },
  ])(
    'rejects oversized Graph metadata and preserves an attachment grant refusal ($status)',
    async ({ status, reason, reply }) => {
      expect.hasAssertions();
      const graph = createSyntheticGraph();
      const id = graph.deliver({
        body: { contentType: 'text', content: 'Over metadata budget' },
        headers: [{ name: 'References', value: 'x'.repeat(256 * 1024 + 1) }],
        attachments: [
          { name: 'notes.txt', contentType: 'text/plain', bytes: [65] },
        ],
      });
      const inbox = createGmailInbox(interceptGraph(graph, reply), {
        provider: 'microsoft-graph',
      });
      await inbox.load();
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      expect(inbox.messageBody(id)).toStrictEqual({
        kind: 'unavailable',
        reason,
      });
      expect(ready(inbox.getSnapshot()).sync).toBe(metadataSync(status));
      expect(graph.cachedBodies().has(id)).toBe(false);
      close();
      inbox.forget();
    },
  );

  it('asks for Microsoft authorization again when Graph refuses the grant', async () => {
    expect.hasAssertions();
    const graph = createSyntheticGraph({ messages: 2 });
    const inbox = microsoftInbox(graph);
    await inbox.load();
    graph.fail({ status: 401 });
    await inbox.load();
    expect(ready(inbox.getSnapshot())).toMatchObject({
      sync: 'authentication',
      messages: expect.any(Array),
    });
    expect(ready(inbox.getSnapshot()).messages).toHaveLength(2);
  });

  it('reports a refused Microsoft grant of the only connection as Microsoft mail being unavailable', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const registration = createRegistration(session.native);
    await registration.register('apple');
    await registration.addMailbox('microsoft-graph');
    session.expire('casey@example.invalid');
    await registration.restore();
    expect(registration.getSnapshot().snapshot).toMatchObject({
      kind: 'mailbox-needed',
      reason: 'microsoft-unavailable',
    });
  });

  it('shows Gmail and Microsoft mail together, searches both online and sends only from Gmail', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ address: 'other@example.invalid' });
    const graph = createSyntheticGraph();
    gmail.deliver({ subject: 'From Gmail', at: Date.UTC(2026, 8, 1, 9) });
    graph.deliver({ subject: 'From Outlook', at: Date.UTC(2026, 8, 1, 10) });
    const session = createMockRegistrationSession('registration-success');
    const registration = createRegistration(session.native);
    await registration.register('apple');
    // Microsoft mail can be the first mailbox, without any Gmail grant.
    await registration.addMailbox('microsoft-graph');
    expect(mailboxesOf(registration.getSnapshot().snapshot)).toStrictEqual([
      {
        id: syntheticMailboxes['casey@example.invalid'],
        provider: 'microsoft-graph',
        address: 'casey@example.invalid',
        state: 'connected',
        profile: defaultProfile,
      },
    ]);
    expect(
      registrationCopy(english, registration.getSnapshot().snapshot).title,
    ).toBe('Mail connected');
    await registration.addMailbox('gmail', true);
    const mailboxes = createMailboxes(
      syntheticConnections({
        [syntheticMailboxes['other@example.invalid']]: gmail,
        [syntheticMailboxes['casey@example.invalid']]: graph,
      }),
      registration,
    );
    await mailboxes.load();

    const shown = mailboxes.getSnapshot();
    expect(
      shown.map(({ provider, address }) => [provider, address]),
    ).toStrictEqual([
      ['microsoft-graph', 'casey@example.invalid'],
      ['gmail', 'other@example.invalid'],
    ]);
    expect(
      inboxMessages(shown, undefined).map(({ message }) => message.subject),
    ).toStrictEqual(['From Outlook', 'From Gmail']);

    const search = createGmailSearch(shown, 'From', undefined);
    await search.search();
    expect(search.getSnapshot().found?.failures).toStrictEqual([]);
    expect(
      search
        .getSnapshot()
        .found?.results.map(({ mailbox }) => mailbox.provider),
    ).toStrictEqual(['microsoft-graph', 'gmail']);
    // Graph searches every folder for the quoted query.
    expect(graph.searches).toStrictEqual(['"From"']);

    expect(
      sendingMailboxes(
        mailboxesOf(registration.getSnapshot().snapshot),
        defaultProfile,
      ).map(({ address }) => address),
    ).toStrictEqual(['other@example.invalid']);
    await expect(
      shown[0]?.inbox.send({ segments: [{ text: 'Hello' }] }),
    ).resolves.toStrictEqual({ kind: 'failed', problem: 'mailbox' });
  });
});
