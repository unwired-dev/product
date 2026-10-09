import { deflateSync } from 'node:zlib';

import { english } from '@private-email/localization';

import type { RegistrationSnapshot } from '../src/registration.ts';
import type { ResponseKind } from '../src/responses.ts';
import type { Asset } from '../src/semantic-document.ts';

import { createComposerNavigation } from '../src/composer-navigation.ts';
import {
  assetsOf,
  createDrafts,
  draftOf,
  isEmptyDraft,
  unsendableAssets,
  recipientsOf,
  withSender,
} from '../src/drafts.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { attachmentLimit } from '../src/message-body.ts';
import { respond, startResponse } from '../src/responses.ts';
import {
  emptyDocument,
  imageCharacter,
  plainText,
} from '../src/semantic-document.ts';
import { createSyntheticDrafts } from '../src/testing/drafts.ts';
import {
  createSyntheticGmail,
  notesText,
} from '../src/testing/gmail-mailbox.ts';

// Two Mailbox Connections of one Product Account; mail is received in the second.
const alex = { id: 'connection-alex', address: 'alex@example.invalid' };
const work = { id: 'connection-work', address: 'alex.work@example.invalid' };

const connected = (
  mailboxes: ReadonlyArray<
    Readonly<{ id: string; address: string; state?: 'authorization' }>
  > = [alex, work],
): Extract<RegistrationSnapshot, { readonly kind: 'connected' }> => ({
  kind: 'connected',
  productAccountId: 'account-a',
  signInProvider: 'google',
  mailboxes: JSON.stringify(
    mailboxes.map(({ id, address, state = 'connected' }) => ({
      id,
      address,
      state,
    })),
  ),
});

const registrationOf = (initial: RegistrationSnapshot) => {
  let snapshot = initial;
  const listeners = new Set<() => void>();
  return {
    getSnapshot: () => ({ snapshot, busy: false, failed: false }),
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    replace: (next: RegistrationSnapshot) => {
      snapshot = next;
      for (const listener of listeners) {
        listener();
      }
    },
  };
};

const present = <T>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`Expected ${what}`);
  }
  return value;
};

// A complete asset's verified fields, or a failed test.
const completed = (asset: Asset | undefined) => {
  if (asset?.state !== 'complete') {
    throw new Error('Expected a complete asset');
  }
  return asset;
};

/* oxlint-disable no-bitwise -- PNG checksums, as in the rich reader tests. */
const u32 = (value: number) => [
  (value >>> 24) & 255,
  (value >>> 16) & 255,
  (value >>> 8) & 255,
  value & 255,
];
const crc32 = (bytes: readonly number[]) => {
  let crc = 4_294_967_295;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 0 ? 0 : 3_988_292_384);
    }
  }
  return (crc ^ 4_294_967_295) >>> 0;
};
/* oxlint-enable no-bitwise */
const ascii = (text: string) => [...text].map((ch) => ch.codePointAt(0) ?? 0);
const chunk = (type: string, data: readonly number[]) => {
  const content = [...ascii(type), ...data];
  return [...u32(data.length), ...content, ...u32(crc32(content))];
};
const logo = [
  ...ascii('\u0089PNG\r\n\u001A\n'),
  ...chunk('IHDR', [...u32(4), ...u32(3), 8, 6, 0, 0, 0]),
  ...chunk('IDAT', [...deflateSync(Buffer.alloc((4 * 4 + 1) * 3))]),
  ...chunk('IEND', []),
];
const report = [...Buffer.from('%PDF-1.7 synthetic report')];

const headers = {
  To: 'Alex Work <ALEX.WORK@example.invalid>, Bob <bob@example.invalid>, alex@example.invalid',
  Cc: '"Doe, Jane" <jane@example.invalid>, bob@example.invalid, Team: carol@example.invalid, not an address;, undisclosed-recipients:;',
  'Reply-To': 'Maya Lists <maya.lists@example.invalid>',
  'Message-ID': '<m2@example.invalid>',
  References: '<m0@example.invalid> <m1@example.invalid>',
};

// The reader's Inbox in the `work` mailbox with one opened message, and the Draft store beside it.
async function reader(
  delivered: Parameters<
    ReturnType<typeof createSyntheticGmail>['deliver']
  >[0] = {},
  snapshot = connected(),
) {
  const gmail = createSyntheticGmail({ address: work.address });
  const id = gmail.deliver({
    subject: 'Plans',
    content: { text: 'First line\nSecond line\n\nNext paragraph' },
    headers,
    ...delivered,
  });
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const close = inbox.retainMessage(id);
  await inbox.readMessage(id);
  const registration = registrationOf(snapshot);
  const storage = createSyntheticDrafts(() => {
    const current = registration.getSnapshot().snapshot;
    return current.kind === 'connected' ? current.productAccountId : undefined;
  });
  const drafts = createDrafts(storage.native, registration);
  await drafts.load();
  const navigation = createComposerNavigation();
  const state = inbox.getSnapshot();
  const message = present(
    state.kind === 'ready'
      ? state.messages.find((each) => each.id === id)
      : undefined,
    'the listed message',
  );
  const start = (kind: ResponseKind, mailbox = work) =>
    startResponse({ navigation, drafts, inbox }, english, {
      kind,
      mailbox,
      message,
      received: 'Sep 1, 2026',
      mailboxes: [alex, work],
    });
  const draft = (draftId: string | undefined) =>
    present(
      draftOf(drafts.getSnapshot(), present(draftId, 'a new Draft')),
      'the Draft',
    );
  return {
    gmail,
    id,
    inbox,
    close,
    storage,
    registration,
    navigation,
    drafts,
    message,
    start,
    draft,
  };
}

describe('replying to and forwarding a received message', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one response path end to end. */
  it('replies from the receiving identity with threading headers and quoted text apart from the body', async () => {
    expect.hasAssertions();
    const { message, start, draft, drafts, storage, registration } =
      await reader();

    const reply = draft(await start('reply'));
    // The receiving identity, not the first or default mailbox, sends the reply.
    expect(reply).toMatchObject({
      connection: work.id,
      from: work.address,
      to: [{ name: 'Maya Lists', address: 'maya.lists@example.invalid' }],
      cc: [],
      bcc: [],
      subject: 'Re: Plans',
      body: emptyDocument,
      response: {
        kind: 'reply',
        message: message.id,
        thread: message.threadId,
        inReplyTo: '<m2@example.invalid>',
        references: [
          '<m0@example.invalid>',
          '<m1@example.invalid>',
          '<m2@example.invalid>',
        ],
      },
    });
    expect(plainText(present(reply.quoted, 'quoted text'))).toBe(
      [
        'On Sep 1, 2026, Maya Chen <maya@example.invalid> wrote:',
        'First line',
        'Second line',
        '',
        'Next paragraph',
      ].join('\n'),
    );
    expect(reply.quoted?.slice(1).every(({ kind }) => kind === 'quote')).toBe(
      true,
    );

    // Reply All keeps external recipients once, without either identity of this account.
    const all = draft(await start('replyAll'));
    expect(all.to.map(({ address }) => address)).toStrictEqual([
      'maya.lists@example.invalid',
      'bob@example.invalid',
    ]);
    expect(all.cc).toStrictEqual([
      { name: 'Doe, Jane', address: 'jane@example.invalid' },
      { address: 'carol@example.invalid' },
    ]);
    expect(all.response?.kind).toBe('replyAll');

    // Editing keeps the response apart from the authored body, through a save and a reopen.
    await drafts.update(
      {
        ...all,
        body: [{ kind: 'paragraph', spans: [{ text: 'Sounds good.' }] }],
      },
      all,
    );
    await expect(drafts.save()).resolves.toBe(true);
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const kept = present(draftOf(reopened.getSnapshot(), all.id), 'reopened');
    expect(plainText(kept.body)).toBe('Sounds good.');
    expect(kept.quoted).toStrictEqual(all.quoted);
    expect(kept.response).toStrictEqual(all.response);
    // Nothing was sent: the Draft stays a Draft.
    expect(isEmptyDraft({ ...kept, to: [], cc: [], subject: '' })).toBe(false);

    // Explicitly sending from another mailbox keeps the threading headers but not the receiving
    // mailbox's Gmail thread.
    expect(withSender(kept, alex)).toMatchObject({
      connection: alex.id,
      from: alex.address,
      response: {
        kind: 'replyAll',
        inReplyTo: '<m2@example.invalid>',
        references: [
          '<m0@example.invalid>',
          '<m1@example.invalid>',
          '<m2@example.invalid>',
        ],
      },
    });
    expect(withSender(kept, alex).response).not.toHaveProperty('thread');
  });

  it('answers a message this mailbox sent to its original recipients, and tolerates malformed headers', () => {
    expect.hasAssertions();
    const prepare = (file: Readonly<{ name: string; type: string }>) => ({
      id: 'asset0000000000',
      ...file,
      state: 'importing' as const,
    });
    const answer = (
      kind: ResponseKind,
      sent: Readonly<Record<string, string>>,
    ) =>
      respond(english, kind, {
        message: {
          id: 'm1',
          threadId: 't1',
          subject: 'RE: Plans',
          sender: 'Maya',
        },
        document: { version: 2, id: 'm1', text: 'Body', headers: sent },
        from: work.address,
        received: 'today',
        prepare,
      }).edit({
        id: 'draft',
        connection: work.id,
        from: work.address,
        to: [],
        cc: [],
        bcc: [],
        subject: '',
        body: emptyDocument,
        updatedAt: 0,
      });

    // Sent by this mailbox: Reply goes to the original recipients, not back to itself.
    const ownMessage = answer('reply', {
      from: `Alex <${work.address}>`,
      to: 'bob@example.invalid',
    });
    expect(ownMessage.to).toStrictEqual([{ address: 'bob@example.invalid' }]);
    // An existing reply prefix is not repeated, in any case.
    expect(ownMessage.subject).toBe('RE: Plans');
    // A message sent only to oneself is still answered to oneself.
    expect(
      answer('replyAll', { from: work.address, to: work.address }).to,
    ).toStrictEqual([{ address: work.address }]);
    expect(
      answer('replyAll', {
        from: work.address,
        to: work.address,
        cc: 'bob@example.invalid',
      }).to,
    ).toStrictEqual([]);
    expect(
      recipientsOf(
        'Bob (friend, not a recipient) <bob@example.invalid>, "Friends" (team): carol@example.invalid, jane@example.invalid;',
      ),
    ).toStrictEqual([
      { name: 'Bob', address: 'bob@example.invalid' },
      { address: 'carol@example.invalid' },
      { address: 'jane@example.invalid' },
    ]);
    expect(
      answer('reply', {
        from: 'wrong@example.invalid',
        replyTo: 'bob@example.invalid (Bob)',
        messageId: '(comment <wrong@example.invalid>) <real@example.invalid>',
        references: '<real@example.invalid> <older@example.invalid>',
      }),
    ).toMatchObject({
      to: [{ address: 'bob@example.invalid' }],
      response: {
        inReplyTo: '<real@example.invalid>',
        references: ['<older@example.invalid>', '<real@example.invalid>'],
      },
    });

    // Unparseable senders and recipients leave the fields for the person to fill, never with
    // this mailbox's own address or a header's raw text.
    const malformed = answer('replyAll', {
      from: 'Maya (no address)',
      to: `${work.address}, <broken, "unterminated`,
      cc: ';;,',
      messageId: 'no-brackets',
      references: '<a@x> junk <b@x>',
    });
    expect(malformed.to).toStrictEqual([]);
    expect(malformed.cc).toStrictEqual([]);
    expect(malformed.response).toStrictEqual({
      kind: 'replyAll',
      message: 'm1',
      thread: 't1',
      references: ['<a@x>', '<b@x>'],
    });
  });

  it('forwards text, inline images and attachments with verified bytes, failing only what cannot be copied', async () => {
    expect.hasAssertions();
    const { id, start, draft, storage, gmail, drafts } = await reader({
      subject: 'Fwd: Report',
      content: {
        html: '<p>See the chart</p><img src="cid:chart@example" alt="chart"><p>Between charts</p><img src="cid:chart@example" alt="chart"><p>After charts</p>',
        images: [
          { contentId: 'chart@example', mimeType: 'image/png', bytes: logo },
        ],
        attachments: [
          {
            filename: 'report.pdf',
            mimeType: 'application/pdf',
            bytes: report,
          },
          {
            filename: 'huge.bin',
            mimeType: 'application/octet-stream',
            bytes: [1],
            size: attachmentLimit + 1,
          },
          {
            filename: 'broken.bin',
            mimeType: 'application/octet-stream',
            bytes: [1, 2, 3],
            size: 9,
          },
        ],
      },
    });

    // Native Draft storage reads the Downloaded Attachments that Gmail's mailbox saved.
    storage.holdImports();
    const forward = draft(await start('forward'));
    for (const [file, { bytes }] of gmail.savedFiles) {
      storage.addFile(file, String.fromCodePoint(...bytes));
    }
    storage.releaseImports();
    expect(forward).toMatchObject({
      connection: work.id,
      from: work.address,
      to: [],
      cc: [],
      subject: 'Fwd: Report',
      body: emptyDocument,
    });
    expect(forward.response).toStrictEqual({ kind: 'forward', message: id });
    const quoted = present(forward.quoted, 'forwarded content');
    expect(plainText(quoted)).toContain(
      '---------- Forwarded message ---------',
    );
    expect(plainText(quoted)).toContain(
      'From: Maya Chen <maya@example.invalid>',
    );
    expect(plainText(quoted)).toContain(`To: ${headers.To}`);
    expect(plainText(quoted)).toContain('See the chart');
    expect(
      quoted
        .slice(-5)
        .map(({ spans }) => spans.map(({ text }) => text).join('')),
    ).toStrictEqual([
      'See the chart',
      imageCharacter,
      'Between charts',
      imageCharacter,
      'After charts',
    ]);

    await vi.waitFor(() => {
      expect(
        assetsOf(draft(forward.id)).every(({ state }) => state !== 'importing'),
      ).toBe(true);
    });
    const settled = draft(forward.id);
    const attached = present(settled.attachments, 'forwarded attachments');
    expect(attached.map(({ name, state }) => ({ name, state }))).toStrictEqual([
      { name: 'notes.txt', state: 'complete' },
      { name: 'report.pdf', state: 'complete' },
      { name: 'huge.bin', state: 'failed' },
      { name: 'broken.bin', state: 'failed' },
    ]);
    expect(attached[2]).toMatchObject({ reason: 'too-large' });
    expect(unsendableAssets(settled).map(({ name }) => name)).toStrictEqual([
      'huge.bin',
      'broken.bin',
    ]);
    // Each copied file and the inline image read back as the received bytes.
    const [notes, pdf] = attached;
    const image = assetsOf(settled).at(-1);
    expect(image).toMatchObject({ type: 'image/png', state: 'complete' });
    for (const [asset, bytes] of [
      [notes, [...Buffer.from(notesText)]],
      [pdf, report],
      [image, logo],
    ] as const) {
      const complete = completed(asset);
      await expect(drafts.readAsset(complete)).resolves.toStrictEqual({
        kind: 'ready',
        uri: `data:${complete.type};base64,${Buffer.from(bytes).toString('base64')}`,
      });
    }
    // The stored Draft names neither the received mailbox's files nor the message's body cache.
    await expect(drafts.save()).resolves.toBe(true);
    const stored = present(storage.stored(), 'stored Drafts').document;
    for (const name of gmail.savedFiles.keys()) {
      expect(stored).not.toContain(name);
    }
  });

  it('never answers from another mailbox, and needs the opened message first', async () => {
    expect.hasAssertions();
    // The receiving mailbox waits for Gmail authorization on this device, so it cannot send.
    const waiting = await reader(
      {},
      connected([alex, { ...work, state: 'authorization' }]),
    );
    await expect(waiting.start('reply')).resolves.toBeUndefined();
    expect(waiting.drafts.getSnapshot()).toMatchObject({ drafts: [] });

    // A message whose reader closed has no response source.
    const { close, start, drafts } = await reader();
    await expect(start('reply', alex)).resolves.toBeUndefined();
    close();
    await expect(start('reply')).resolves.toBeUndefined();
    expect(drafts.getSnapshot()).toMatchObject({ drafts: [] });
  });

  it('preserves another editor’s content while response creation waits for storage', async () => {
    expect.hasAssertions();
    const { start, drafts, storage } = await reader();
    storage.hold();
    const pending = start('reply');
    await vi.waitFor(() =>
      expect(drafts.getSnapshot()).toMatchObject({ drafts: [{ subject: '' }] }),
    );
    const state = drafts.getSnapshot();
    const existing = present(
      // oxlint-disable-next-line vitest/no-conditional-in-test -- Narrows the public store snapshot.
      state.kind === 'ready' ? state.drafts[0] : undefined,
      'new row',
    );
    const editing = drafts.update(
      {
        ...existing,
        subject: 'My work',
        to: [{ address: 'bob@example.invalid' }],
      },
      existing,
    );
    storage.release();
    await editing;
    await expect(pending).resolves.toBeUndefined();
    expect(drafts.getSnapshot()).toMatchObject({
      drafts: [
        { subject: 'My work', to: [{ address: 'bob@example.invalid' }] },
      ],
    });
  });

  it('keeps reply ancestry from a single parent In-Reply-To and ignores comment identifiers', async () => {
    expect.hasAssertions();
    const { start, draft } = await reader({
      headers: {
        From: 'maya@example.invalid',
        'Message-ID':
          '(ignore <wrong@example.invalid>) <parent@example.invalid>',
        'In-Reply-To':
          '(ignore <fake@example.invalid>) <ancestor@example.invalid>',
        'Reply-To': `wrong@example.invalid${' '.repeat(64 * 1024)}`,
        Date: 'Tue, 1 Sep 2026 09:00:00 +0000',
      },
    });
    const reply = draft(await start('reply'));
    expect(reply.to.map(({ address }) => address)).toStrictEqual([
      'maya@example.invalid',
    ]);
    expect(plainText(present(reply.quoted, 'quoted text'))).toContain(
      'On Tue, 1 Sep 2026 09:00:00 +0000,',
    );
    expect(reply.response).toMatchObject({
      inReplyTo: '<parent@example.invalid>',
      references: ['<ancestor@example.invalid>', '<parent@example.invalid>'],
    });
  });

  it.each(['reader closes', 'account changes', 'navigation changes'] as const)(
    'refuses a Forward if %s during attachment preparation',
    async (replacement) => {
      expect.hasAssertions();
      const {
        inbox,
        close,
        drafts,
        navigation,
        registration,
        storage,
        message,
      } = await reader();
      const gate = Promise.withResolvers<undefined>();
      const begun = Promise.withResolvers<undefined>();
      const pending = startResponse(
        {
          navigation,
          drafts,
          inbox: {
            ...inbox,
            downloadAttachment: async (id, locator) => {
              begun.resolve(undefined);
              await gate.promise;
              await inbox.downloadAttachment(id, locator);
            },
          },
        },
        english,
        { kind: 'forward', mailbox: work, message, received: 'today' },
      );
      await begun.promise;
      await {
        'reader closes': close,
        'account changes': async () => {
          inbox.forget();
          registration.replace({
            ...connected(),
            productAccountId: 'account-b',
          });
          await drafts.load();
        },
        'navigation changes': () => navigation.leave(),
      }[replacement]();
      gate.resolve(undefined);
      await expect(pending).resolves.toBeUndefined();
      expect(drafts.getSnapshot()).toMatchObject({ drafts: [] });
      const reopened = createDrafts(storage.native, registration);
      await reopened.load();
      expect(reopened.getSnapshot()).toMatchObject({ drafts: [] });
    },
  );
});
