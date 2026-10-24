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
  concerned: ReadonlyMap<string, unknown>;
  working: readonly string[];
  scope: readonly unknown[];
  covered: boolean;
  // Messages an outcome took away while their organizing work is unfinished:
  // a withdrawn or discarded change, or an Undo the server is still moving back, returns them.
  // Finished work owns nothing, so another client's later restoration stays quiet.
  attributed: ReadonlySet<string>;
  leaving: ReadonlyArray<Leaving<I>>;
  returning: ReadonlySet<string>;
}>;

export type ShownRows<I> = Readonly<{
  sections: ReadonlyArray<RowSection<I>>;
  // A row's key; a message row's is its `motionIdentityOf`, which outcomes name.
  keyOf: (item: I) => string;
  // The immutable displayed content, excluding a host's temporary row wrapper.
  contentOf: (item: I) => unknown;
  // Each shown mailbox's organizing outcome. Only an action, its Undo or their reconciliation
  // changes one; synchronization and view changes never do.
  outcomes: readonly unknown[];
  // The messages those outcomes and any blocked change concern, with each outcome's identity so
  // the same notice cannot repeatedly attribute motion.
  concerned: ReadonlyMap<string, unknown>;
  // The messages whose organizing work is unfinished, keyed like the rows.
  working: readonly string[];
  // View/search/filter choices and the live mailbox owners. Replacing them retires row motion.
  scope: readonly unknown[];
  // Whether a native reader transition must finish before the leaving row starts.
  covered: boolean;
}>;

type Named = Readonly<{ message: Readonly<{ id: string }> }>;
// A shown mailbox, by what its Inbox snapshot publishes.
type Listed = Readonly<{
  id: string;
  state: Readonly<{
    kind: string;
    originalIds?: ReadonlyMap<string, string> | undefined;
  }>;
}>;
type OrganizingMailbox = Readonly<{
  id: string;
  state: Listed['state'] &
    Readonly<{
      notice?: Named | undefined;
      blockedAction?: Named | undefined;
      organizing?: readonly string[] | undefined;
    }>;
}>;

// Provider message IDs, which Gmail and Microsoft Graph keep across folders. IMAP gives a moved
// message a new UID, so its Inbox names the ID each verified move started from.
const motionIdentity = ({ id, state }: Listed, message: string) =>
  `${id}\n${state.originalIds?.get(message) ?? message}`;

// A message row's key, which it keeps while it leaves and when an Undo brings it back.
export const motionIdentityOf = ({
  mailbox,
  message,
}: Readonly<{ mailbox: Listed; message: Readonly<{ id: string }> }>) =>
  motionIdentity(mailbox, message.id);

// The shown mailboxes' organizing outcomes, the messages they and any blocked change concern, and
// which messages still have organizing work to finish.
export const organizingWork = (mailboxes: readonly OrganizingMailbox[]) => ({
  outcomes: mailboxes.map(({ state }) => state.notice),
  concerned: new Map(
    mailboxes.flatMap((mailbox) =>
      [mailbox.state.notice, mailbox.state.blockedAction].flatMap(
        (outcome): Array<[string, unknown]> =>
          outcome === undefined
            ? []
            : [[motionIdentity(mailbox, outcome.message.id), outcome]],
      ),
    ),
  ),
  working: mailboxes.flatMap((mailbox) =>
    (mailbox.state.organizing ?? []).map((id) => motionIdentity(mailbox, id)),
  ),
});

// The same mailboxes show the same outcomes; a changed set of mailboxes is not an outcome.
const sameOrganizingOutcomes = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length !== b.length || a.every((outcome, index) => outcome === b[index]);

const sameValues = (a: readonly unknown[], b: readonly unknown[]) =>
  a.length === b.length && a.every((value, index) => value === b[index]);

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

const keysOf = <I>(shown: ShownRows<I>) =>
  shown.sections.flatMap(({ data }) => data.map(shown.keyOf));

const unchanged = <I>(tracked: RowMotionState<I>, shown: ShownRows<I>) =>
  sameValues(shown.scope, tracked.scope) &&
  shown.covered === tracked.covered &&
  sameValues(shown.outcomes, tracked.outcomes) &&
  sameValues(shown.working, tracked.working) &&
  shown.concerned.size === tracked.concerned.size &&
  [...shown.concerned].every(
    ([identity, outcome]) => tracked.concerned.get(identity) === outcome,
  ) &&
  shown.sections.length === tracked.sections.length &&
  shown.sections.every((section, index) => {
    const previous = tracked.sections[index];
    return (
      previous !== undefined &&
      section.key === previous.key &&
      sameValues(
        section.data.map(shown.keyOf),
        previous.data.map(shown.keyOf),
      ) &&
      sameValues(
        section.data.map(shown.contentOf),
        previous.data.map(shown.contentOf),
      )
    );
  });

// What unfinished work keeps owning: the messages it took away that are still absent.
const stillAttributed = <I>(
  owned: ReadonlySet<string>,
  shown: ShownRows<I>,
  present: ReadonlySet<string>,
) =>
  new Set(
    [...owned].filter(
      (identity) => !present.has(identity) && shown.working.includes(identity),
    ),
  );

// The motion state for a list before any outcome.
export const restingRowMotion = <I>(shown: ShownRows<I>): RowMotionState<I> => {
  const order = keysOf(shown);
  return {
    order,
    sections: shown.sections,
    outcomes: shown.outcomes,
    concerned: shown.concerned,
    working: shown.working,
    scope: shown.scope,
    covered: shown.covered,
    attributed: stillAttributed(
      new Set(shown.concerned.keys()),
      shown,
      new Set(order),
    ),
    leaving: [],
    returning: new Set(),
  };
};

// The list after a render. A new outcome moves the rows it concerns, and unfinished work keeps
// owning the messages it took away. Every other row changes without motion. A new outcome
// finishes rows still leaving, except one it concerns, which its Undo may still bring back.
export function advanceRowMotion<I>(
  tracked: RowMotionState<I>,
  shown: ShownRows<I>,
): RowMotionState<I> {
  if (unchanged(tracked, shown)) {
    return tracked;
  }
  if (!sameValues(shown.scope, tracked.scope)) {
    return restingRowMotion(shown);
  }
  const order = keysOf(shown);
  const now = new Set(order);
  const before = new Set(tracked.order);
  const fresh = new Set(
    [...shown.concerned]
      .filter(
        ([identity, outcome]) => tracked.concerned.get(identity) !== outcome,
      )
      .map(([identity]) => identity),
  );
  const owned = new Set([...tracked.attributed, ...fresh]);
  const positions = new Map(tracked.order.map((key, index) => [key, index]));
  const left = tracked.sections.flatMap((section) =>
    section.data.flatMap((item): Array<Leaving<I>> => {
      const key = shown.keyOf(item);
      const index = positions.get(key);
      return now.has(key) || index === undefined || !owned.has(key)
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
  const sameOutcome = sameOrganizingOutcomes(shown.outcomes, tracked.outcomes);
  // Clearing a notice after reconciliation is not another action that interrupts its entrance.
  const newOutcome = shown.outcomes.some(
    (outcome, index) =>
      outcome !== undefined && outcome !== tracked.outcomes[index],
  );
  const still = tracked.leaving.filter(
    ({ key }) => !now.has(key) && (sameOutcome || fresh.has(key)),
  );
  const back = order.filter(
    (key) => (!before.has(key) && owned.has(key)) || reversing.has(key),
  );
  return {
    order,
    sections: shown.sections,
    outcomes: shown.outcomes,
    concerned: shown.concerned,
    working: shown.working,
    scope: shown.scope,
    covered: shown.covered,
    attributed: stillAttributed(owned, shown, now),
    leaving: [...still, ...left],
    returning: new Set([
      ...(newOutcome
        ? []
        : [...tracked.returning].filter((key) => now.has(key))),
      ...back,
    ]),
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
  const holding = (key: string | undefined) =>
    placed.findIndex(({ data }) => data.some((item) => keyOf(item) === key));
  // Where a row's own section returns once it left with its last row: before the section holding
  // the row's later neighbour, else after the one holding its earlier neighbour.
  const sectionIndexFor = (row: Leaving<I>, afterKey: string | undefined) => {
    const beforeSection = holding(row.before);
    if (beforeSection !== -1) {
      return beforeSection;
    }
    const afterSection = holding(afterKey);
    return afterSection === -1 ? placed.length : afterSection + 1;
  };
  // Where a row goes among its section's rows: after its earlier neighbour, else before its later
  // one.
  const rowIndexFor = (
    data: readonly I[],
    row: Leaving<I>,
    afterKey: string | undefined,
  ) => {
    const index = data.findIndex(
      (item) => keyOf(item) === (afterKey ?? row.before),
    );
    if (index === -1) {
      return row.before === undefined ? data.length : 0;
    }
    return index + (row.after === undefined ? 0 : 1);
  };
  const after = new Map<string, string>();
  for (const row of leaving) {
    const afterKey =
      row.after === undefined ? undefined : (after.get(row.after) ?? row.after);
    let section = placed.find(({ key }) => key === row.section);
    if (section === undefined) {
      // SectionList includes the section key in each cell's identity, even for its last row.
      section = { key: row.section, data: [] };
      placed.splice(sectionIndexFor(row, afterKey), 0, section);
    }
    section.data.splice(rowIndexFor(section.data, row, afterKey), 0, row.item);
    if (row.after !== undefined) {
      after.set(row.after, row.key);
    }
  }
  return placed;
}
