import type { RowMotionState } from '../src/mailboxes.ts';

import { advanceRowMotion, placeLeavingRows } from '../src/mailboxes.ts';

describe('organizing row continuity', () => {
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
      covered: false,
      leaving: [],
      returning: new Set(),
    };
    const keyOf = (key: string) => key;
    const shown = {
      sections: [{ key: 'today', data: ['a'] }],
      keyOf,
      outcomes: ['archived'],
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
  });
});
