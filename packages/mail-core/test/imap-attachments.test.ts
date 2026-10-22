import * as Base64 from 'effect/encoding/Base64';

import type { ImapInbox, NativeImapMailbox } from '../src/imap-inbox.ts';

import { createImapInbox } from '../src/imap-inbox.ts';
import { createSyntheticImap } from '../src/testing/imap-mailbox.ts';

const pdf = new TextEncoder().encode('%PDF-1.4\n');

// A plain-text message with one attached file, as the controlled server stores it.
const withAttachment = (subject: string, name: string) =>
  [
    'From: Synthetic Sender <sender@example.invalid>',
    'To: alex@example.invalid',
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="mixed"',
    '',
    '--mixed',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'The report is attached.',
    '--mixed',
    `Content-Type: application/pdf; name="${name}"`,
    `Content-Disposition: attachment; filename="${name}"`,
    'Content-Transfer-Encoding: base64',
    '',
    Base64.encode(pdf),
    '--mixed--',
  ].join('\r\n');

// The connection's server, with source reads that wait for `release` while `held`.
const setup = async () => {
  const imap = createSyntheticImap();
  imap.deliver('INBOX', {
    subject: 'Report',
    raw: withAttachment('Report', 'report.pdf'),
  });
  imap.deliver('INBOX', {
    subject: 'Invoice',
    raw: withAttachment('Invoice', 'invoice.pdf'),
  });
  const gate = { held: false, waiting: [] as Array<() => void> };
  const native: NativeImapMailbox = {
    ...imap.native,
    imapMessage: async (mailbox, message) => {
      if (gate.held) {
        // oxlint-disable-next-line promise/avoid-new -- Hold the server's answer until the test releases it.
        await new Promise<void>((resolve) => {
          gate.waiting.push(resolve);
        });
      }
      return imap.native.imapMessage(mailbox, message);
    },
  };
  const inbox = createImapInbox(native, { connection: 'imap-1' });
  await inbox.load();
  const idOf = (subject: string) => {
    const state = inbox.getSnapshot();
    const found =
      state.kind === 'ready'
        ? state.messages.find((message) => message.subject === subject)
        : undefined;
    if (found === undefined) {
      throw new Error(`No listed message ${subject}`);
    }
    return found.id;
  };
  // Opens the message in one reader, as the IMAP reader view does.
  const open = async (subject: string) => {
    const id = idOf(subject);
    const release = inbox.retainMessage(id, Symbol('reader'));
    await inbox.readMessage(id);
    return { id, release };
  };
  return {
    imap,
    inbox,
    open,
    hold: () => {
      gate.held = true;
    },
    release: () => {
      gate.held = false;
      for (const resume of gate.waiting.splice(0)) {
        resume();
      }
    },
  };
};

const stateOf = (inbox: ImapInbox, id: string) =>
  inbox.messageAttachments(id)?.[0]?.state;

describe('imap received attachments', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one download and ownership contract end to end. */
  it('downloads, opens and shares an attachment from the message source, then deletes it with the last reader', async () => {
    expect.hasAssertions();
    const { imap, inbox, open } = await setup();
    const { id, release } = await open('Report');
    expect(inbox.messageAttachments(id)).toStrictEqual([
      {
        locator: '0.1',
        name: 'report.pdf',
        mimeType: 'application/pdf',
        size: pdf.length,
        state: { kind: 'available' },
      },
    ]);

    // Download reads the message's source again at its UIDVALIDITY and keeps its exact bytes.
    imap.server.reads.length = 0;
    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'downloaded' });
    expect(imap.server.reads).toStrictEqual(['message INBOX 1']);
    expect([...imap.files.savedFiles.values()]).toStrictEqual([
      { name: 'report.pdf', bytes: pdf },
    ]);
    // A second Download reads nothing more.
    await inbox.downloadAttachment(id, '0.1');
    expect(imap.server.reads).toStrictEqual(['message INBOX 1']);

    await inbox.presentAttachment(id, '0.1', 'open');
    await inbox.presentAttachment(id, '0.1', 'share');
    expect(imap.files.presentations).toStrictEqual([
      { name: 'report.pdf', action: 'open' },
      { name: 'report.pdf', action: 'share' },
    ]);
    // A Draft can copy the saved file through the connection's open generation.
    expect(inbox.attachmentFile(id, '0.1')).toStrictEqual({
      name: 'report.pdf',
      type: 'application/pdf',
      address: 'alex@example.invalid',
      generation: 'generation-1',
      file: [...imap.files.savedFiles.keys()][0],
    });

    // A file the device no longer has offers Download again.
    imap.files.savedFiles.clear();
    await inbox.presentAttachment(id, '0.1', 'open');
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'available' });
    await inbox.downloadAttachment(id, '0.1');
    expect(imap.files.savedFiles.size).toBe(1);

    release();
    expect(imap.files.savedFiles.size).toBe(0);
  });

  it('says why a download failed and downloads after Try again', async () => {
    expect.hasAssertions();
    const { imap, inbox, open } = await setup();
    const { id } = await open('Report');

    imap.server.failure = 'offline';
    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'download',
    });

    // A refused password also asks for it again in the Inbox.
    imap.server.failure = 'imap-refused';
    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toMatchObject({ status: 'authentication' });

    imap.server.failure = undefined;
    imap.files.failSave('locked');
    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'locked',
    });
    expect(imap.files.savedFiles.size).toBe(0);

    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'downloaded' });
  });

  it('reports a message the server no longer has', async () => {
    expect.hasAssertions();
    const { imap, inbox, open } = await setup();
    const { id } = await open('Report');
    imap.expunge('INBOX', 1);
    await inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'missing',
    });
  });

  it('cancels a download and deletes a file saved for it', async () => {
    expect.hasAssertions();
    const { imap, inbox, open, hold, release } = await setup();
    const { id } = await open('Report');
    hold();
    const download = inbox.downloadAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'downloading' });
    inbox.cancelAttachment(id, '0.1');
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'available' });
    release();
    await download;
    expect(stateOf(inbox, id)).toStrictEqual({ kind: 'available' });
    expect(imap.files.savedFiles.size).toBe(0);
  });

  it('a new UIDVALIDITY deletes saved attachments and drops downloads in flight', async () => {
    expect.hasAssertions();
    const { imap, inbox, open, hold, release } = await setup();
    const report = await open('Report');
    const invoice = await open('Invoice');
    await inbox.downloadAttachment(report.id, '0.1');
    expect(imap.files.savedFiles.size).toBe(1);
    hold();
    const pending = inbox.downloadAttachment(invoice.id, '0.1');

    imap.renumber('INBOX');
    await inbox.load();
    // Readers keep showing the earlier messages, whose attachments are gone from this folder.
    expect(imap.files.savedFiles.size).toBe(0);
    for (const { id } of [report, invoice]) {
      expect(stateOf(inbox, id)).toStrictEqual({
        kind: 'unavailable',
        reason: 'missing',
      });
    }
    release();
    await pending;
    expect(stateOf(inbox, invoice.id)).toStrictEqual({
      kind: 'unavailable',
      reason: 'missing',
    });
    expect(imap.files.savedFiles.size).toBe(0);
  });

  it('deletes saved attachments when the connection leaves the Inbox', async () => {
    expect.hasAssertions();
    const { imap, inbox, open } = await setup();
    const { id } = await open('Report');
    await inbox.downloadAttachment(id, '0.1');
    expect(imap.files.savedFiles.size).toBe(1);
    inbox.forget();
    expect(imap.files.savedFiles.size).toBe(0);
  });
  /* oxlint-enable vitest/max-expects */
});
