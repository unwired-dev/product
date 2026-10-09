import { assetsOf, isEmptyDraft } from '../src/drafts.ts';
import {
  applyText,
  emptyDocument,
  insertImage,
} from '../src/semantic-document.ts';
import { createSyntheticProductSync } from '../src/testing/drafts.ts';
import { alex, complete, device, present } from './draft-sync-fixture.ts';

describe('continuing synchronized Draft content and files', () => {
  it('automatically publishes a forwarded quoted image after its slow import finishes', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a new forward');
    await phone.drafts.sync();
    phone.storage.addFile('file:///received.png', 'received image bytes');
    phone.storage.holdImports();
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    try {
      const asset = phone.drafts.prepare({
        name: 'received.png',
        type: 'image/png',
      });
      await phone.drafts.fill(
        id,
        (draft) => ({
          ...draft,
          response: { kind: 'forward', message: 'received-message' },
          quoted: insertImage(emptyDocument, { start: 0, end: 0 }, asset)
            .document,
        }),
        [{ asset, source: { kind: 'file', uri: 'file:///received.png' } }],
      );
      await vi.advanceTimersByTimeAsync(60_000);
      await phone.drafts.sync();
      await mac.drafts.sync();
      expect({
        empty: isEmptyDraft(phone.draft(id)),
        draft: mac.draft(id),
        assetState: assetsOf(mac.draft(id))[0]?.state,
      }).toStrictEqual({
        empty: false,
        draft: phone.draft(id),
        assetState: 'importing',
      });

      phone.storage.releaseImports();
      await vi.advanceTimersByTimeAsync(0);
      expect(assetsOf(phone.draft(id))[0]).toMatchObject({ state: 'complete' });
      // Completion must publish without another phone edit or explicit synchronization.
      await vi.advanceTimersByTimeAsync(60_000);
      await mac.drafts.sync();
      const downloaded = complete(mac.draft(id), asset.id);
      expect({
        draft: mac.draft(id),
        preview: await mac.drafts.readAsset(downloaded),
      }).toStrictEqual({
        draft: phone.draft(id),
        preview: {
          kind: 'ready',
          uri: `data:image/png;base64,${btoa('received image bytes')}`,
        },
      });
      await mac.drafts.save();
      await mac.relaunch();
      await mac.drafts.sync();
      server.setReachable(false);
      expect({
        draft: mac.draft(id),
        preview: await mac.drafts.readAsset(downloaded),
      }).toStrictEqual({
        draft: phone.draft(id),
        preview: {
          kind: 'ready',
          uri: `data:image/png;base64,${btoa('received image bytes')}`,
        },
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('continues a reply and preserves response-only and quoted-only divergent edits', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a new reply');
    const response = {
      kind: 'replyAll' as const,
      message: 'received-message',
      thread: { connection: alex.id, id: 'received-thread' },
      inReplyTo: '<received@example.invalid>',
      references: ['<parent@example.invalid>', '<received@example.invalid>'],
    };
    const quoted = applyText(emptyDocument, 'Original correspondence').document;
    await phone.drafts.fill(
      id,
      (draft) => ({ ...draft, response, quoted }),
      [],
    );
    await phone.drafts.sync();
    await mac.drafts.sync();
    await mac.relaunch();
    await mac.drafts.sync();
    expect(mac.draft(id)).toStrictEqual(phone.draft(id));

    const original = mac.draft(id);
    const phoneEdit = {
      ...original,
      response: { ...response, kind: 'reply' as const },
    };
    const macEdit = {
      ...original,
      quoted: applyText(emptyDocument, 'Different correspondence').document,
    };
    await phone.drafts.update(phoneEdit, original);
    await mac.drafts.update(macEdit, original);
    await phone.drafts.sync();
    await mac.drafts.sync();
    await phone.drafts.sync();
    const copy = present(
      mac.list().find((draft) => draft.conflict === true),
      'the quoted conflict',
    );
    expect({
      count: mac.list().length,
      continued: {
        response: mac.draft(id).response,
        quoted: mac.draft(id).quoted,
      },
      copy: { response: copy.response, quoted: copy.quoted },
    }).toStrictEqual({
      count: 2,
      continued: { response: phoneEdit.response, quoted },
      copy: { response, quoted: macEdit.quoted },
    });
    expect(phone.draft(copy.id)).toStrictEqual(copy);
    await mac.relaunch();
    expect(mac.draft(copy.id)).toStrictEqual(copy);
  });

  it('reclaims a file whose download finishes after its Draft was discarded', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    phone.storage.addFile('file:///notes.txt', 'notes bytes');
    const notes = phone.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    await phone.drafts.update(
      { ...phone.draft(id), attachments: [notes] },
      phone.draft(id),
    );
    await phone.drafts.importAsset(notes, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    await phone.drafts.sync();
    await mac.drafts.sync();

    // The Mac discards the Draft while its file is still downloading.
    mac.storage.holdImports();
    const reading = mac.drafts.readAsset(complete(mac.draft(id), notes.id), {
      preview: false,
    });
    await expect(mac.drafts.discard(id)).resolves.toBe(true);
    mac.storage.releaseImports();
    await expect(reading).resolves.toStrictEqual({ kind: 'missing' });
    expect(mac.storage.assets()).toStrictEqual([]);
  });

  it('keeps a late download referenced after re-entering the same account', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const phone = await device(server);
    const mac = await device(server);
    const id = present(await phone.drafts.create(alex), 'a Draft');
    phone.storage.addFile('file:///notes.txt', 'notes bytes');
    const notes = phone.drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    await phone.drafts.update(
      { ...phone.draft(id), attachments: [notes] },
      phone.draft(id),
    );
    await phone.drafts.importAsset(notes, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    await phone.drafts.sync();
    await mac.drafts.sync();

    const native = present(mac.storage.sync, 'Draft sync');
    const download = native.downloadDraftAsset;
    const started = Promise.withResolvers<undefined>();
    const held = vi
      .spyOn(native, 'downloadDraftAsset')
      .mockImplementation((...args) => {
        started.resolve(undefined);
        return download(...args);
      });
    mac.storage.holdImports();
    const asset = complete(mac.draft(id), notes.id);
    const reading = mac.drafts.readAsset(asset, { preview: false });
    await started.promise;
    await mac.reconnect();
    expect(complete(mac.draft(id), notes.id)).toStrictEqual(asset);
    mac.storage.releaseImports();
    await expect(reading).resolves.toStrictEqual({ kind: 'missing' });
    held.mockRestore();
    expect(mac.storage.assets()).toStrictEqual([notes.id]);
    server.setReachable(false);
    await expect(
      mac.drafts.readAsset(asset, { preview: false }),
    ).resolves.toStrictEqual({ kind: 'verified' });
  });
});
