import type {
  GmailInbox,
  MessageBodyState,
  NativeGmailMailbox,
} from '../src/gmail-inbox.ts';

import { createBodyLoads, createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

const bodyRequests = (gmail: ReturnType<typeof createSyntheticGmail>) =>
  gmail.requests.filter(({ query }) => query.get('format') === 'full');

const read = async (inbox: GmailInbox, id: string) => {
  await inbox.readMessage(id);
  return inbox.messageBody(id);
};

const ready = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready') {
    throw new Error(`Expected a ready body, received ${state?.kind}`);
  }
  return state.presentation;
};

const readyBody = (state: MessageBodyState | undefined) =>
  ready(state).readable;

const richDocument = (state: MessageBodyState | undefined) => {
  const { rich } = ready(state);
  if (rich === undefined) {
    throw new Error('Expected a rich presentation');
  }
  return rich;
};

const isFull = (query: Parameters<NativeGmailMailbox['gmailRequest']>[1]) =>
  query.some(([key, value]) => key === 'format' && value === 'full');

const substituteFull = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  reply: ReturnType<typeof createSyntheticGmail>['native']['gmailRequest'],
) => {
  const request = gmail.native.gmailRequest;
  gmail.native.gmailRequest = (...args) =>
    isFull(args[1]) ? reply(...args) : request(...args);
};

// Full-body replies wait until the test answers each one, recording the order Gmail was asked.
const controlledBodies = (gmail: ReturnType<typeof createSyntheticGmail>) => {
  const started: string[] = [];
  const replies = new Map<string, () => void>();
  const { gmailRequest } = gmail.native;
  substituteFull(gmail, async (...request) => {
    const id = request[0].slice('messages/'.length);
    started.push(id);
    const answered = Promise.withResolvers<undefined>();
    replies.set(id, () => {
      answered.resolve(undefined);
    });
    await answered.promise;
    return gmailRequest(...request);
  });
  const answer = async (id: string) => {
    await vi.waitFor(() => {
      expect(replies.has(id)).toBe(true);
    });
    replies.get(id)?.();
  };
  return { started, answer };
};

// Gmail replies whose HTML body sits under each message's number of related containers, built
// as text so the test itself never recurses.
const nestedReplies =
  (depths: ReadonlyMap<string, number>) => (path: string) => {
    const id = path.slice('messages/'.length);
    const depth = depths.get(id) ?? 0;
    const html = `{"mimeType":"text/html","body":{"size":4,"data":"${Buffer.from('Deep').toString('base64url')}"}}`;
    return Promise.resolve({
      status: 200,
      body: `{"id":"${id}","payload":${'{"mimeType":"multipart/related","parts":['.repeat(depth)}${html}${']}'.repeat(depth)}}`,
    });
  };

const resolveSecond = (active: number, resolve: (value: undefined) => void) => {
  if (active === 2) {
    resolve(undefined);
  }
};

// A lax host decoder that accepts any label and always decodes UTF-8.
const HostTextDecoder = TextDecoder;
class Utf8OnlyDecoder {
  readonly #decoder = new HostTextDecoder();
  public decode(bytes: Uint8Array) {
    return this.#decoder.decode(bytes);
  }
}

describe('reading Gmail message bodies', () => {
  // oxlint-disable-next-line vitest/no-hooks -- One test replaces the host decoder.
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one reading path end to end. */
  it('renders untrusted HTML as text with vetted links and reopens it offline from the cache', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      subject: 'Newsletter',
      content: {
        html: [
          '<!doctype html><html><head><title>Hidden title</title>',
          '<style>p { color: red }</style></head><body>',
          '<script>alert("x")</script>',
          '<p>Hello &amp; welcome&nbsp;&mdash; <b>friends</b>.</p>',
          '<p onclick="steal()">Read <a href="https://example.invalid/a?b=1&amp;c=2">the post</a>',
          ' or <a href="javascript:steal()">this</a>',
          ' or <a href="data:text/html,x">that</a>.</p>',
          '<img src="https://tracker.invalid/pixel.gif" alt="">',
          '<ul><li>One</li><li>Two<br>lines</li></ul>',
          '<style-card>Kept</style-card>',
          '<p><a title=" href=https://different.invalid " href="https://correct.invalid">Correct destination</a></p>',
          '<iframe src="https://example.invalid/frame">Frame text</iframe>',
          '</body></html>',
        ].join(''),
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();

    const opened = await read(inbox, id);
    const body = readyBody(opened);
    const { document, links } = richDocument(opened);
    // The isolated document forbids every load except app-generated images, and runs nothing.
    expect(document).toContain(
      `default-src 'none'; img-src data:; media-src 'none'; style-src 'unsafe-inline'`,
    );
    expect(document).not.toMatch(
      /<script|onclick|javascript:|data:text|tracker\.invalid|<iframe|Hidden title|color: red/u,
    );
    expect(document).toContain(
      '<a href="about:blank#unwired-link-0" rel="noreferrer noopener">the post</a>',
    );
    expect(links).toStrictEqual([
      { href: 'https://example.invalid/a?b=1&c=2', text: 'the post' },
      { href: 'https://correct.invalid', text: 'Correct destination' },
    ]);
    expect(body).toStrictEqual({
      paragraphs: [
        [{ text: 'Hello & welcome\u00A0— friends.' }],
        [
          { text: 'Read ' },
          { text: 'the post', href: 'https://example.invalid/a?b=1&c=2' },
          { text: ' or this or that.' },
        ],
        [{ text: '• One' }],
        [{ text: '• Two\nlines' }],
        // An element that merely starts with a hidden element's name keeps its text.
        [{ text: 'Kept' }],
        [{ text: 'Correct destination', href: 'https://correct.invalid' }],
      ],
      hidesImages: true,
    });
    // The image, frame and links were never requested; only Gmail was read.
    expect(gmail.requests.every(({ path }) => !path.includes('invalid'))).toBe(
      true,
    );
    expect(bodyRequests(gmail)).toHaveLength(1);
    expect(gmail.cachedBodies().has(id)).toBe(true);

    // Opening it again in this Inbox reads nothing more.
    await read(inbox, id);
    expect(bodyRequests(gmail)).toHaveLength(1);

    // After a relaunch without Gmail, the cached body opens and nothing is fetched.
    const relaunched = createGmailInbox(gmail.native);
    gmail.fail({ code: 'unavailable' });
    await relaunched.load();
    expect(relaunched.getSnapshot()).toMatchObject({ sync: 'retry' });
    expect(ready(await read(relaunched, id))).toStrictEqual(ready(opened));
    expect(bodyRequests(gmail)).toHaveLength(1);
  });

  it('decodes plain text, Latin-1 and separately served parts', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const plain = gmail.deliver({
      content: {
        text: 'Café at noon?\r\nDetails: https://example.invalid/menu.\r\n\r\nWrite to mailto:sam@example.invalid',
        charset: 'latin1',
        separate: true,
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    // The Mac host's decoder polyfill knows only UTF-8; Latin-1 must not depend on it.
    vi.stubGlobal('TextDecoder', Utf8OnlyDecoder);

    expect(readyBody(await read(inbox, plain))).toStrictEqual({
      paragraphs: [
        [
          { text: 'Café at noon?\nDetails: ' },
          {
            text: 'https://example.invalid/menu',
            href: 'https://example.invalid/menu',
          },
          { text: '.' },
        ],
        [
          { text: 'Write to ' },
          {
            text: 'mailto:sam@example.invalid',
            href: 'mailto:sam@example.invalid',
          },
        ],
      ],
      hidesImages: false,
    });
    // The part arrived through Gmail's attachments resource; the attached file was not fetched.
    expect(
      gmail.requests
        .map(({ path }) => path)
        .filter((path) => path.includes('/attachments/')),
    ).toStrictEqual([`messages/${plain}/attachments/part-0-0`]);
  });

  it('decodes Czech legacy charsets without the host decoder', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const czech = 'Příliš žluťoučký kůň úpěl ďábelské ódy.';
    const windows = gmail.deliver({
      content: { text: czech, charset: 'windows-1250' },
    });
    const iso = gmail.deliver({
      content: { html: `<p>${czech}</p>`, charset: 'iso-8859-2' },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    // Hosts may only know UTF-8: native Expo and the Mac host's decoder polyfill.
    vi.stubGlobal('TextDecoder', Utf8OnlyDecoder);

    expect(readyBody(await read(inbox, windows))).toStrictEqual({
      paragraphs: [[{ text: czech }]],
      hidesImages: false,
    });
    expect(readyBody(await read(inbox, iso))).toStrictEqual({
      paragraphs: [[{ text: czech }]],
      hidesImages: false,
    });
  });

  it('recognizes quoted reply history only where it ends the message', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const cited = gmail.deliver({
      content: {
        html: '<p>Sounds good.</p><blockquote type="cite"><p>Apple Mail quote</p></blockquote>',
      },
    });
    const outlook = gmail.deliver({
      content: {
        text: 'Approved.\n\n-----Original Message-----\nFrom: Maya\nPlease approve.',
      },
    });
    const onlyQuote = gmail.deliver({
      content: { text: 'On Monday, Maya wrote:\n> Everything here is quoted.' },
    });
    const interleaved = gmail.deliver({
      content: { text: '> Can you come?\nYes.\n> And bring notes?' },
    });
    const htmlOnlyQuote = gmail.deliver({
      content: {
        html: '<blockquote type="cite"><p>Everything here is quoted.</p></blockquote>',
      },
    });
    const htmlInterleaved = gmail.deliver({
      content: {
        html: '<blockquote type="cite"><p>Can you come?</p></blockquote><p>Yes.</p><blockquote type="cite"><p>And bring notes?</p></blockquote><p>I will.</p>',
      },
    });
    const imageReply = gmail.deliver({
      content: {
        html: '<p>Here is my reply.</p><blockquote type="cite"><p>Can you draw the layout?</p></blockquote><img src="https://images.invalid/layout.png" alt="My proposed layout">',
      },
    });
    const alternative = gmail.deliver({
      content: {
        html: '<p>OK.</p><div class="gmail_quote">Old reply</div>',
        text: 'OK.\n\nOld reply',
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const text = (state: MessageBodyState | undefined) =>
      ready(state)
        .withoutQuotedHistory?.readable.paragraphs.map((spans) =>
          spans.map((span) => span.text).join(''),
        )
        .join('\n\n');

    const reply = ready(await read(inbox, cited));
    expect(reply.rich?.document).toContain('Apple Mail quote');
    expect(reply.withoutQuotedHistory?.rich?.document).not.toContain(
      'Apple Mail quote',
    );
    expect(text(await read(inbox, cited))).toBe('Sounds good.');
    expect(text(await read(inbox, outlook))).toBe('Approved.');
    // Collapsing would leave nothing, and an inline reply keeps every answer beside its question.
    expect(
      ready(await read(inbox, onlyQuote)).withoutQuotedHistory,
    ).toBeUndefined();
    expect(
      ready(await read(inbox, interleaved)).withoutQuotedHistory,
    ).toBeUndefined();
    expect(
      ready(await read(inbox, htmlOnlyQuote)).withoutQuotedHistory,
    ).toBeUndefined();
    expect(
      ready(await read(inbox, htmlInterleaved)).withoutQuotedHistory,
    ).toBeUndefined();
    expect(
      ready(await read(inbox, imageReply)).withoutQuotedHistory,
    ).toBeUndefined();
    const withAlternative = ready(await read(inbox, alternative));
    inbox.discardRichMessage(alternative, withAlternative);
    expect(text(inbox.messageBody(alternative))).toBe('OK.');
  });

  it('reports bodies it cannot download and downloads them once Gmail allows it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const kept = gmail.deliver({ subject: 'Kept' });
    const removed = gmail.deliver({ subject: 'Removed in Gmail' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();

    gmail.fail({ code: 'unavailable' });
    await expect(read(inbox, kept)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'download',
    });
    const current = inbox.getSnapshot();
    expect(current).toMatchObject({ kind: 'ready', sync: 'current' });
    gmail.fail({ status: 401 });
    await expect(read(inbox, kept)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toStrictEqual({
      ...current,
      sync: 'authentication',
    });
    gmail.fail({ status: 500 });
    await expect(read(inbox, kept)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'download',
    });
    expect(gmail.cachedBodies().size).toBe(0);
    // A synchronization that reaches Gmail downloads the body it could not provide before.
    await inbox.load();
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });
    await vi.waitFor(() => {
      expect(inbox.messageBody(kept)?.kind).toBe('ready');
    });
    expect(readyBody(inbox.messageBody(kept)).paragraphs).toStrictEqual([
      [{ text: 'Synthetic snippet' }],
      [{ text: 'Synthetic body.' }],
    ]);

    gmail.remove(removed);
    await expect(read(inbox, removed)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'missing',
    });

    gmail.failBodyOpen('locked');
    const locked = createGmailInbox(gmail.native);
    await locked.load();
    await expect(read(locked, kept)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'locked',
    });
  });

  it('shares one download between windows and limits concurrent downloads', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const first = gmail.deliver();
    const ids = [first, gmail.deliver(), gmail.deliver()];
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    let active = 0;
    let most = 0;
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const { gmailRequest } = gmail.native;
    gmail.native.gmailRequest = async (...request) => {
      active += 1;
      most = Math.max(most, active);
      resolveSecond(active, started.resolve);
      await release.promise;
      active -= 1;
      return gmailRequest(...request);
    };

    const downloads = Promise.all([
      inbox.readMessage(first),
      inbox.readMessage(first),
      ...ids.map((id) => inbox.readMessage(id)),
    ]);
    await started.promise;
    release.resolve(undefined);
    await downloads;
    expect(bodyRequests(gmail)).toHaveLength(3);
    expect(most).toBe(2);
    expect(ids.map((id) => inbox.messageBody(id)?.kind)).toStrictEqual([
      'ready',
      'ready',
      'ready',
    ]);
  });

  it('starts waiting reads in the order a reader ranks them while other connections keep their loads', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const gmail = createSyntheticGmail();
    const oldest = gmail.deliver({ subject: 'Planning' });
    const reply = () =>
      gmail.deliver({ subject: 'Re: Planning', thread: oldest });
    const fifth = reply();
    const kept = reply();
    const third = reply();
    const second = reply();
    const newest = reply();
    const thread = [newest, second, third, kept, fifth, oldest];
    const inbox = createGmailInbox(gmail.native, { shared });
    await inbox.load();
    const { started, answer } = controlledBodies(gmail);
    const other = createSyntheticGmail({ address: 'sam@example.invalid' });
    const elsewhere = [other.deliver(), other.deliver()];
    const otherInbox = createGmailInbox(other.native, { shared });
    await otherInbox.load();
    const otherGmail = controlledBodies(other);

    // Opened newest first, the two newest bodies take the connection's two loads.
    const reads = thread.map((id) =>
      inbox.readMessage(id, { background: true }),
    );
    await vi.waitFor(() => {
      expect(started).toStrictEqual([newest, second]);
    });
    // The older chosen message overtakes the waiting newer ones once a load ends.
    const release = inbox.rankBodies(thread.toReversed());
    await answer(newest);
    await vi.waitFor(() => {
      expect(started).toStrictEqual([newest, second, oldest]);
    });
    // Scrolling ranks again before the next load ends.
    inbox.rankBodies([third, ...thread.filter((id) => id !== third)]);
    release();
    await answer(second);
    await vi.waitFor(() => {
      expect(started).toStrictEqual([newest, second, oldest, third]);
    });

    // Another connection still runs its own two loads beside this one's waiting reads.
    const otherReads = elsewhere.map((id) => otherInbox.readMessage(id));
    await vi.waitFor(() => {
      expect(otherGmail.started).toStrictEqual(elsewhere);
    });
    expect(started).toHaveLength(4);
    await Promise.all(elsewhere.map(otherGmail.answer));
    await Promise.all(otherReads);

    // A reader that retains a body while its background read waits keeps it; the rest are
    // brought onto this device only.
    inbox.retainMessage(kept);
    await Promise.all(thread.map(answer));
    await Promise.all(reads);
    expect(started.slice(4)).toStrictEqual([kept, fifth]);
    expect(thread.map((id) => inbox.messageBody(id)?.kind)).toStrictEqual([
      undefined,
      undefined,
      undefined,
      'ready',
      undefined,
      undefined,
    ]);
    expect([...gmail.cachedBodies().keys()].toSorted()).toStrictEqual(
      thread.toSorted(),
    );
    expect(
      elsewhere.map((id) => otherInbox.messageBody(id)?.kind),
    ).toStrictEqual(['ready', 'ready']);
  });

  it('reprioritizes reads still waiting for account capacity without reserving connection slots', async () => {
    expect.hasAssertions();
    const shared = createBodyLoads();
    const mailbox = async (address: string) => {
      const gmail = createSyntheticGmail({ address });
      const ids: readonly [string, string, string] = [
        gmail.deliver(),
        gmail.deliver(),
        gmail.deliver(),
      ];
      const inbox = createGmailInbox(gmail.native, { shared });
      await inbox.load();
      return { inbox, ids, ...controlledBodies(gmail) };
    };
    const first = await mailbox('first@example.invalid');
    const second = await mailbox('second@example.invalid');
    const waiting = await mailbox('waiting@example.invalid');
    const firstReads = first.ids
      .slice(0, 2)
      .map((id) => first.inbox.readMessage(id));
    const secondReads = second.ids
      .slice(0, 2)
      .map((id) => second.inbox.readMessage(id));
    await vi.waitFor(() => {
      expect(first.started).toHaveLength(2);
      expect(second.started).toHaveLength(2);
    });
    const waitingReads = waiting.ids.map((id) => waiting.inbox.readMessage(id));
    const reversed = waiting.ids.toReversed();
    waiting.inbox.rankBodies(reversed);
    await first.answer(first.ids[0]);
    await firstReads[0];
    await vi.waitFor(() => {
      expect(waiting.started).toStrictEqual(reversed.slice(0, 1));
    });
    await first.answer(first.ids[1]);
    await firstReads[1];
    await vi.waitFor(() => {
      expect(waiting.started).toStrictEqual(reversed.slice(0, 2));
    });
    // A third free account slot must remain available to another connection.
    const lastFirstRead = first.inbox.readMessage(first.ids[2]);
    await second.answer(second.ids[0]);
    await secondReads[0];
    await vi.waitFor(() => {
      expect(first.started).toHaveLength(3);
    });
    expect(waiting.started).toHaveLength(2);
    await Promise.all([
      first.answer(first.ids[2]),
      second.answer(second.ids[1]),
      ...reversed.map(waiting.answer),
    ]);
    await Promise.all([
      ...firstReads,
      ...secondReads,
      ...waitingReads,
      lastFirstRead,
    ]);
  });

  it('gives the current Thread priority over background reads from a closed Thread', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const first = gmail.deliver();
    const second = gmail.deliver();
    const old = [first, second, gmail.deliver(), gmail.deliver()];
    const current = gmail.deliver();
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const { started, answer } = controlledBodies(gmail);
    const release = inbox.rankBodies(old);
    const reads = old.map((id) => inbox.readMessage(id, { background: true }));
    await vi.waitFor(() => {
      expect(started).toStrictEqual([first, second]);
    });
    release();
    inbox.rankBodies([current]);
    const currentRead = inbox.readMessage(current, { background: true });
    await answer(first);
    await reads[0];
    await vi.waitFor(() => {
      expect(started).toStrictEqual([first, second, current]);
    });
    await Promise.all([
      answer(second),
      answer(current),
      ...old.slice(2).map(answer),
    ]);
    await Promise.all([...reads, currentRead]);
  });

  it('keeps each body with its message, mailbox and owner', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const archived = gmail.deliver({ subject: 'Archived later' });
    const other = gmail.deliver({ subject: 'Other' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await read(inbox, archived);
    await read(inbox, other);
    expect([...gmail.cachedBodies().keys()].toSorted()).toStrictEqual(
      [archived, other].toSorted(),
    );

    // A body cached under another message's ID is never shown for this one.
    const otherDocument = String(gmail.cachedBodies().get(other));
    await gmail.native.commitMessageBody(
      { address: 'alex@example.invalid', generation: '0' },
      archived,
      { document: otherDocument, tier: 'opened', protectedIds: [] },
    );
    const reopened = createGmailInbox(gmail.native);
    await reopened.load();
    expect(readyBody(await read(reopened, archived)).paragraphs).toContainEqual(
      [{ text: 'Synthetic body.' }],
    );
    expect(gmail.cachedBodies().get(archived)).not.toBe(otherDocument);

    // A message that leaves the Inbox takes its cached body with it.
    gmail.archive(archived);
    await reopened.load();
    expect([...gmail.cachedBodies().keys()]).toStrictEqual([other]);

    // Only listed messages are read.
    const fresh = createGmailInbox(gmail.native);
    await fresh.load();
    await fresh.readMessage(archived);
    expect(fresh.messageBody(archived)).toBeUndefined();
    expect([...gmail.cachedBodies().keys()]).toStrictEqual([other]);

    // A read finishing after the open Inbox closed is dropped, and the closed Inbox's bodies go.
    const pending = reopened.readMessage(other);
    expect(reopened.messageBody(other)).toStrictEqual({ kind: 'loading' });
    reopened.forget();
    await pending;
    expect(reopened.messageBody(archived)).toBeUndefined();
    expect(reopened.messageBody(other)).toBeUndefined();

    // Another mailbox never sees the previous mailbox's bodies.
    gmail.reselect('sam@example.invalid');
    const next = gmail.deliver({ subject: 'New mailbox' });
    await reopened.load();
    expect(gmail.cachedBodies().size).toBe(0);
    expect(readyBody(await read(reopened, next)).paragraphs).toHaveLength(2);
  });

  it('rejects incomplete content and malformed bridge replies, and recovers without keeping an empty body', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ content: { text: 'Complete café.' } });
    let openBody: NativeGmailMailbox['openMessageBody'] = () =>
      Promise.resolve({ wrongField: 'malformed' });
    const inbox = createGmailInbox({
      ...gmail.native,
      gmailRequest: (...args) => gmail.native.gmailRequest(...args),
      openMessageBody: (...args) => openBody(...args),
    });
    await inbox.load();
    const { gmailRequest } = gmail.native;
    await expect(read(inbox, id)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'failed',
    });
    expect(bodyRequests(gmail)).toHaveLength(0);
    openBody = gmail.native.openMessageBody;
    const incomplete = [
      { size: 44 },
      { size: 44, data: Buffer.from('Partial').toString('base64url') },
    ];
    for (const body of incomplete) {
      substituteFull(gmail, () =>
        Promise.resolve({
          status: 200,
          body: JSON.stringify({
            id,
            payload: { mimeType: 'text/plain', body },
          }),
        }),
      );
      await expect(read(inbox, id)).resolves.toStrictEqual({
        kind: 'unavailable',
        reason: 'download',
      });
      expect(gmail.cachedBodies().size).toBe(0);
    }
    gmail.native.gmailRequest = gmailRequest;
    expect(readyBody(await read(inbox, id)).paragraphs).toStrictEqual([
      [{ text: 'Complete café.' }],
    ]);
  });

  it('reads only recognized multipart containers for the body', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const extension = gmail.deliver();
    const signed = gmail.deliver();
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const part = (mimeType: string, text: string) => ({
      mimeType,
      body: {
        size: Buffer.byteLength(text),
        data: Buffer.from(text).toString('base64url'),
      },
    });
    const payloads = new Map<string, unknown>([
      [
        extension,
        {
          mimeType: 'multipart/mixed',
          parts: [
            part('text/plain', 'Outer message.'),
            {
              mimeType: 'multipart/x-folder',
              parts: [part('text/html', '<p>Extension content.</p>')],
            },
          ],
        },
      ],
      [
        signed,
        {
          mimeType: 'multipart/signed',
          parts: [
            part('text/plain', 'Signed message.'),
            part('application/pkcs7-signature', 'signature'),
          ],
        },
      ],
    ]);
    const { gmailRequest } = gmail.native;
    substituteFull(gmail, (path) =>
      Promise.resolve({
        status: 200,
        body: JSON.stringify({
          id: path.slice('messages/'.length),
          payload: payloads.get(path.slice('messages/'.length)),
        }),
      }),
    );
    const extensionBody = ready(await read(inbox, extension));
    const signedBody = readyBody(await read(inbox, signed));
    gmail.native.gmailRequest = gmailRequest;
    // The extension container's HTML is neither rendered nor read as text.
    expect(extensionBody.rich).toBeUndefined();
    expect(extensionBody.readable.paragraphs).toStrictEqual([
      [{ text: 'Outer message.' }],
    ]);
    expect(signedBody.paragraphs).toStrictEqual([
      [{ text: 'Signed message.' }],
    ]);
  });

  it('settles a message nested too deeply to read instead of exhausting the stack', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const shallow = gmail.deliver();
    const deep = gmail.deliver();
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    substituteFull(
      gmail,
      nestedReplies(
        new Map([
          [shallow, 32],
          [deep, 100_000],
        ]),
      ),
    );
    expect(readyBody(await read(inbox, shallow)).paragraphs).toStrictEqual([
      [{ text: 'Deep' }],
    ]);
    await expect(read(inbox, deep)).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'download',
    });
  });

  it('fails a message whose MIME metadata exceeds its budgets and reads one within them promptly', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const text = (headers: ReadonlyArray<{ name: string; value: string }>) => ({
      mimeType: 'text/plain',
      headers,
      body: { size: 7, data: Buffer.from('Bounded').toString('base64url') },
    });
    const value = 256 * 1024;
    const payloads = new Map<string, unknown>([
      [
        gmail.deliver(),
        {
          mimeType: 'multipart/mixed',
          parts: [50_000, 50_001].map((length) =>
            text(Array.from({ length }, () => ({ name: 'X-A', value: '' }))),
          ),
        },
      ],
      [gmail.deliver(), text([{ name: 'X'.repeat(999), value: '' }])],
      [gmail.deliver(), text([{ name: 'X-A', value: 'a'.repeat(value + 1) }])],
      [
        gmail.deliver(),
        {
          mimeType: 'multipart/mixed',
          parts: [
            text([]),
            {
              mimeType: 'message/rfc822',
              parts: [
                text([{ name: 'Content-ID', value: `<${'a'.repeat(997)}>` }]),
              ],
            },
          ],
        },
      ],
      [gmail.deliver(), { ...text([]), mimeType: `text/${'a'.repeat(251)}` }],
      [
        gmail.deliver(),
        {
          mimeType: 'multipart/mixed',
          parts: Array.from({ length: 17 }, () =>
            text([{ name: 'X-A', value: 'a'.repeat(value) }]),
          ),
        },
      ],
    ]);
    // A Content-Type at the value budget whose quoted string never closes. Measure the read
    // explicitly: a synchronous parser stall can prevent the test timeout from firing.
    const bounded = gmail.deliver();
    const prefix = 'text/plain; x=';
    payloads.set(
      bounded,
      text([
        {
          name: 'Content-Type',
          value: prefix + '"\\'.repeat((value - prefix.length) / 2),
        },
      ]),
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    substituteFull(gmail, (path) => {
      const id = path.slice('messages/'.length);
      return Promise.resolve({
        status: 200,
        body: JSON.stringify({ id, payload: payloads.get(id) }),
      });
    });
    for (const id of [...payloads.keys()].filter((key) => key !== bounded)) {
      await expect(read(inbox, id)).resolves.toStrictEqual({
        kind: 'unavailable',
        reason: 'failed',
      });
    }
    const started = performance.now();
    const body = await read(inbox, bounded);
    expect(performance.now() - started).toBeLessThan(5000);
    expect(readyBody(body).paragraphs).toStrictEqual([[{ text: 'Bounded' }]]);
  });

  it('keeps forwarded attachments out of the body and falls back to readable plain alternatives', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const original = gmail.deliver();
    const fallback = gmail.deliver({
      content: {
        text: 'Readable alternative.',
        html: '<script>hidden()</script>',
      },
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const part = (mimeType: string, text: string) => ({
      mimeType,
      body: {
        size: Buffer.byteLength(text),
        data: Buffer.from(text).toString('base64url'),
      },
    });
    const { gmailRequest } = gmail.native;
    substituteFull(gmail, () =>
      Promise.resolve({
        status: 200,
        body: JSON.stringify({
          id: original,
          payload: {
            mimeType: 'multipart/mixed',
            parts: [
              part('text/plain', 'Outer message.'),
              {
                mimeType: 'message/rfc822',
                parts: [part('text/html', '<p>Forwarded attachment.</p>')],
              },
            ],
          },
        }),
      }),
    );
    const originalBody = readyBody(await read(inbox, original));
    gmail.native.gmailRequest = gmailRequest;
    expect(originalBody.paragraphs).toStrictEqual([
      [{ text: 'Outer message.' }],
    ]);
    expect(readyBody(await read(inbox, fallback)).paragraphs).toStrictEqual([
      [{ text: 'Readable alternative.' }],
    ]);
  });

  it('does not repopulate a removed message after its download finishes', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver();
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const started = Promise.withResolvers<undefined>();
    const release = Promise.withResolvers<undefined>();
    const { gmailRequest } = gmail.native;
    substituteFull(gmail, async (...request) => {
      const reply = await gmailRequest(...request);
      started.resolve(undefined);
      await release.promise;
      return reply;
    });
    const pending = inbox.readMessage(id);
    await started.promise;
    gmail.archive(id);
    await inbox.load();
    release.resolve(undefined);
    await pending;
    expect(gmail.cachedBodies().size).toBe(0);
    expect(inbox.messageBody(id)).toBeUndefined();
  });

  it('keeps displayed bodies available while other windows read more mail', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const ids = Array.from({ length: 24 }, () => gmail.deliver());
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const first = String(ids[0]);
    const release = inbox.retainMessage(first);
    for (const id of ids) {
      await read(inbox, id);
    }
    expect(inbox.messageBody(first)?.kind).toBe('ready');
    release();
  });
  /* oxlint-enable vitest/max-expects */
});
