import type { Draft, DraftsState } from '../src/drafts.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';
import type { SemanticDocument } from '../src/semantic-document.ts';

import {
  addRecipients,
  createDrafts,
  draftOf,
  sendingStateOf,
} from '../src/drafts.ts';
import { mailboxesOf } from '../src/registration.ts';
import {
  applyText,
  displayOf,
  emptyDocument,
  historyOf,
  plainText,
  record,
  redo,
  setBlockKind,
  toggleMark,
  undo,
} from '../src/semantic-document.ts';
import { createSyntheticDrafts } from '../src/testing/drafts.ts';

const alex = { id: 'connection-alex', address: 'alex@example.invalid' };
const other = { id: 'connection-other', address: 'other@example.invalid' };

const connected = (
  productAccountId: string,
  mailboxes: ReadonlyArray<
    Readonly<{ id: string; address: string; state?: 'authorization' }>
  > = [alex, other],
): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId,
  signInProvider: 'google',
  mailboxes: JSON.stringify(
    mailboxes.map(({ id, address, state = 'connected' }) => ({
      id,
      address,
      state,
    })),
  ),
});

// Registration as the Draft store follows it, with an account the test can change.
function account(initial: RegistrationSnapshot) {
  let snapshot = initial;
  const listeners = new Set<() => void>();
  return {
    registration: {
      getSnapshot: () => ({ snapshot, busy: false, failed: false }),
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    },
    productAccount: () =>
      snapshot.kind === 'signed-out' ? undefined : snapshot.productAccountId,
    change: (next: RegistrationSnapshot) => {
      snapshot = next;
      for (const listener of listeners) {
        listener();
      }
    },
    mailboxes: () => mailboxesOf(snapshot),
  };
}

const ready = (state: DraftsState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected ready Drafts, received ${state.kind}`);
  }
  return state;
};

const typed = (document: SemanticDocument, text: string) =>
  applyText(document, text).document;

const present = <T>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`Expected ${what}`);
  }
  return value;
};

describe('editing a Semantic Message Document', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one editing path end to end. */
  it('continues lists on Return, applies Markdown markers with a literal Undo step, and keeps marks', () => {
    expect.hasAssertions();
    let document = typed(emptyDocument, 'Plan');
    document = typed(document, 'Plan\n');
    document = typed(document, 'Plan\n-');
    // A Markdown marker at the start of a block applies its list semantics without storing it.
    const marker = applyText(document, 'Plan\n- ');
    expect(plainText(present(marker.literal, 'a literal marker'))).toBe(
      'Plan\n- ',
    );
    ({ document } = marker);
    expect(document.map(({ kind }) => kind)).toStrictEqual([
      'paragraph',
      'bulleted',
    ]);
    expect(displayOf(document).text).toBe('Plan\n• ');
    expect(marker.selection).toStrictEqual({ start: 7, end: 7 });
    document = typed(document, 'Plan\n• Milk');
    document = typed(document, 'Plan\n• Milk\n');
    expect(displayOf(document).text).toBe('Plan\n• Milk\n• ');
    // Deleting into a marker turns the item back into a paragraph.
    const removed = applyText(document, 'Plan\n• Milk\n•');
    expect(removed.document.map(({ kind }) => kind)).toStrictEqual([
      'paragraph',
      'bulleted',
      'paragraph',
    ]);
    expect(displayOf(removed.document).text).toBe('Plan\n• Milk\n');
    expect(removed.selection).toStrictEqual({ start: 12, end: 12 });

    // Marks apply to a selection, and text typed after marked text continues them.
    const bold = toggleMark(document, { start: 7, end: 11 }, 'bold');
    expect(bold[1]?.spans).toStrictEqual([{ text: 'Milk', marks: ['bold'] }]);
    const more = typed(bold, 'Plan\n• Milks\n• ');
    expect(more[1]?.spans).toStrictEqual([{ text: 'Milks', marks: ['bold'] }]);
    expect(
      toggleMark(more, { start: 7, end: 12 }, 'bold')[1]?.spans,
    ).toStrictEqual([{ text: 'Milks' }]);

    // Numbered items count from one, and a block kind applies to every selected block.
    const numbered = setBlockKind(more, { start: 0, end: 12 }, 'numbered');
    expect(displayOf(numbered.document).text).toBe('1. Plan\n2. Milks\n• ');
    expect(numbered.selection).toStrictEqual({ start: 3, end: 16 });
    // Return at the start of a heading keeps the heading and inserts a paragraph above it.
    const heading = setBlockKind(
      typed(emptyDocument, 'Title'),
      { start: 0, end: 0 },
      'heading1',
    );
    const above = typed(heading.document, '\nTitle');
    expect(above.map(({ kind }) => kind)).toStrictEqual([
      'paragraph',
      'heading1',
    ]);
  });

  it('undoes typing a word at a time and redoes it', () => {
    expect.hasAssertions();
    let history = historyOf('');
    for (const text of ['H', 'Hi', 'Hi ', 'Hi t', 'Hi th', 'Hi there']) {
      history = record(history, text, !text.endsWith(' '));
    }
    history = record(history, 'Hi there', false);
    history = undo(history);
    expect(history.present).toBe('Hi there');
    history = undo(history);
    expect(history.present).toBe('Hi ');
    history = undo(history);
    expect(history.present).toBe('Hi');
    history = redo(history);
    expect(history.present).toBe('Hi ');
    expect(redo(redo(redo(history))).present).toBe('Hi there');
  });

  it('edits the selected occurrence of repeated characters without moving their marks', () => {
    expect.hasAssertions();
    const document: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [{ text: 'a', marks: ['bold'] }, { text: 'a' }],
      },
    ];
    expect(
      applyText(document, 'a', { selection: { start: 0, end: 1 } }).document[0]
        .spans,
    ).toStrictEqual([{ text: 'a' }]);
    expect(
      applyText(document, 'a', { selection: { start: 1, end: 1 } }).document[0]
        .spans,
    ).toStrictEqual([{ text: 'a' }]);
    expect(
      applyText(document, 'a', {
        selection: { start: 1, end: 1 },
        deletion: 'forward',
      }).document[0].spans,
    ).toStrictEqual([{ text: 'a', marks: ['bold'] }]);
    expect(
      applyText(document, 'aaa', { marks: [], selection: { start: 0, end: 0 } })
        .document[0].spans,
    ).toStrictEqual([
      { text: 'a' },
      { text: 'a', marks: ['bold'] },
      { text: 'a' },
    ]);
  });
  /* oxlint-enable vitest/max-expects */
});

describe('entering Draft recipients', () => {
  /* oxlint-disable vitest/max-expects -- One journey proves recipient entry end to end. */
  const draft: Draft = {
    id: 'draft',
    connection: alex.id,
    from: alex.address,
    to: [],
    cc: [],
    bcc: [],
    subject: '',
    body: emptyDocument,
    updatedAt: 0,
  };

  it('accepts names and addresses, keeps invalid text, and never adds an address twice', () => {
    expect.hasAssertions();
    const named = addRecipients(draft, {
      field: 'to',
      text: '"Chen, Maya" <maya@example.com>, oliver@example.com; partial',
    });
    expect(named.draft.to).toStrictEqual([
      { name: 'Chen, Maya', address: 'maya@example.com' },
      { address: 'oliver@example.com' },
    ]);
    expect(named.text).toBe('partial');
    expect(named.notice).toBeUndefined();

    const invalid = addRecipients(named.draft, {
      field: 'cc',
      text: 'not an address',
      all: true,
    });
    expect(invalid.notice).toBe('invalid');
    expect(invalid.text).toBe('not an address');
    expect(invalid.draft.cc).toStrictEqual([]);

    const duplicate = addRecipients(named.draft, {
      field: 'bcc',
      text: 'MAYA@example.com',
      all: true,
    });
    expect(duplicate.notice).toBe('duplicate');
    expect(duplicate.text).toBe('');
    expect(duplicate.draft.bcc).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */
});

describe('storing Drafts', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one storage path end to end. */
  it('saves every edit in order, reopens the same Draft, and keeps unsaved edits through a failure', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = await drafts.create(alex);
    const created = present(draftOf(drafts.getSnapshot(), id), 'the new Draft');

    // Edits made while a save is in flight are saved after it, never dropped.
    storage.hold();
    const first = drafts.update({ ...created, subject: 'Studio' });
    const second = drafts.update({
      ...created,
      subject: 'Studio review',
      body: typed(emptyDocument, 'Notes'),
    });
    expect(ready(drafts.getSnapshot()).save).toBe('saving');
    storage.release();
    await Promise.all([first, second]);
    expect(ready(drafts.getSnapshot()).save).toBe('saved');

    // A failed save keeps the edit in memory and reports it; the next save stores it.
    storage.failNextCommit('unavailable');
    const failed = await drafts.update({
      ...created,
      subject: 'Studio review on Thursday',
      body: typed(emptyDocument, 'Notes'),
    });
    expect(failed).toBe(false);
    expect(ready(drafts.getSnapshot()).save).toBe('failed');
    expect(draftOf(drafts.getSnapshot(), id)?.subject).toBe(
      'Studio review on Thursday',
    );
    await expect(drafts.save()).resolves.toBe(true);

    // A new store, as after relaunch, reopens the same Draft without sending it.
    const relaunched = createDrafts(storage.native, session.registration);
    await relaunched.load();
    const reopened = present(
      draftOf(relaunched.getSnapshot(), id),
      'the reopened Draft',
    );
    expect(reopened.subject).toBe('Studio review on Thursday');
    expect(plainText(reopened.body)).toBe('Notes');
    expect(reopened.connection).toBe(alex.id);
  });

  it('keeps a Draft whose sending mailbox was removed, without substituting another sender', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = await drafts.create(other);
    expect(sendingStateOf({ connection: other.id }, session.mailboxes())).toBe(
      'available',
    );
    session.change(
      connected('account-a', [alex, { ...other, state: 'authorization' }]),
    );
    expect(sendingStateOf({ connection: other.id }, session.mailboxes())).toBe(
      'authorization',
    );
    session.change(connected('account-a', [alex]));
    const kept = draftOf(drafts.getSnapshot(), id);
    expect(kept?.connection).toBe(other.id);
    expect(kept?.from).toBe(other.address);
    expect(sendingStateOf({ connection: other.id }, session.mailboxes())).toBe(
      'removed',
    );
  });

  it('preserves concurrent Drafts and conflicting editor versions, including after relaunch', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    const second = createDrafts(storage.native, session.registration);
    await Promise.all([first.load(), second.load()]);
    const firstId = await first.create(alex);
    const secondId = await second.create(other);
    expect(ready(second.getSnapshot()).drafts.map(({ id }) => id)).toContain(
      firstId,
    );
    const before = present(
      draftOf(second.getSnapshot(), secondId),
      'Draft shared by windows',
    );
    await second.update({ ...before, subject: 'Window A subject' }, before);
    await expect(
      second.discard(before.id, { onlyIfEmpty: true }),
    ).resolves.toBe(true);
    expect(draftOf(second.getSnapshot(), before.id)?.subject).toBe(
      'Window A subject',
    );
    await second.update(
      { ...before, body: typed(emptyDocument, 'Window B body') },
      before,
    );
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: firstId }),
        expect.objectContaining({
          subject: 'Window A subject',
          conflict: true,
        }),
        expect.objectContaining({
          id: secondId,
          body: typed(emptyDocument, 'Window B body'),
        }),
      ]),
    );
    // A stale store's later edit must preserve the durable conflicting version too.
    const stale = present(draftOf(first.getSnapshot(), firstId), 'first Draft');
    const recent = present(
      draftOf(reopened.getSnapshot(), firstId),
      'reopened first Draft',
    );
    await reopened.update({ ...recent, subject: 'Durable version' }, recent);
    await first.update({ ...stale, subject: 'Stale editor version' }, stale);
    const final = createDrafts(storage.native, session.registration);
    await final.load();
    expect(
      ready(final.getSnapshot()).drafts.map(({ subject }) => subject),
    ).toStrictEqual(
      expect.arrayContaining([
        'Durable version',
        'Stale editor version',
        'Window A subject',
      ]),
    );
  });

  it('keeps a refused deletion visible and retryable without losing the durable Draft', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft id');
    storage.failNextCommit('locked');
    await expect(drafts.discard(id)).resolves.toBe(false);
    expect(draftOf(drafts.getSnapshot(), id)).toBeDefined();
    await expect(drafts.discard(id)).resolves.toBe(true);
    expect(draftOf(drafts.getSnapshot(), id)).toBeUndefined();
    // A repeated discard still confirms deletion durably and reports refused storage.
    storage.failNextCommit('locked');
    await expect(drafts.discard(id)).resolves.toBe(false);
    expect(ready(drafts.getSnapshot()).save).toBe('locked');
    await expect(drafts.discard(id)).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([]);
    // Another window's completed edit while deletion is in flight survives as a copy.
    const racingId = present(await drafts.create(alex), 'racing Draft');
    const before = present(
      draftOf(drafts.getSnapshot(), racingId),
      'racing editor',
    );
    storage.hold();
    const deletion = drafts.discard(racingId);
    const edit = drafts.update(
      { ...before, subject: 'Edited during discard' },
      before,
    );
    storage.release();
    await Promise.all([deletion, edit]);
    const after = createDrafts(storage.native, session.registration);
    await after.load();
    expect(ready(after.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({
        subject: 'Edited during discard',
        conflict: true,
      }),
    ]);
  });

  it('shows each Product Account only its own Drafts', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = await drafts.create(alex);
    expect(ready(drafts.getSnapshot()).drafts).toHaveLength(1);

    // Signing out forgets the Drafts in memory; another account opens none of them.
    session.change({ kind: 'signed-out' });
    expect(drafts.getSnapshot()).toStrictEqual({ kind: 'closed' });
    session.change(connected('account-b'));
    await drafts.load();
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
    await drafts.create(alex);
    expect(storage.stored()?.owner).toBe('account-b');
    expect(storage.stored()?.document).not.toContain(id);

    // A save started for one account never reaches the next one's storage.
    storage.hold();
    const pending = drafts.create(other);
    session.change(connected('account-c'));
    storage.release();
    await pending;
    expect(storage.stored()?.owner).toBe('account-b');
  });

  it('reports locked storage and opens once the device is unlocked', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    let locked = true;
    const drafts = createDrafts(
      {
        ...storage.native,
        openDrafts: () =>
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Storage stays locked until the device unlocks.
          locked
            ? Promise.reject(
                Object.assign(new Error('locked'), { code: 'locked' }),
              )
            : storage.native.openDrafts(),
      },
      session.registration,
    );
    await drafts.load();
    expect(drafts.getSnapshot()).toStrictEqual({ kind: 'locked' });
    locked = false;
    await drafts.load();
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */
});
