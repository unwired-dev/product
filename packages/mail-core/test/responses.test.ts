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
  withSender,
} from '../src/drafts.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { attachmentLimit } from '../src/message-body.ts';
import { respond, startResponse } from '../src/responses.ts';
import { emptyDocument, plainText } from '../src/semantic-document.ts';
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
): RegistrationSnapshot => ({
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

const registrationOf = (snapshot: RegistrationSnapshot) => ({
  getSnapshot: () => ({ snapshot, busy: false, failed: false }),
  subscribe: () => () => undefined,
});

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
  const storage = createSyntheticDrafts(() => 'account-a');
  const registration = registrationOf(snapshot);
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

    // Reply All keeps every other recipient once, without this mailbox's own address, and keeps
    // the other identity of the same account.
    const all = draft(await start('replyAll'));
    expect(all.to.map(({ address }) => address)).toStrictEqual([
      'maya.lists@example.invalid',
      'bob@example.invalid',
      'alex@example.invalid',
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
        html: '<p>See the chart</p><img src="cid:chart@example" alt="chart">',
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
    close();
    await expect(start('reply')).resolves.toBeUndefined();
    expect(drafts.getSnapshot()).toMatchObject({ drafts: [] });
  });
});
