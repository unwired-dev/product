import type { GmailInbox } from '../src/gmail-inbox.ts';

import { createGmailInbox } from '../src/gmail-inbox.ts';
import { attachmentLimit, safeFilename } from '../src/message-body.ts';
import {
  createSyntheticGmail,
  notesText,
} from '../src/testing/gmail-mailbox.ts';

const report = [...Buffer.from('%PDF-1.7 synthetic report')];

const attachmentRequests = (gmail: ReturnType<typeof createSyntheticGmail>) =>
  gmail.requests.filter(({ path }) => path.includes('/attachments/'));

const cachedBody = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  id: string,
) => {
  const document = gmail.cachedBodies().get(id);
  if (document === undefined) {
    throw new Error('Expected a cached body');
  }
  return document;
};

const listed = (inbox: GmailInbox, id: string) => {
  const attachments = inbox.messageAttachments(id);
  if (attachments === undefined) {
    throw new Error('Expected attachment metadata');
  }
  return attachments;
};

const stateOf = (inbox: GmailInbox, id: string, name: string) =>
  listed(inbox, id).find((attachment) => attachment.name === name)?.state;

const locatorOf = (inbox: GmailInbox, id: string, name: string) => {
  const found = listed(inbox, id).find(
    (attachment) => attachment.name === name,
  );
  if (found === undefined) {
    throw new Error(`Expected attachment ${name}`);
  }
  return found.locator;
};

// An Inbox with one opened message carrying `attachments`, its reader kept open.
async function opened(
  attachments: Parameters<
    ReturnType<typeof createSyntheticGmail>['deliver']
  >[0] = {},
) {
  const gmail = createSyntheticGmail();
  const id = gmail.deliver(attachments);
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const close = inbox.retainMessage(id);
  await inbox.readMessage(id);
  return { gmail, id, inbox, close };
}

describe('received attachments', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one attachment path end to end. */
  it('lists names, sizes and availability without downloading, then downloads, opens, shares and cleans up', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox, close } = await opened({
      content: {
        text: 'See attached.',
        attachments: [
          {
            filename: '../Q3\u202Efdp.exe/report.pdf',
            mimeType: 'application/pdf',
            bytes: report,
          },
          {
            filename: 'archive.zip',
            mimeType: 'application/zip',
            bytes: [],
            size: attachmentLimit + 1,
          },
          {
            filename: 'forwarded.eml',
            mimeType: 'message/rfc822',
            bytes: [1, 2, 3],
          },
        ],
      },
    });

    expect(listed(inbox, id)).toStrictEqual([
      {
        locator: '0.1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        size: notesText.length,
        state: { kind: 'available' },
      },
      {
        locator: '0.2',
        name: '_Q3fdp.exe_report.pdf',
        mimeType: 'application/pdf',
        size: report.length,
        state: { kind: 'available' },
      },
      {
        locator: '0.3',
        name: 'archive.zip',
        mimeType: 'application/zip',
        size: attachmentLimit + 1,
        state: { kind: 'oversized' },
      },
    ]);
    // Opening the message read only its readable body.
    expect(attachmentRequests(gmail)).toStrictEqual([]);

    const pdf = locatorOf(inbox, id, '_Q3fdp.exe_report.pdf');
    await inbox.downloadAttachment(id, pdf);
    await inbox.downloadAttachment(id, locatorOf(inbox, id, 'archive.zip'));

    expect(stateOf(inbox, id, '_Q3fdp.exe_report.pdf')).toStrictEqual({
      kind: 'downloaded',
    });
    expect(stateOf(inbox, id, 'archive.zip')).toStrictEqual({
      kind: 'oversized',
    });
    // Only the requested attachment was downloaded, and its exact bytes were saved.
    expect(attachmentRequests(gmail).map(({ path }) => path)).toStrictEqual([
      `messages/${id}/attachments/file-0`,
    ]);
    expect([...gmail.savedFiles.values()]).toStrictEqual([
      { name: '_Q3fdp.exe_report.pdf', bytes: Uint8Array.from(report) },
    ]);

    await inbox.presentAttachment(id, pdf, 'open');
    await inbox.presentAttachment(id, pdf, 'share');
    expect(gmail.presentations).toStrictEqual([
      { name: '_Q3fdp.exe_report.pdf', action: 'open' },
      { name: '_Q3fdp.exe_report.pdf', action: 'share' },
    ]);

    // Closing the message deletes its Downloaded Attachments.
    close();
    expect(gmail.savedFiles.size).toBe(0);
  });

  it('rejects incomplete or undecodable downloads and saves nothing', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox } = await opened({
      content: {
        text: 'Two damaged files.',
        attachments: [
          {
            filename: 'short.bin',
            mimeType: 'application/octet-stream',
            bytes: [1, 2, 3],
            size: 4,
          },
          {
            filename: 'garbled.bin',
            mimeType: 'application/octet-stream',
            bytes: [1, 2, 3],
            data: '***',
          },
        ],
      },
    });

    await inbox.downloadAttachment(id, locatorOf(inbox, id, 'short.bin'));
    await inbox.downloadAttachment(id, locatorOf(inbox, id, 'garbled.bin'));

    expect(stateOf(inbox, id, 'short.bin')).toStrictEqual({
      kind: 'unavailable',
      reason: 'damaged',
    });
    expect(stateOf(inbox, id, 'garbled.bin')).toStrictEqual({
      kind: 'unavailable',
      reason: 'damaged',
    });
    expect(gmail.savedFiles.size).toBe(0);
  });

  it('retries an interrupted download and reports refused grants and removed messages', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox } = await opened();
    const notes = locatorOf(inbox, id, 'notes.txt');

    gmail.fail({ code: 'unavailable' });
    await inbox.downloadAttachment(id, notes);
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'unavailable',
      reason: 'download',
    });
    expect(gmail.savedFiles.size).toBe(0);

    await inbox.downloadAttachment(id, notes);
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'downloaded',
    });
    expect([...gmail.savedFiles.values()]).toStrictEqual([
      { name: 'notes.txt', bytes: new TextEncoder().encode(notesText) },
    ]);

    const second = await opened();
    second.gmail.fail({ status: 401 });
    await second.inbox.downloadAttachment(
      second.id,
      locatorOf(second.inbox, second.id, 'notes.txt'),
    );
    expect(stateOf(second.inbox, second.id, 'notes.txt')).toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(second.inbox.getSnapshot()).toMatchObject({
      sync: 'authentication',
    });

    const third = await opened();
    third.gmail.remove(third.id);
    await third.inbox.downloadAttachment(
      third.id,
      locatorOf(third.inbox, third.id, 'notes.txt'),
    );
    expect(stateOf(third.inbox, third.id, 'notes.txt')).toStrictEqual({
      kind: 'unavailable',
      reason: 'missing',
    });
  });

  it('cancels a download, including one already being saved, without keeping its file', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox, close } = await opened();
    const notes = locatorOf(inbox, id, 'notes.txt');

    // Gmail is slow to answer: cancelling drops the download.
    const request = gmail.native.gmailRequest;
    const requesting = Promise.withResolvers<undefined>();
    const interrupted = Promise.withResolvers<undefined>();
    gmail.native.gmailRequest = async (path, query, scope) => {
      const { signal } = scope;
      requesting.resolve(undefined);
      // oxlint-disable-next-line promise/avoid-new -- The transport waits for cancellation, not a timer.
      await new Promise<void>((_resolve, reject) => {
        signal?.addEventListener(
          'abort',
          () => {
            interrupted.resolve(undefined);
            reject(new Error('synthetic cancellation'));
          },
          { once: true },
        );
      });
      return request(path, query, scope);
    };
    const first = inbox.downloadAttachment(id, notes);
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'downloading',
    });
    await requesting.promise;
    inbox.cancelAttachment(id, notes);
    await interrupted.promise;
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'available',
    });
    await first;
    expect(attachmentRequests(gmail)).toStrictEqual([]);
    gmail.native.gmailRequest = request;

    // Native code is still writing the file when the person cancels: the file is deleted.
    const save = gmail.native.saveAttachment;
    const saving = Promise.withResolvers<undefined>();
    const saveHeld = Promise.withResolvers<undefined>();
    gmail.native.saveAttachment = async (...args) => {
      saving.resolve(undefined);
      await saveHeld.promise;
      return save(...args);
    };
    const second = inbox.downloadAttachment(id, notes);
    await saving.promise;
    inbox.cancelAttachment(id, notes);
    saveHeld.resolve(undefined);
    await second;
    await Promise.resolve();

    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'available',
    });
    expect(gmail.savedFiles.size).toBe(0);

    // Last-reader closure also deletes files while a body refresh is still pending.
    gmail.native.saveAttachment = save;
    await inbox.downloadAttachment(id, notes);
    const open = gmail.native.openMessageBody;
    const opening = Promise.withResolvers<undefined>();
    const held = Promise.withResolvers<undefined>();
    gmail.native.openMessageBody = async (...args) => {
      opening.resolve(undefined);
      await held.promise;
      return open(...args);
    };
    const refresh = inbox.readMessage(id, { refresh: true });
    await opening.promise;
    // This journey's only reader ends before the body refresh can settle.
    close();
    expect(gmail.savedFiles.size).toBe(0);
    held.resolve(undefined);
    await refresh;
  });

  it('drops a downloaded file when a refresh changes its attachment at the same position', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox } = await opened({
      content: {
        text: 'Report attached.',
        attachments: [
          {
            filename: 'report.pdf',
            mimeType: 'application/pdf',
            bytes: report,
          },
        ],
      },
    });
    const notes = locatorOf(inbox, id, 'notes.txt');
    const pdf = locatorOf(inbox, id, 'report.pdf');
    await inbox.downloadAttachment(id, notes);
    await inbox.downloadAttachment(id, pdf);
    expect(gmail.savedFiles.size).toBe(2);

    // The refreshed body names another file at the report's position.
    await gmail.native.commitMessageBody(
      { address: 'alex@example.invalid', generation: '0' },
      id,
      {
        document: cachedBody(gmail, id).replace(
          '"name":"report.pdf"',
          '"name":"report-v2.pdf"',
        ),
        tier: 'opened',
        protectedIds: [],
      },
    );
    await inbox.readMessage(id, { refresh: true });

    expect(stateOf(inbox, id, 'report-v2.pdf')).toStrictEqual({
      kind: 'available',
    });
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'downloaded',
    });
    expect(
      [...gmail.savedFiles.values()].map(({ name }) => name),
    ).toStrictEqual(['notes.txt']);
  });

  it('downloads again when the saved file is gone, and forgets downloads with the Inbox', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox } = await opened();
    const notes = locatorOf(inbox, id, 'notes.txt');
    await inbox.downloadAttachment(id, notes);
    // The system cleared the temporary file.
    gmail.savedFiles.clear();

    await inbox.presentAttachment(id, notes, 'open');
    expect(gmail.presentations).toStrictEqual([]);
    expect(stateOf(inbox, id, 'notes.txt')).toStrictEqual({
      kind: 'available',
    });

    await inbox.downloadAttachment(id, notes);
    expect(gmail.savedFiles.size).toBe(1);
    inbox.forget();
    expect(gmail.savedFiles.size).toBe(0);
  });

  it('lists attachments for a body cached before their metadata was kept, once Gmail answers', async () => {
    expect.hasAssertions();
    const { gmail, id, inbox, close } = await opened();
    const legacy = cachedBody(gmail, id).replace(
      /,"attachments":\[[^\]]*\]/u,
      '',
    );
    expect(legacy).not.toContain('attachments');
    await gmail.native.commitMessageBody(
      { address: 'alex@example.invalid', generation: '0' },
      id,
      { document: legacy, tier: 'opened', protectedIds: [] },
    );
    close();

    gmail.fail({ code: 'unavailable' });
    const offline = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(inbox.messageAttachments(id)).toBeUndefined();
    offline();

    const online = inbox.retainMessage(id);
    await inbox.readMessage(id);
    expect(listed(inbox, id).map(({ name }) => name)).toStrictEqual([
      'notes.txt',
    ]);
    expect(cachedBody(gmail, id)).toContain('"name":"notes.txt"');
    online();
  });
  /* oxlint-enable vitest/max-expects */

  it('keeps file names safe to show and save', () => {
    expect.hasAssertions();
    expect(safeFilename(String.raw`..\..\etc/passwd`)).toBe('_.._etc_passwd');
    expect(safeFilename(' .hidden ')).toBe('hidden');
    expect(safeFilename('in\u0000voice\u200F.pdf')).toBe('invoice.pdf');
    expect(safeFilename('...')).toBe('attachment');
    expect([
      safeFilename(`${'a'.repeat(200)}.docx`),
      safeFilename(`${'📎'.repeat(100)}.pdf`),
    ]).toStrictEqual([`${'a'.repeat(115)}.docx`, `${'📎'.repeat(62)}.pdf`]);
  });
});
