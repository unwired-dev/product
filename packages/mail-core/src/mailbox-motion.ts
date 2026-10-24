type RowSection<I> = Readonly<{ key: string; data: readonly I[] }>;

type Leaving<I> = Readonly<{
  item: I;
  key: string;
  section: string;
  // The neighbours it had, which place it while it leaves.
  after: string | undefined;
  before: string | undefined;
  wait: boolean;
}>;

export type RowMotionState<I> = Readonly<{
  order: readonly string[];
  sections: ReadonlyArray<RowSection<I>>;
  outcomes: readonly unknown[];
  covered: boolean;
  leaving: ReadonlyArray<Leaving<I>>;
  returning: ReadonlySet<string>;
}>;

export type ShownRows<I> = Readonly<{
  sections: ReadonlyArray<RowSection<I>>;
  keyOf: (item: I) => string;
  // Each shown mailbox's organizing outcome. Only an action, its Undo or their reconciliation
  // changes one; synchronization and view changes never do.
  outcomes: readonly unknown[];
  // Whether a native reader transition must finish before the leaving row starts.
  covered: boolean;
}>;

// The same mailboxes show the same outcomes; a changed set of mailboxes is not an outcome.
export const sameOrganizingOutcomes = (
  a: readonly unknown[],
  b: readonly unknown[],
) => a.length !== b.length || a.every((outcome, index) => outcome === b[index]);

// The nearest key on one side of `index` that the list still shows.
const neighbour = (
  {
    order,
    shown,
  }: Readonly<{ order: readonly string[]; shown: ReadonlySet<string> }>,
  index: number,
  step: -1 | 1,
) => {
  for (let at = index + step; at >= 0 && at < order.length; at += step) {
    const key = order[at];
    if (key !== undefined && shown.has(key)) {
      return key;
    }
  }
  return undefined;
};

// The list after a render. Rows an outcome removed keep leaving and rows it brought back return;
// a new outcome finishes rows still leaving, unless they return. Other changes replace the list.
export function advanceRowMotion<I>(
  tracked: RowMotionState<I>,
  shown: ShownRows<I>,
): RowMotionState<I> {
  const order = shown.sections.flatMap(({ data }) => data.map(shown.keyOf));
  const now = new Set(order);
  const next = {
    order,
    sections: shown.sections,
    outcomes: shown.outcomes,
    covered: shown.covered,
  };
  if (sameOrganizingOutcomes(shown.outcomes, tracked.outcomes)) {
    return {
      ...tracked,
      ...next,
      leaving: tracked.leaving.filter(({ key }) => !now.has(key)),
    };
  }
  const before = new Set(tracked.order);
  const positions = new Map(tracked.order.map((key, index) => [key, index]));
  const leaving = tracked.sections.flatMap((section) =>
    section.data.flatMap((item): Array<Leaving<I>> => {
      const key = shown.keyOf(item);
      const index = positions.get(key);
      return now.has(key) || index === undefined
        ? []
        : [
            {
              item,
              key,
              section: section.key,
              after: neighbour({ order: tracked.order, shown: now }, index, -1),
              before: neighbour({ order: tracked.order, shown: now }, index, 1),
              wait: tracked.covered,
            },
          ];
    }),
  );
  const reversing = new Set(
    tracked.leaving.filter(({ key }) => now.has(key)).map(({ key }) => key),
  );
  return {
    ...next,
    leaving,
    returning: new Set(
      order.filter((key) => !before.has(key) || reversing.has(key)),
    ),
  };
}

// The sections with each leaving row beside the neighbours it had.
export function placeLeavingRows<I>(
  sections: ReadonlyArray<RowSection<I>>,
  leaving: ReadonlyArray<Leaving<I>>,
  keyOf: (item: I) => string,
): Array<RowSection<I>> {
  if (leaving.length === 0) {
    return [...sections];
  }
  const placed = sections.map((section) => ({
    ...section,
    data: [...section.data],
  }));
  const after = new Map<string, string>();
  for (const row of leaving) {
    const afterKey =
      row.after === undefined ? undefined : (after.get(row.after) ?? row.after);
    let section = placed.find(({ key }) => key === row.section);
    if (section === undefined) {
      // SectionList includes the section key in each cell's identity, even for its last row.
      section = { key: row.section, data: [] };
      const beforeSection = placed.findIndex(({ data }) =>
        data.some((item) => keyOf(item) === row.before),
      );
      const afterSection = placed.findIndex(({ data }) =>
        data.some((item) => keyOf(item) === afterKey),
      );
      let sectionIndex = beforeSection;
      if (sectionIndex === -1) {
        sectionIndex = afterSection === -1 ? placed.length : afterSection + 1;
      }
      placed.splice(sectionIndex, 0, section);
    }
    const anchor = afterKey ?? row.before;
    const index = section.data.findIndex((item) => keyOf(item) === anchor);
    let at = index + (row.after === undefined ? 0 : 1);
    if (index === -1) {
      at = row.before === undefined ? section.data.length : 0;
    }
    section.data.splice(at, 0, row.item);
    if (row.after !== undefined) {
      after.set(row.after, row.key);
    }
  }
  return placed;
}
