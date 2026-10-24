import type { RowMotionState } from '@private-email/mail-core/mailboxes';

import {
  advanceRowMotion,
  placeLeavingRows,
} from '@private-email/mail-core/mailboxes';

describe('organizing row continuity', () => {
  it('tracks a midnight section change even when the row order stays the same', () => {
    expect.hasAssertions();
    const tracked: RowMotionState<string> = {
      order: ['a', 'b'],
      sections: [{ key: 'today', data: ['a', 'b'] }],
      outcomes: [undefined],
      scope: [],
      covered: false,
      leaving: [],
      returning: new Set(),
    };
    const shown = {
      ...tracked,
      keyOf: (key: string) => key,
      sections: [{ key: 'yesterday', data: ['a', 'b'] }],
    };
    const midnight = advanceRowMotion(tracked, shown);
    const archived = {
      ...shown,
      sections: [{ key: 'yesterday', data: ['b'] }],
      outcomes: ['archived'],
    };
    const removed = advanceRowMotion(midnight, archived);

    expect(
      placeLeavingRows(archived.sections, removed.leaving, shown.keyOf),
    ).toStrictEqual(shown.sections);
    expect(advanceRowMotion(midnight, shown)).toBe(midnight);
  });

  it('preserves section identity and order when an outcome removes adjacent rows and whole date sections', () => {
    expect.hasAssertions();
    const sections = [
      { key: 'today', data: ['a', 'b', 'c'] },
      { key: 'yesterday', data: ['d'] },
      { key: 'earlier', data: ['e', 'f'] },
    ];
    const tracked: RowMotionState<string> = {
      sections,
      order: sections.flatMap(({ data }) => data),
      outcomes: [undefined],
      scope: [],
      covered: false,
      leaving: [],
      returning: new Set(),
    };
    const keyOf = (key: string) => key;
    const shown = {
      sections: [{ key: 'today', data: ['a'] }],
      keyOf,
      outcomes: ['archived'],
      scope: [],
      covered: false,
    };
    const removed = advanceRowMotion(tracked, shown);

    expect(
      placeLeavingRows(shown.sections, removed.leaving, keyOf),
    ).toStrictEqual(sections);
    expect(
      advanceRowMotion(removed, { ...shown, sections, outcomes: ['undone'] })
        .returning,
    ).toStrictEqual(new Set(['b', 'c', 'd', 'e', 'f']));
    // Changing mailbox, query or Filter is a replacement even if its notice also differs.
    expect(
      advanceRowMotion(removed, {
        ...shown,
        scope: ['another view'],
        sections: [{ key: 'today', data: ['z'] }],
        outcomes: ['another mailbox notice'],
      }),
    ).toMatchObject({ leaving: [], returning: new Set() });
  });
});
