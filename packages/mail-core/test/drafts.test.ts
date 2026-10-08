import { execFileSync } from 'node:child_process';

import * as Schema from 'effect/Schema';

import type { Draft, DraftsState } from '../src/drafts.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';
import type {
  Asset,
  Block,
  SemanticDocument,
} from '../src/semantic-document.ts';

import { createComposerNavigation } from '../src/composer-navigation.ts';
import {
  addRecipients,
  assetsOf,
  createDrafts,
  draftSummary,
  isEmptyDraft,
  recipientSummary,
  draftOf,
  draftsOf,
  sendingStateOf,
  unsendableAssets,
} from '../src/drafts.ts';
import { mailboxesOf } from '../src/registration.ts';
import {
  applyText,
  BlockKindSchema,
  displayOf,
  emptyDocument,
  historyOf,
  imageCharacter,
  imagesOf,
  insertImage,
  marksAt,
  plainText,
  previewOf,
  record,
  redo,
  SemanticDocumentSchema,
  setBlockKind,
  toggled,
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

// A complete asset's verified fields, or a failed test.
const completed = (asset: Asset | undefined) => {
  if (asset?.state !== 'complete') {
    throw new Error('Expected a complete asset');
  }
  return asset;
};

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

  it('reports the marks typed text inherits at every caret, including block starts and list markers', () => {
    expect.hasAssertions();
    const bold = toggleMark(
      typed(emptyDocument, 'Hi'),
      { start: 0, end: 2 },
      'bold',
    );
    // The Bold control shows what typing at the caret applies, so toggling it turns bold off.
    expect(marksAt(bold, { start: 0, end: 0 })).toStrictEqual(['bold']);
    const typedAtStart = applyText(bold, 'XHi').document;
    expect(typedAtStart[0]?.spans).toStrictEqual([
      { text: 'XHi', marks: ['bold'] },
    ]);
    const plain = applyText(bold, 'XHi', {
      marks: toggled(marksAt(bold, { start: 0, end: 0 }), 'bold'),
    });
    expect(plain.document[0]?.spans).toStrictEqual([
      { text: 'X' },
      { text: 'Hi', marks: ['bold'] },
    ]);

    const document: SemanticDocument = [
      { kind: 'paragraph', spans: [] },
      ...BlockKindSchema.literals.flatMap((kind) => [
        {
          kind,
          spans: [
            { text: 'B', marks: ['bold'] as const },
            { text: 'P' },
            { text: 'I😀', marks: ['italic'] as const },
          ],
        },
        { kind, spans: [] },
      ]),
      // Marker width changes at the tenth consecutive numbered item.
      ...Array.from({ length: 11 }, () => ({
        kind: 'numbered' as const,
        spans: [{ text: 'N', marks: ['bold'] as const }],
      })),
    ];
    const before = displayOf(document).text;
    for (let at = 0; at <= before.length; at += 1) {
      const selection = { start: at, end: at };
      const marks = marksAt(document, selection);
      const next = `${before.slice(0, at)}X${before.slice(at)}`;
      const inserted = applyText(document, next, { selection }).document;
      // Check the actual inserted character after marker normalization, not another caret lookup.
      const insertedMarks = (edited: SemanticDocument) =>
        edited.flatMap(({ spans }) =>
          spans
            .filter(({ text }) => text.includes('X'))
            .map(({ marks = [] }) => marks),
        );
      expect(insertedMarks(inserted)).toStrictEqual([marks]);
      const override = toggled(marks, 'bold');
      expect(
        insertedMarks(
          applyText(document, next, { selection, marks: override }).document,
        ),
      ).toStrictEqual([override]);
    }
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

  it('previews the start of a body on one line without reading the rest', () => {
    expect.hasAssertions();
    const short: SemanticDocument = [
      { kind: 'heading1', spans: [{ text: 'Plan' }] },
      {
        kind: 'paragraph',
        spans: [{ text: 'Ship ' }, { text: 'today', marks: ['bold'] }],
      },
    ];
    expect(previewOf(short)).toBe(plainText(short).replaceAll('\n', ' '));
    const blank: Block = { kind: 'paragraph', spans: [] };
    const text: Block = { kind: 'paragraph', spans: [{ text: ' text ' }] };
    for (const [body, expected] of [
      [[blank], ''],
      [[blank, blank, blank], '  '],
      [[blank, text, blank], '  text  '],
      [[{ kind: 'paragraph', spans: [{ text: ' \t\r ' }] }], ' \t\r '],
    ] satisfies ReadonlyArray<readonly [SemanticDocument, string]>) {
      expect(previewOf(body)).toBe(expected);
      expect(previewOf(body)).toBe(plainText(body).replaceAll('\n', ' '));
    }
    // A complete emoji at the cut stays intact, even when its pair crosses marked spans.
    const split: SemanticDocument = [
      {
        kind: 'paragraph',
        spans: [{ text: 'a\uD83D' }, { text: '\uDE00b', marks: ['bold'] }],
      },
    ];
    expect(previewOf(split, 2)).toBe('a');
    expect(previewOf(split, 3)).toBe('a😀');
    // A bounded prefix is read, and a surrogate pair is never split.
    const reads: number[] = [];
    const counted = (text: string): Block => ({
      kind: 'paragraph',
      spans: [
        {
          get text() {
            reads.push(text.length);
            return text;
          },
        },
      ],
    });
    const long: SemanticDocument = [
      counted(`${'a'.repeat(9)}😀`),
      ...Array.from({ length: 1000 }, () => counted('b'.repeat(1000))),
    ];
    expect(previewOf(long, 10)).toBe('a'.repeat(9));
    expect(reads).toStrictEqual([11]);
    expect(previewOf(long, 30)).toHaveLength(30);
    expect(reads).toHaveLength(3);
  });

  it('rebuilds only the edited block, so history versions share the rest', () => {
    expect.hasAssertions();
    const before: SemanticDocument = [
      { kind: 'paragraph', spans: [{ text: 'First' }] },
      { kind: 'quote', spans: [{ text: 'Second', marks: ['bold'] }] },
      { kind: 'paragraph', spans: [{ text: 'Third' }] },
    ];
    const after = applyText(before, 'First\nSecond!\nThird', {
      selection: { start: 13, end: 13 },
    }).document;
    expect(after[0]).toBe(before[0]);
    expect(after[2]).toBe(before[2]);
    expect(after[1]).toStrictEqual({
      kind: 'quote',
      spans: [{ text: 'Second!', marks: ['bold'] }],
    });
    const marked = toggleMark(after, { start: 6, end: 13 }, 'italic');
    const quoted = setBlockKind(
      marked,
      { start: 6, end: 13 },
      'heading1',
    ).document;
    const history = record(record(historyOf(before), after), quoted);
    expect(undo(history).present).toBe(after);
    expect(redo(undo(history)).present).toBe(quoted);
    for (const version of [...history.past, history.present]) {
      expect(version[0]).toBe(before[0]);
      expect(version[2]).toBe(before[2]);
    }
    expect(before[1]?.spans).toStrictEqual([
      { text: 'Second', marks: ['bold'] },
    ]);
  });

  it('keeps long-paragraph undo history compact instead of retaining expanded character arrays', () => {
    expect.hasAssertions();
    // An isolated Node heap and explicit GC make this a retained-memory check, not a timing test.
    const source = new URL('../src/semantic-document.ts', import.meta.url).href;
    const retained = Number(
      execFileSync(
        process.execPath,
        [
          '--expose-gc',
          '--input-type=module',
          '--eval',
          `
        import { applyText, historyOf, record } from ${JSON.stringify(source)};
        let history = historyOf([{ kind: 'paragraph', spans: [{ text: 'x'.repeat(100_000) }] }]);
        globalThis.gc();
        const before = process.memoryUsage().heapUsed;
        for (let i = 0; i < 100; i += 1) {
          const text = history.present[0].spans.map(({ text }) => text).join('') + ' word';
          history = record(history, applyText(history.present, text).document);
        }
        globalThis.gc();
        console.log(process.memoryUsage().heapUsed - before);
        if (history.past.length !== 100 || history.present[0].spans[0].text.length !== 100_500) {
          process.exitCode = 1;
        }
      `,
        ],
        { encoding: 'utf8', timeout: 20_000 },
      ),
    );
    // The strings need roughly 10 MiB; expanded arrays retained by the old cache need over 120 MiB.
    expect(retained).toBeLessThan(64 * 1024 * 1024);
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

// A regular expression result as Hermes can return it: positional captures without `groups`.
const nativeExec = RegExp.prototype.exec;
function withoutNamedGroups(this: RegExp, text: string) {
  const result = nativeExec.call(this, text);
  if (result !== null) {
    delete result.groups;
  }
  return result;
}

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
    // The entry still being typed is part of the Draft, so it is saved with every edit.
    expect(named.draft.entries).toStrictEqual({ to: 'partial' });
    expect(named.notice).toBeUndefined();

    const invalid = addRecipients(named.draft, {
      field: 'cc',
      text: 'not an address',
      all: true,
    });
    expect(invalid.notice).toBe('invalid');
    expect(invalid.text).toBe('not an address');
    expect(invalid.draft.cc).toStrictEqual([]);
    expect(invalid.draft.entries).toStrictEqual({
      to: 'partial',
      cc: 'not an address',
    });

    const duplicate = addRecipients(named.draft, {
      field: 'bcc',
      text: 'MAYA@example.com',
      all: true,
    });
    expect(duplicate.notice).toBe('duplicate');
    expect(duplicate.text).toBe('');
    expect(duplicate.draft.bcc).toStrictEqual([]);
  });

  it('summarizes recipients by their To, Cc and Bcc roles', () => {
    expect.hasAssertions();
    expect(recipientSummary(draft)).toBe('No recipients');
    expect(
      recipientSummary({
        ...draft,
        bcc: [{ name: 'Maya Chen', address: 'maya@example.com' }],
      }),
    ).toBe('Bcc Maya Chen');
    expect(
      recipientSummary({
        ...draft,
        to: [
          { name: 'Oliver', address: 'oliver@example.com' },
          { address: 'alex@example.invalid' },
        ],
        cc: [{ name: 'Maya Chen', address: 'maya@example.com' }],
        bcc: [{ address: 'private@example.invalid' }],
      }),
    ).toBe(
      'To Oliver, alex@example.invalid · Cc Maya Chen · Bcc private@example.invalid',
    );
    // A row shows one line: the summary stops reading recipients once that line is full.
    let reads = 0;
    const many = Array.from({ length: 10_000 }, (_, index) => ({
      get address() {
        reads += 1;
        return `person-${index}@example.invalid`;
      },
    }));
    const summary = recipientSummary({ ...draft, to: many }, 40);
    expect(summary).toBe('To person-0@example.invalid, person-1@ex');
    expect(reads).toBe(2);
    // A shortened row cannot mistake a surrogate cut for an exact-length summary.
    expect(
      draftSummary({
        ...draft,
        to: [
          { name: `${'x'.repeat(297)}😀tail`, address: 'a@example.invalid' },
        ],
      }),
    ).toMatchObject({
      recipients: `To ${'x'.repeat(297)}`,
      shortened: true,
    });
    expect(
      draftSummary({
        ...draft,
        to: [{ name: 'x'.repeat(297), address: 'a@example.invalid' }],
      }),
    ).toMatchObject({
      recipients: `To ${'x'.repeat(297)}`,
      shortened: false,
    });
  });

  it('decides emptiness from the first non-whitespace character without joining the body', () => {
    expect.hasAssertions();
    const reads: string[] = [];
    const span = (text: string) => ({
      get text() {
        reads.push(text);
        return text;
      },
    });
    const body: SemanticDocument = [
      { kind: 'paragraph', spans: [span('  ')] },
      { kind: 'paragraph', spans: [span('Kept'), span('unread')] },
      { kind: 'paragraph', spans: [span('unread')] },
    ];
    expect(isEmptyDraft({ ...draft, body })).toBe(false);
    expect(reads).toStrictEqual(['  ', 'Kept']);
    expect(
      isEmptyDraft({
        ...draft,
        subject: ' \n',
        body: [{ kind: 'quote', spans: [span(' ')] }],
      }),
    ).toBe(true);
    // trim() treats BOM/ZWNBSP as whitespace, but preserves a zero-width space.
    for (const text of ['\uFEFF', '\u00A0\u2028\u2029', '\u200B']) {
      expect(isEmptyDraft({ ...draft, subject: text })).toBe(
        text.trim() === '',
      );
      expect(
        isEmptyDraft({
          ...draft,
          body: [{ kind: 'code', spans: [span(text)] }],
        }),
      ).toBe(text.trim() === '');
    }
  });

  it('parses named recipients when regular expression results carry no named groups, as on Hermes', () => {
    expect.hasAssertions();
    const spy = vi
      .spyOn(RegExp.prototype, 'exec')
      .mockImplementation(withoutNamedGroups);
    const added = addRecipients(draft, {
      field: 'to',
      text: 'Maya Chen <maya@example.com>, "Park, Oliver" <oliver@example.com>',
      all: true,
    });
    spy.mockRestore();
    expect(added.draft.to).toStrictEqual([
      { name: 'Maya Chen', address: 'maya@example.com' },
      { name: 'Park, Oliver', address: 'oliver@example.com' },
    ]);
    expect(added.notice).toBeUndefined();
  });
  /* oxlint-enable vitest/max-expects */
});

describe('storing Drafts', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one storage path end to end. */
  it('preserves unfinished recipients across concurrent saves and refuses empty-only disposal', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = await first.create(alex);
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    // A document written before entries existed still opens with no pending text.
    const before = present(draftOf(second.getSnapshot(), id), 'legacy Draft');
    expect(before.entries).toBeUndefined();

    storage.hold();
    const initialEntry = addRecipients(before, {
      field: 'to',
      text: 'm',
    }).draft;
    const initialSave = first.update(initialEntry, before);
    const latestEntry = addRecipients(initialEntry, {
      field: 'to',
      text: 'maya@exa',
    }).draft;
    const latestSave = first.update(latestEntry, initialEntry);
    storage.release();
    await Promise.all([initialSave, latestSave]);

    // An older storage writer's entry must preserve both independently authored versions.
    const otherEntry = addRecipients(before, {
      field: 'cc',
      text: 'oliv',
    }).draft;
    await second.update(otherEntry, before);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual(
      expect.arrayContaining([
        expect.objectContaining({ id, entries: { to: 'maya@exa' } }),
        expect.objectContaining({ conflict: true, entries: { cc: 'oliv' } }),
      ]),
    );
    await expect(
      reopened.discard(before.id, { onlyIfEmpty: true }),
    ).resolves.toBe(true);
    expect(draftOf(reopened.getSnapshot(), id)?.entries).toStrictEqual({
      to: 'maya@exa',
    });

    // The shared store also preserves entries from two stale editors in one process.
    const current = present(
      draftOf(reopened.getSnapshot(), id),
      'current Draft',
    );
    await reopened.update(
      addRecipients(current, { field: 'to', text: 'maya@exam' }).draft,
      current,
    );
    // The stale editor's version becomes a copy it is told about, so it keeps editing its own.
    const moved: string[] = [];
    const saving = reopened.update(
      addRecipients(current, { field: 'to', text: 'maya@examp' }).draft,
      current,
      (copy) => {
        moved.push(copy);
      },
    );
    expect(moved).toStrictEqual([`${id}-conflict-1`]);
    await saving;
    const final = createDrafts(storage.native, session.registration);
    await final.load();
    expect(ready(final.getSnapshot()).drafts).toStrictEqual(
      expect.arrayContaining([
        expect.objectContaining({ id, entries: { to: 'maya@exam' } }),
        expect.objectContaining({
          id: `${id}-conflict-1`,
          entries: { to: 'maya@examp' },
          conflict: true,
        }),
      ]),
    );
  });

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

  it('starts no Draft from a sender that stopped sending while the open composer saved', async () => {
    expect.hasAssertions();
    const cases: ReadonlyArray<readonly RegistrationSnapshot[]> = [
      [connected('account-a', [alex, { ...other, state: 'authorization' }])],
      [connected('account-a', [alex])],
      [
        connected('account-b', [
          { id: 'connection-b', address: 'b@example.invalid' },
        ]),
      ],
      [connected('account-b', [{ ...other, address: 'b@example.invalid' }])],
      [connected('account-b', [other])],
      [{ kind: 'signed-out' }, connected('account-a')],
    ];
    for (const changes of cases) {
      const session = account(connected('account-a'));
      const storage = createSyntheticDrafts(session.productAccount);
      const drafts = createDrafts(storage.native, session.registration);
      await drafts.load();
      const navigation = createComposerNavigation();
      // The open composer's save finishes after replacement Drafts are already ready, including
      // a replacement with the same sender and sign-out/re-entry into the same Product Account.
      const unregister = navigation.register(async () => {
        for (const next of changes) {
          session.change(next);
        }
        await drafts.load();
        return true;
      });
      await expect(navigation.create(drafts, other)).resolves.toBeUndefined();
      expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
      unregister();
      const reopened = createDrafts(storage.native, session.registration);
      await reopened.load();
      expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([]);
    }
  });

  it('does not start a stale New Message when replacement Drafts are still opening', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const opening = Promise.withResolvers<undefined>();
    let held: Promise<undefined> | undefined = undefined;
    const drafts = createDrafts(
      {
        ...storage.native,
        openDrafts: async () => {
          await held;
          return storage.native.openDrafts();
        },
      },
      session.registration,
    );
    await drafts.load();
    held = opening.promise;
    const navigation = createComposerNavigation();
    navigation.register(async () => {
      session.change(connected('account-b', [other]));
      return true;
    });
    await expect(navigation.create(drafts, other)).resolves.toBeUndefined();
    expect(drafts.getSnapshot()).toStrictEqual({ kind: 'loading' });
    opening.resolve(undefined);
    await drafts.load();
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([]);
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
          id: secondId,
          subject: 'Window A subject',
        }),
        expect.objectContaining({
          body: typed(emptyDocument, 'Window B body'),
          conflict: true,
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

  it('ignores a previous account editor after the next account has loaded', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft id');
    const before = present(draftOf(drafts.getSnapshot(), id), 'Draft');
    session.change(connected('account-b'));
    await drafts.load();
    const revision = storage.stored()?.revision;
    await expect(
      drafts.update({ ...before, subject: 'Previous account content' }, before),
    ).resolves.toBe(true);
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
    expect(storage.stored()?.revision).toBe(revision);
  });

  it('deletes the Draft its editor holds when deletion runs, after earlier saves', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft');
    const before = present(draftOf(drafts.getSnapshot(), id), 'Draft');
    const other = createDrafts(storage.native, session.registration);
    await other.load();
    await other.update({ ...before, subject: 'Other writer' }, before);
    // The held autosave rebases this editor onto its own conflict copy.
    let target = id;
    storage.hold();
    const saving = drafts.update(
      { ...before, subject: 'Queued' },
      before,
      (copy) => {
        target = copy;
      },
    );
    const deletion = drafts.discard(() => target);
    storage.release();
    await Promise.all([saving, deletion]);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(
      ready(reopened.getSnapshot()).drafts.map(({ id: each, subject }) => [
        each,
        subject,
      ]),
    ).toStrictEqual([[id, 'Other writer']]);
  });

  it('discards a Draft after another store saved a newer revision', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const discarded = present(await first.create(alex), 'discarded Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    // The first store saves again, so the second store's revision is stale.
    const other = present(await first.create(alex), 'other Draft');
    await expect(second.discard(discarded)).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(
      ready(reopened.getSnapshot()).drafts.map(({ id }) => id),
    ).toStrictEqual([other]);
  });

  it("keeps another store's completed Draft on empty-only disposal and finishes saving", async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const before = present(draftOf(first.getSnapshot(), id), 'empty Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    await first.update({ ...before, subject: 'Completed elsewhere' }, before);
    await expect(second.discard(id, { onlyIfEmpty: true })).resolves.toBe(true);
    expect(ready(second.getSnapshot()).save).toBe('saved');
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(draftOf(reopened.getSnapshot(), id)?.subject).toBe(
      'Completed elsewhere',
    );
  });

  it("keeps another store's edit to a Draft this store discards from a stale revision", async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    // The first store completes an edit the second store has not seen; the second discards.
    const before = present(draftOf(first.getSnapshot(), id), 'shared Draft');
    await first.update({ ...before, subject: 'Edited elsewhere' }, before);
    await expect(second.discard(id)).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(draftOf(reopened.getSnapshot(), id)?.subject).toBe(
      'Edited elsewhere',
    );
  });

  it('stops moving an editor released after a refused save, and keeps its edit', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    const before = present(draftOf(second.getSnapshot(), id), 'shared Draft');
    const moves: string[] = [];
    const moved = (copy: string) => {
      moves.push(copy);
    };
    storage.failNextCommit('locked');
    await expect(
      second.update({ ...before, subject: 'Closed window' }, before, moved),
    ).resolves.toBe(false);
    // The window closes while storage refused its edit; recovery later copies that edit.
    second.release(moved);
    await first.update({ ...before, subject: 'Other store' }, before);
    await expect(second.save()).resolves.toBe(true);
    expect(moves).toStrictEqual([]);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(
      ready(reopened.getSnapshot()).drafts.map(({ subject }) => subject),
    ).toStrictEqual(expect.arrayContaining(['Other store', 'Closed window']));
  });

  it('moves every editor bound to an unsaved version when storage recovery copies it', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    const before = present(draftOf(second.getSnapshot(), id), 'shared Draft');
    await first.update({ ...before, subject: 'Other store' }, before);
    // Two editors of the second store write the same version before its save completes.
    const moves: string[] = [];
    storage.hold();
    const firstEditor = second.update(
      { ...before, subject: 'Same' },
      before,
      (copy) => {
        moves.push(`first ${copy}`);
      },
    );
    const secondEditor = second.update(
      { ...before, subject: 'Same' },
      before,
      (copy) => {
        moves.push(`second ${copy}`);
      },
    );
    storage.release();
    await Promise.all([firstEditor, secondEditor]);
    const copy = present(
      ready(second.getSnapshot()).drafts.find(
        ({ subject }) => subject === 'Same',
      ),
      'bound copy',
    );
    expect(moves).toStrictEqual([`first ${copy.id}`, `second ${copy.id}`]);
    await second.discard(() =>
      present(moves[0]?.split(' ')[1], 'editor target'),
    );
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toMatchObject([
      { id, subject: 'Other store' },
    ]);
  });

  it('does not notify an editor for a version it left during another editor notification', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const otherId = present(await first.create(other), 'other Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    const before = present(draftOf(second.getSnapshot(), id), 'shared Draft');
    const otherBefore = present(
      draftOf(second.getSnapshot(), otherId),
      'other Draft',
    );
    await first.update({ ...before, subject: 'Other store' }, before);
    const moves: string[] = [];
    const moved = (copy: string) => {
      moves.push(copy);
    };
    let following: Promise<boolean> | undefined = undefined;
    storage.hold();
    const firstEditor = second.update(
      { ...before, subject: 'Same' },
      before,
      () => {
        following = second.update(
          { ...otherBefore, subject: 'New editor target' },
          otherBefore,
          moved,
        );
      },
    );
    const secondEditor = second.update(
      { ...before, subject: 'Same' },
      before,
      moved,
    );
    storage.release();
    await Promise.all([firstEditor, secondEditor]);
    await present(following, 'reentrant edit');
    expect(moves).toStrictEqual([]);
    expect(draftOf(second.getSnapshot(), otherId)?.subject).toBe(
      'New editor target',
    );
  });

  it('writes nothing for an editor that changed nothing while another editor or store moved on', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    const before = present(draftOf(second.getSnapshot(), id), 'shared Draft');
    await first.update({ ...before, subject: 'Other store' }, before);
    const revision = storage.stored()?.revision;
    // Equal content, even in a fresh payload with a different edit time, is not an edit.
    for (const editor of [first, second]) {
      await expect(
        editor.update({ ...before, updatedAt: before.updatedAt + 1 }, before),
      ).resolves.toBe(true);
      expect(storage.stored()?.revision).toBe(revision);
      expect(
        ready(editor.getSnapshot()).drafts.map(({ id: each }) => each),
      ).toStrictEqual([id]);
    }
  });

  it('keeps the later edit time when two stores save the same content', async () => {
    expect.hasAssertions();
    const earlier = 1_800_000_000_000;
    const committing = Promise.withResolvers<undefined>();
    const held = Promise.withResolvers<undefined>();
    vi.useFakeTimers({ now: earlier, toFake: ['Date'] });
    try {
      const session = account(connected('account-a'));
      const storage = createSyntheticDrafts(session.productAccount);
      const first = createDrafts(storage.native, session.registration);
      await first.load();
      const id = present(await first.create(alex), 'Draft');
      const otherId = present(await first.create(other), 'other Draft');
      const second = createDrafts(
        {
          ...storage.native,
          commitDrafts: async (...args) => {
            committing.resolve(undefined);
            await held.promise;
            return storage.native.commitDrafts(...args);
          },
        },
        session.registration,
      );
      await second.load();
      const before = present(draftOf(second.getSnapshot(), id), 'shared Draft');
      // Hold only the earlier writer until both later edits are durable.
      const stale = second.update({ ...before, subject: 'Same' }, before);
      await committing.promise;
      vi.setSystemTime(earlier + 30_000);
      const between = present(
        draftOf(first.getSnapshot(), otherId),
        'other Draft',
      );
      await first.update({ ...between, subject: 'Between' }, between);
      const later = earlier + 60_000;
      vi.setSystemTime(later);
      await first.update({ ...before, subject: 'Same' }, before);
      held.resolve(undefined);
      await stale;
      const reopened = createDrafts(storage.native, session.registration);
      await reopened.load();
      expect(draftOf(reopened.getSnapshot(), id)?.updatedAt).toBe(later);
      expect(
        draftsOf(reopened.getSnapshot()).map(({ id: each }) => each),
      ).toStrictEqual([id, otherId]);
    } finally {
      held.resolve(undefined);
      vi.useRealTimers();
    }
  });

  it("keeps another editor's newer content when a stale editor of the same store discards", async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft');
    const shown = present(
      draftOf(drafts.getSnapshot(), id),
      'stale editor view',
    );
    // Another window of this store saves an edit; the stale window still shows the old version.
    await drafts.update({ ...shown, subject: 'Newer edit' }, shown);
    await expect(drafts.discard(id, { expected: () => shown })).resolves.toBe(
      true,
    );
    expect(draftOf(drafts.getSnapshot(), id)?.subject).toBe('Newer edit');
  });

  it('discards the rebound copy when an edit arrives during a stale deletion', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft');
    const before = present(draftOf(first.getSnapshot(), id), 'shared Draft');
    const waiting = Promise.withResolvers<undefined>();
    const entered = Promise.withResolvers<undefined>();
    let held = false;
    const second = createDrafts(
      {
        ...storage.native,
        commitDrafts: async (...args) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Hold only the stale deletion at the native boundary.
          if (held) {
            held = false;
            entered.resolve(undefined);
            await waiting.promise;
          }
          return storage.native.commitDrafts(...args);
        },
      },
      session.registration,
    );
    await second.load();
    held = true;
    let target = id;
    const deleting = second.discard(() => target);
    await entered.promise;
    const editing = second.update(
      { ...before, subject: 'This editor' },
      before,
      (copy) => {
        target = copy;
      },
    );
    await first.update({ ...before, subject: 'Other editor' }, before);
    waiting.resolve(undefined);
    await expect(deleting).resolves.toBe(true);
    await editing;
    expect(target).not.toBe(id);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({ id, subject: 'Other editor' }),
    ]);
  });

  it.each([
    ['conflict', 'failed'],
    ['unavailable', 'failed'],
    ['locked', 'locked'],
  ] as const)(
    'publishes %s after the single stale-deletion retry and keeps the Draft retryable',
    async (code, save) => {
      expect.hasAssertions();
      const session = account(connected('account-a'));
      const storage = createSyntheticDrafts(session.productAccount);
      const first = createDrafts(storage.native, session.registration);
      await first.load();
      const id = present(await first.create(alex), 'Draft');
      let failAfterRebase = false;
      const second = createDrafts(
        {
          ...storage.native,
          openDrafts: async () => {
            const opened = await storage.native.openDrafts();
            // oxlint-disable-next-line vitest/no-conditional-in-test -- Fail the retry after opening the conflicting revision.
            if (failAfterRebase) {
              failAfterRebase = false;
              storage.failNextCommit(code);
            }
            return opened;
          },
        },
        session.registration,
      );
      await second.load();
      const other = present(await first.create(alex), 'other Draft');
      failAfterRebase = true;
      await expect(second.discard(id)).resolves.toBe(false);
      expect(ready(second.getSnapshot()).save).toBe(save);
      expect(draftOf(second.getSnapshot(), id)?.id).toBe(id);
      await expect(second.discard(id)).resolves.toBe(true);
      const reopened = createDrafts(storage.native, session.registration);
      await reopened.load();
      expect(
        ready(reopened.getSnapshot()).drafts.map(({ id: each }) => each),
      ).toStrictEqual([other]);
    },
  );

  it.each([
    { transition: 'signed-out', next: [{ kind: 'signed-out' }] as const },
    { transition: 'different-account', next: [connected('account-b')] },
    {
      transition: 'same-account-return',
      next: [{ kind: 'signed-out' } as const, connected('account-a')],
    },
  ])(
    'returns no Draft for a New Message started before the account changed ($transition)',
    async ({ next }) => {
      expect.hasAssertions();
      const session = account(connected('account-a'));
      const storage = createSyntheticDrafts(session.productAccount);
      const drafts = createDrafts(storage.native, session.registration);
      await drafts.load();
      storage.hold();
      const pending = drafts.create(alex);
      for (const snapshot of next) {
        session.change(snapshot);
      }
      storage.release();
      await expect(pending).resolves.toBeUndefined();
    },
  );

  it('keeps an authored edit that arrives after its Draft was deleted', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft id');
    const before = present(draftOf(drafts.getSnapshot(), id), 'Draft');
    await expect(drafts.discard(id, { onlyIfEmpty: true })).resolves.toBe(true);
    const revision = storage.stored()?.revision;
    // An empty late edit changes nothing, not even storage.
    await expect(drafts.update(before, before)).resolves.toBe(true);
    expect(storage.stored()?.revision).toBe(revision);
    // An authored one survives as a copy its editor is told about.
    const moved: string[] = [];
    await drafts.update({ ...before, subject: 'Late edit' }, before, (copy) => {
      moved.push(copy);
    });
    expect(moved).toStrictEqual([`${id}-conflict-1`]);
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({
        id: `${id}-conflict-1`,
        subject: 'Late edit',
        conflict: true,
      }),
    ]);
  });

  it('flushes earlier failed work when an empty late edit changes nothing', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'Draft id');
    const empty = present(draftOf(drafts.getSnapshot(), id), 'Empty Draft');
    await drafts.discard(id);
    const keptId = present(await drafts.create(alex), 'Kept Draft id');
    const kept = present(draftOf(drafts.getSnapshot(), keptId), 'Kept Draft');
    storage.failNextCommit('locked');
    await expect(
      drafts.update({ ...kept, subject: 'Still needs saving' }, kept),
    ).resolves.toBe(false);
    await expect(drafts.update(empty, empty)).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({ id: keptId, subject: 'Still needs saving' }),
    ]);
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
    let followed = racingId;
    const edit = drafts.update(
      { ...before, subject: 'Edited during discard' },
      before,
      (copy) => {
        followed = copy;
      },
    );
    storage.release();
    await Promise.all([deletion, edit]);
    const after = createDrafts(storage.native, session.registration);
    await after.load();
    expect(ready(after.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({
        id: followed,
        subject: 'Edited during discard',
        conflict: true,
      }),
    ]);
  });

  it('drops an abandoned empty Draft at the next save after storage refused it', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    storage.failNextCommit('locked');
    const id = present(await drafts.create(alex), 'Draft id');
    storage.failNextCommit('locked');
    await expect(drafts.abandon(id)).resolves.toBe(false);
    expect(draftOf(drafts.getSnapshot(), id)).toBeUndefined();
    // Recovery saves without the abandoned Draft, while a Draft that gained content stays.
    const kept = present(await drafts.create(alex), 'kept Draft');
    const empty = present(draftOf(drafts.getSnapshot(), kept), 'kept editor');
    await drafts.update({ ...empty, subject: 'Typed meanwhile' }, empty);
    await expect(drafts.abandon(kept)).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({ id: kept, subject: 'Typed meanwhile' }),
    ]);
  });

  it('keeps a late authored edit after abandoning an unsaved empty Draft', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    storage.failNextCommit('locked');
    const id = present(await drafts.create(alex), 'Draft id');
    const empty = present(draftOf(drafts.getSnapshot(), id), 'empty editor');
    storage.failNextCommit('locked');
    await drafts.abandon(id);
    storage.failNextCommit('locked');
    await expect(drafts.update(empty, empty)).resolves.toBe(false);
    expect(ready(drafts.getSnapshot()).drafts).toStrictEqual([]);
    let followed = id;
    storage.failNextCommit('locked');
    await expect(
      drafts.update({ ...empty, subject: 'Late content' }, empty, (copy) => {
        followed = copy;
      }),
    ).resolves.toBe(false);
    expect(followed).not.toBe(id);
    await expect(drafts.save()).resolves.toBe(true);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([
      expect.objectContaining({
        id: followed,
        subject: 'Late content',
        conflict: true,
      }),
    ]);
  });

  it.each([
    { subject: '', retained: [] },
    { subject: 'Other writer', retained: [{ subject: 'Other writer' }] },
  ])(
    'rebases abandoned deletion without losing concurrent content ($subject)',
    async ({ subject, retained }) => {
      expect.hasAssertions();
      const session = account(connected('account-a'));
      const storage = createSyntheticDrafts(session.productAccount);
      const first = createDrafts(storage.native, session.registration);
      await first.load();
      const id = present(await first.create(alex), 'Draft id');
      const second = createDrafts(storage.native, session.registration);
      await second.load();
      const empty = present(draftOf(second.getSnapshot(), id), 'other editor');
      const independent = present(
        await second.create(other),
        'independent Draft',
      );
      await second.update({ ...empty, subject }, empty);
      await expect(first.abandon(id)).resolves.toBe(true);
      expect(ready(first.getSnapshot()).save).toBe('saved');
      const reopened = createDrafts(storage.native, session.registration);
      await reopened.load();
      expect(ready(reopened.getSnapshot()).drafts).toStrictEqual([
        ...retained.map((content) =>
          expect.objectContaining({ id, ...content }),
        ),
        expect.objectContaining({ id: independent }),
      ]);
    },
  );

  it('keeps an editor bound to its copy when another storage writer chose the same copy ID', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const first = createDrafts(storage.native, session.registration);
    await first.load();
    const id = present(await first.create(alex), 'Draft id');
    const before = present(draftOf(first.getSnapshot(), id), 'shared Draft');
    const second = createDrafts(storage.native, session.registration);
    await second.load();
    await first.update({ ...before, subject: 'First latest' }, before);
    await second.update({ ...before, subject: 'Second latest' }, before);
    await first.update({ ...before, subject: 'First stale' }, before);
    let followed = id;
    // Retain the binding through a failed save: Retry may be the operation that rebases it.
    storage.failNextCommit('unavailable');
    await expect(
      second.update({ ...before, subject: 'Second stale' }, before, (copy) => {
        followed = copy;
      }),
    ).resolves.toBe(false);
    await second.save();
    expect(draftOf(second.getSnapshot(), followed)?.subject).toBe(
      'Second stale',
    );
    await second.discard(followed);
    const reopened = createDrafts(storage.native, session.registration);
    await reopened.load();
    expect(
      ready(reopened.getSnapshot()).drafts.map(({ subject }) => subject),
    ).toStrictEqual(
      expect.arrayContaining(['First latest', 'Second latest', 'First stale']),
    );
    expect(ready(reopened.getSnapshot()).drafts).toHaveLength(3);
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

describe('adding files and images to Drafts', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one asset path end to end. */
  const file = (uri: string, name: string, type = 'application/pdf') =>
    ({ name, type, source: { kind: 'file', uri } }) as const;

  // A store, its storage and a new Draft from alex's mailbox.
  const opened = async () => {
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount);
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = present(await drafts.create(alex), 'a new Draft');
    const draft = () => present(draftOf(drafts.getSnapshot(), id), 'the Draft');
    return { session, storage, drafts, id, draft };
  };

  it('places, removes and restores an inline image with the text around it', () => {
    expect.hasAssertions();
    const image = {
      id: 'image0001',
      name: 'chart.png',
      type: 'image/png',
      state: 'importing',
    } as const;
    const before = typed(emptyDocument, 'Before after');
    const inserted = insertImage(before, { start: 7, end: 7 }, image);
    expect(displayOf(inserted.document).text).toBe(
      `Before ${imageCharacter}after`,
    );
    expect(inserted.selection).toStrictEqual({ start: 8, end: 8 });
    expect(imagesOf(inserted.document)).toStrictEqual([image]);
    // The stored form round-trips, and typed text around it keeps the reference.
    const encoded = Schema.encodeSync(
      Schema.fromJsonString(SemanticDocumentSchema),
    )(inserted.document);
    expect(
      Schema.decodeSync(Schema.fromJsonString(SemanticDocumentSchema))(encoded),
    ).toStrictEqual(inserted.document);
    const typedAround = applyText(
      inserted.document,
      `Before ${imageCharacter}and after`,
    ).document;
    expect(imagesOf(typedAround)).toStrictEqual([image]);
    // A typed or pasted replacement character never becomes an image.
    const pasted = applyText(before, `Before ${imageCharacter}after`).document;
    expect(imagesOf(pasted)).toStrictEqual([]);
    expect(displayOf(pasted).text).toBe('Before after');
    // Deleting the character removes the image; Undo restores the same reference.
    const history = record(
      historyOf(typedAround),
      typed(typedAround, 'Before and after'),
    );
    expect(imagesOf(history.present)).toStrictEqual([]);
    expect(imagesOf(undo(history).present)).toStrictEqual([image]);
    // Previews leave images out, and a body with only an image is not empty.
    expect(previewOf(inserted.document)).toBe('Before after');
    expect(
      isEmptyDraft({
        id: 'd',
        connection: alex.id,
        from: alex.address,
        to: [],
        cc: [],
        bcc: [],
        subject: '',
        body: insertImage(emptyDocument, { start: 0, end: 0 }, image).document,
        updatedAt: 0,
      }),
    ).toBe(false);
  });

  it('stores verified bytes under the Draft through relaunch, Undo and deletion', async () => {
    expect.hasAssertions();
    const { session, storage, drafts, id, draft } = await opened();
    storage.addFile('file:///plan.pdf', 'plan bytes');
    storage.addFile('file:///chart.png', 'chart bytes');
    const attachment = drafts.prepare({
      name: ' plan.pdf ',
      type: 'application/pdf',
    });
    const image = drafts.prepare({ name: 'chart.png', type: 'image/png' });
    expect(attachment.name).toBe('plan.pdf');
    const created = draft();
    await drafts.update(
      {
        ...created,
        attachments: [attachment],
        body: insertImage(created.body, { start: 0, end: 0 }, image).document,
      },
      created,
    );
    expect(unsendableAssets(draft())).toHaveLength(2);
    await Promise.all([
      drafts.importAsset(attachment, { kind: 'file', uri: 'file:///plan.pdf' }),
      drafts.importAsset(image, { kind: 'file', uri: 'file:///chart.png' }),
    ]);
    const [stored, inline] = assetsOf(draft());
    expect(stored).toMatchObject({ state: 'complete', size: 10 });
    expect(inline).toMatchObject({ id: image.id, state: 'complete', size: 11 });
    expect(unsendableAssets(draft())).toStrictEqual([]);
    expect(storage.assets().toSorted()).toStrictEqual(
      [attachment.id, image.id].toSorted(),
    );
    // The document names the asset; its bytes never enter it.
    expect(storage.stored()?.document).toContain(attachment.id);
    expect(storage.stored()?.document).not.toContain('plan bytes');

    // Removing the image keeps its bytes for Undo while the Draft exists in this session.
    const complete = draft();
    const removed = { ...complete, body: typed(complete.body, '') };
    await drafts.update(removed, complete);
    expect(storage.assets()).toContain(image.id);
    await drafts.update(complete, removed);
    await expect(drafts.readAsset(completed(inline))).resolves.toStrictEqual({
      kind: 'ready',
      uri: `data:image/png;base64,${btoa('chart bytes')}`,
    });

    // After a relaunch, the reopened Draft keeps both. An image removed then stays for Undo
    // until the next relaunch, whose first save removes it.
    const relaunch = async () => {
      storage.relaunch();
      const store = createDrafts(storage.native, session.registration);
      await store.load();
      return store;
    };
    let relaunched = await relaunch();
    const reopened = present(
      draftOf(relaunched.getSnapshot(), id),
      'the reopened Draft',
    );
    expect(assetsOf(reopened)).toStrictEqual(assetsOf(complete));
    const withoutImage = { ...reopened, body: typed(reopened.body, '') };
    await relaunched.update(withoutImage, reopened);
    expect(storage.assets()).toHaveLength(2);
    relaunched = await relaunch();
    await relaunched.update({ ...withoutImage, subject: 'Plan' }, withoutImage);
    expect(storage.assets()).toStrictEqual([attachment.id]);

    // Discarding the Draft removes its bytes with it.
    await expect(relaunched.discard(id)).resolves.toBe(true);
    expect(storage.assets()).toStrictEqual([]);
  });

  it('keeps cancelled, failed and interrupted imports out of what can be sent', async () => {
    expect.hasAssertions();
    const { session, storage, drafts, id, draft } = await opened();
    storage.addFile('file:///large.mov', 'movie');
    storage.addFile('file:///notes.txt', 'notes');
    const cancelling = drafts.prepare({
      name: 'large.mov',
      type: 'video/quicktime',
    });
    const failing = drafts.prepare({ name: 'missing.txt', type: 'text/plain' });
    const created = draft();
    await drafts.update(
      { ...created, attachments: [cancelling, failing] },
      created,
    );

    // Cancelling while native code copies leaves the asset cancelled and discards its bytes.
    storage.holdImports();
    const copying = drafts.importAsset(cancelling, {
      kind: 'file',
      uri: 'file:///large.mov',
    });
    expect(drafts.getImports().has(cancelling.id)).toBe(true);
    await drafts.cancelImport(cancelling.id);
    expect(drafts.getImports().has(cancelling.id)).toBe(false);
    storage.releaseImports();
    await copying;
    expect(assetsOf(draft())[0]).toMatchObject({ state: 'cancelled' });
    expect(storage.assets()).toStrictEqual([]);

    // Unreadable source bytes fail the import.
    await drafts.importAsset(failing, {
      kind: 'file',
      uri: 'file:///missing.txt',
    });
    expect(assetsOf(draft())[1]).toMatchObject({ state: 'failed' });
    expect(unsendableAssets(draft()).map(({ state }) => state)).toStrictEqual([
      'cancelled',
      'failed',
    ]);

    // An import that a relaunch interrupts stays importing, and its stray bytes never survive.
    const interrupted = drafts.prepare({
      name: 'notes.txt',
      type: 'text/plain',
    });
    const current = draft();
    await drafts.update(
      {
        ...current,
        // This Draft has attachments only, so its assets are its attachments.
        attachments: [...assetsOf(current), interrupted],
      },
      current,
    );
    await storage.native.importDraftAsset('account-a', interrupted.id, {
      kind: 'file',
      uri: 'file:///notes.txt',
    });
    storage.relaunch();
    const relaunched = createDrafts(storage.native, session.registration);
    await relaunched.load();
    expect(relaunched.getImports().size).toBe(0);
    const reopened = present(
      draftOf(relaunched.getSnapshot(), id),
      'the reopened Draft',
    );
    expect(assetsOf(reopened)[2]).toMatchObject({ state: 'importing' });
    await relaunched.update({ ...reopened, subject: 'Notes' }, reopened);
    expect(storage.assets()).toStrictEqual([]);
    expect(unsendableAssets(reopened)).toHaveLength(3);
  });

  it('refuses files over the limits and reports damaged or missing bytes', async () => {
    expect.hasAssertions();
    const session = account(connected('account-a'));
    const storage = createSyntheticDrafts(session.productAccount, {
      outgoingLimit: 600,
    });
    const drafts = createDrafts(storage.native, session.registration);
    await drafts.load();
    const id = await drafts.create(alex);
    storage.addFile('file:///big.bin', 'x'.repeat(400));
    storage.addFile('file:///small.txt', 'small');
    const big = drafts.prepare({ name: 'big.bin', type: '' });
    const small = drafts.prepare({ name: 'small.txt', type: 'text/plain' });
    const created = present(draftOf(drafts.getSnapshot(), id), 'the Draft');
    await drafts.update({ ...created, attachments: [big, small] }, created);
    // The Outgoing Content Store refuses rather than evicting anything.
    await drafts.importAsset(big, { kind: 'file', uri: 'file:///big.bin' });
    await drafts.importAsset(small, { kind: 'file', uri: 'file:///small.txt' });
    const [refused, stored] = assetsOf(
      present(draftOf(drafts.getSnapshot(), id), 'the Draft'),
    );
    const kept = completed(stored);
    expect(refused).toMatchObject({ state: 'failed', reason: 'too-large' });
    // Damaged bytes and bytes the device lost read as unavailable, never as the file.
    storage.damage(kept.id);
    await expect(drafts.readAsset(kept)).resolves.toStrictEqual({
      kind: 'damaged',
    });
    await expect(
      drafts.readAsset({ ...kept, id: 'notstored0' }),
    ).resolves.toStrictEqual({ kind: 'missing' });
  });

  it('copies a received attachment without keeping its mailbox, and only for its account', async () => {
    expect.hasAssertions();
    const { session, storage, drafts, id, draft } = await opened();
    storage.addFile('downloaded-file', 'received bytes');
    // The attachment came from another mailbox than the Draft sends from.
    const received = {
      name: 'invoice.pdf',
      type: 'application/pdf',
      source: {
        kind: 'received',
        mailbox: {
          connection: other.id,
          address: other.address,
          generation: 'generation-1',
        },
        file: 'downloaded-file',
      },
    } as const;
    await drafts.attach(id, [received]);
    await vi.waitFor(() => {
      expect(assetsOf(draft())[0]).toMatchObject({
        state: 'complete',
        size: 14,
      });
    });
    expect(storage.stored()?.document).not.toContain(other.id);
    expect(storage.stored()?.document).not.toContain('generation-1');
    expect(storage.stored()?.document).not.toContain('downloaded-file');

    // Another Product Account neither reads nor keeps the first account's bytes.
    const asset = completed(assetsOf(draft())[0]);
    await expect(drafts.save()).resolves.toBe(true);
    session.change(connected('account-b'));
    await drafts.load();
    await expect(drafts.readAsset(asset)).resolves.toStrictEqual({
      kind: 'damaged',
    });
    await drafts.create(alex);
    expect(storage.assets()).toStrictEqual([]);
    // Picking files that the person dismissed adds nothing.
    await expect(drafts.pick('files')).resolves.toStrictEqual([]);
    storage.pickNext('photos', [
      { uri: 'file:///a.png', name: 'a.png', type: 'image/png' },
    ]);
    await expect(drafts.pick('photos')).resolves.toStrictEqual([
      file('file:///a.png', 'a.png', 'image/png'),
    ]);
  });

  it('preserves completed asset bytes for an edit racing with Draft deletion', async () => {
    expect.hasAssertions();
    const { storage, drafts, id, draft } = await opened();
    storage.addFile('file:///plan.pdf', 'plan');
    await drafts.attach(id, [file('file:///plan.pdf', 'plan.pdf')]);
    await vi.waitFor(() => {
      expect(assetsOf(draft())[0]).toMatchObject({ state: 'complete' });
    });
    const before = draft();
    storage.hold();
    const deleting = drafts.discard(id, { expected: () => before });
    await vi.waitFor(() => {
      expect(drafts.getSnapshot()).toMatchObject({ save: 'saving' });
    });
    const editing = drafts.update(
      { ...before, subject: 'Keep this version' },
      before,
    );
    storage.release();
    await Promise.all([deleting, editing]);
    const [copy] = draftsOf(drafts.getSnapshot());
    expect(copy).toMatchObject({
      conflict: true,
      subject: 'Keep this version',
    });
    expect(storage.assets()).toHaveLength(1);
    await expect(
      drafts.readAsset(completed(copy?.attachments?.[0])),
    ).resolves.toMatchObject({ kind: 'ready' });
  });

  it('drops picked files after a Product Account changes while choosing', async () => {
    expect.hasAssertions();
    const { session, storage } = await opened();
    const { promise: picked, resolve: finish } =
      Promise.withResolvers<
        ReadonlyArray<{ uri: string; name: string; type: string }>
      >();
    const drafts = createDrafts(
      { ...storage.native, pickDraftFiles: () => picked },
      session.registration,
    );
    await drafts.load();
    const choosing = drafts.pick('photos');
    session.change(connected('account-b'));
    finish([{ uri: 'file:///a.png', name: 'a.png', type: 'image/png' }]);
    await expect(choosing).resolves.toStrictEqual([]);
  });

  it('keeps later navigation after received-attachment preparation and fences account replacement', async () => {
    expect.hasAssertions();
    const { session, storage, drafts } = await opened();
    const navigation = createComposerNavigation();
    storage.addFile('downloaded-file', 'received');
    const saved = {
      name: 'invoice.pdf',
      type: 'application/pdf',
      address: alex.address,
      generation: 'generation-1',
      file: 'downloaded-file',
    };
    let attaching: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Signals when the real attach reaches held storage.
    const prepared = new Promise<void>((resolve) => {
      attaching = resolve;
    });
    const controlled = {
      ...drafts,
      attach: async (...args: Readonly<Parameters<typeof drafts.attach>>) => {
        storage.hold();
        const result = drafts.attach(...args);
        attaching();
        return result;
      },
    };
    const creating = navigation.attachReceived(controlled, {
      mailbox: alex.id,
      mailboxes: [{ ...alex, state: 'connected' as const }],
      saved,
    });
    await prepared;
    await navigation.leave();
    storage.release();
    await expect(creating).resolves.toBeUndefined();
    await drafts.save();
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(2);

    // oxlint-disable-next-line promise/avoid-new -- A fresh signal fences the second attachment operation.
    const secondPrepared = new Promise<void>((resolve) => {
      attaching = resolve;
    });
    const replacement = createComposerNavigation();
    const preparing = replacement.attachReceived(controlled, {
      mailbox: alex.id,
      mailboxes: [{ ...alex, state: 'connected' as const }],
      saved,
    });
    await secondPrepared;
    session.change(connected('account-b'));
    storage.release();
    await expect(preparing).resolves.toBeUndefined();
    await drafts.load();
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);
  });
  /* oxlint-enable vitest/max-expects */
});
