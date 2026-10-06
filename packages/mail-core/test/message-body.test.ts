import type {
  GmailInbox,
  MessageBodyState,
  NativeGmailMailbox,
} from '../src/gmail-inbox.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
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
