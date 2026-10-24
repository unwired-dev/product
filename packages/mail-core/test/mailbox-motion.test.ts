import type { ShownRows } from '@private-email/mail-core/mailboxes';

import {
  advanceRowMotion,
  placeLeavingRows,
  restingRowMotion,
} from '@private-email/mail-core/mailboxes';

// Rows are `message@uid`: IMAP gives a message moved back a new UID in the same folder.
const keyOf = (key: string) => key;
const identityOf = (key: string) => key.split('@')[0];
const shownRows = (
  sections: ShownRows<string>['sections'],
  outcome: unknown,
  concerned: readonly string[] = [],
): ShownRows<string> => ({
  sections,
  keyOf,
  identityOf,
  outcomes: [outcome],
  concerned,
  scope: [],
  covered: false,
});

describe('organizing row continuity', () => {
  it('moves only the rows an outcome concerns, never synchronization', () => {
    expect.hasAssertions();
    const resting = restingRowMotion(
      shownRows([{ key: 'today', data: ['a@1', 'b@1'] }], undefined),
    );
    const synchronized = advanceRowMotion(
      resting,
      shownRows([{ key: 'today', data: ['new@1', 'b@1'] }], undefined),
    );
    const archived = advanceRowMotion(
      synchronized,
      shownRows([{ key: 'today', data: ['new@1'] }], 'archived b', ['b']),
    );

    expect([
      synchronized.leaving.length,
      [...synchronized.returning],
      archived.leaving.map(({ key }) => key),
      [...archived.returning],
    ]).toStrictEqual([0, [], ['b@1'], []]);
  });

  it('returns an IMAP message moved back under a new UID after its notice, beside unrelated arrivals', () => {
    expect.hasAssertions();
    const resting = restingRowMotion(
      shownRows([{ key: 'today', data: ['x@1', 'y@1'] }], undefined),
    );
    const archived = advanceRowMotion(
      resting,
      shownRows([{ key: 'today', data: ['y@1'] }], 'archived x', ['x']),
    );
    // The restore notice publishes before the server's refreshed Inbox.
    const undone = advanceRowMotion(
      archived,
      shownRows([{ key: 'today', data: ['y@1'] }], 'restored x', ['x']),
    );
    const refreshed = advanceRowMotion(
      undone,
      shownRows(
        [{ key: 'today', data: ['x@2', 'other@1', 'y@1'] }],
        'restored x',
        ['x'],
      ),
    );

    expect([...refreshed.returning]).toStrictEqual(['x@2']);
  });

  it('returns a blocked change discarded after relaunch, with no notice to name it', () => {
    expect.hasAssertions();
    // A relaunched store lists the blocked archive without its message and names it only there.
    const relaunched = restingRowMotion(
      shownRows([{ key: 'today', data: ['y@1'] }], undefined, ['x']),
    );
    const discarded = advanceRowMotion(
      relaunched,
      shownRows([{ key: 'today', data: ['x@1', 'y@1'] }], undefined),
    );
    const delivered = advanceRowMotion(
      discarded,
      shownRows([{ key: 'today', data: ['z@1', 'x@1', 'y@1'] }], undefined),
    );

    expect([[...discarded.returning], [...delivered.returning]]).toStrictEqual([
      ['x@1'],
      ['x@1'],
    ]);
  });

  it('retires returning motion when synchronization removes its row before the animation settles', () => {
    expect.hasAssertions();
    const removed = advanceRowMotion(
      restingRowMotion(
        shownRows([{ key: 'today', data: ['b@1'] }], 'archived', ['a', 'b']),
      ),
      shownRows([{ key: 'today', data: ['a@1', 'b@1'] }], 'undone', ['a', 'b']),
    );
    const synchronized = advanceRowMotion(
      removed,
      shownRows([{ key: 'today', data: ['b@1'] }], 'undone', ['a', 'b']),
    );

    expect([[...removed.returning], [...synchronized.returning]]).toStrictEqual(
      [['a@1'], []],
    );
  });

  it('tracks a midnight section change even when the row order stays the same', () => {
    expect.hasAssertions();
    const shown = shownRows(
      [{ key: 'yesterday', data: ['a@1', 'b@1'] }],
      undefined,
    );
    const midnight = advanceRowMotion(
      restingRowMotion(
        shownRows([{ key: 'today', data: ['a@1', 'b@1'] }], undefined),
      ),
      shown,
    );
    const archived = shownRows(
      [{ key: 'yesterday', data: ['b@1'] }],
      'archived',
      ['a'],
    );
    const removed = advanceRowMotion(midnight, archived);

    expect(
      placeLeavingRows(archived.sections, removed.leaving, keyOf),
    ).toStrictEqual(shown.sections);
    expect(advanceRowMotion(midnight, shown)).toBe(midnight);
  });

  it('preserves section identity and order when an outcome removes adjacent rows and whole date sections', () => {
    expect.hasAssertions();
    const sections = [
      { key: 'today', data: ['a@1', 'b@1', 'c@1'] },
      { key: 'yesterday', data: ['d@1'] },
      { key: 'earlier', data: ['e@1', 'f@1'] },
    ];
    const moved = ['b', 'c', 'd', 'e', 'f'];
    const shown = shownRows(
      [{ key: 'today', data: ['a@1'] }],
      'archived',
      moved,
    );
    const removed = advanceRowMotion(
      restingRowMotion(shownRows(sections, undefined)),
      shown,
    );

    expect(
      placeLeavingRows(shown.sections, removed.leaving, keyOf),
    ).toStrictEqual(sections);
    expect([
      ...advanceRowMotion(removed, shownRows(sections, 'undone', moved))
        .returning,
    ]).toStrictEqual(['b@1', 'c@1', 'd@1', 'e@1', 'f@1']);
    // Changing mailbox, query or Filter is a replacement even if its notice also differs.
    expect(
      advanceRowMotion(removed, {
        ...shown,
        scope: ['another view'],
        sections: [{ key: 'today', data: ['z@1'] }],
        outcomes: ['another mailbox notice'],
      }),
    ).toMatchObject({ leaving: [], returning: new Set() });
  });
});
