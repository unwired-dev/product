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

// An organizing outcome or blocked change, and the mailbox whose work it is.
type Concern = Readonly<{ outcome: unknown; mailbox: string }>;

export type RowMotionState<I> = Readonly<{
  order: readonly string[];
  sections: ReadonlyArray<RowSection<I>>;
  outcomes: readonly unknown[];
  concerned: ReadonlyMap<string, Concern>;
  working: readonly string[];
  scope: readonly unknown[];
  covered: boolean;
  // Messages an outcome took away, by mailbox, while that mailbox's organizing work is unfinished:
  // a withdrawn or discarded change, or an Undo the server is still moving back, returns them.
  // Finished work owns nothing, so another client's later restoration stays quiet.
  attributed: ReadonlyMap<string, string>;
  leaving: ReadonlyArray<Leaving<I>>;
  returning: ReadonlySet<string>;
}>;

export type ShownRows<I> = Readonly<{
  sections: ReadonlyArray<RowSection<I>>;
  // A row's key; a message row's is its `motionIdentityOf`, which outcomes name.
  keyOf: (item: I) => string;
  // Each shown mailbox's organizing outcome. Only an action, its Undo or their reconciliation
  // changes one; synchronization and view changes never do.
  outcomes: readonly unknown[];
  // The messages those outcomes and any blocked change concern, with each outcome's identity so
  // the same notice cannot repeatedly attribute motion.
  concerned: ReadonlyMap<string, Concern>;
  // The shown mailboxes whose organizing work is unfinished.
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
      pending?: number | undefined;
      saving?: number | undefined;
      blocked?: boolean | string | undefined;
      restoring?: true | undefined;
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

// Changes the provider has not confirmed, a blocked change, or an Undo not yet listed again.
const unfinished = ({ state }: OrganizingMailbox) =>
  (state.pending ?? 0) > 0 ||
  (state.saving ?? 0) > 0 ||
  (state.blocked !== undefined && state.blocked !== false) ||
  state.restoring === true;

// The shown mailboxes' organizing outcomes, the messages they and any blocked change concern, and
// which mailboxes still have organizing work to finish.
export const organizingWork = (mailboxes: readonly OrganizingMailbox[]) => ({
  outcomes: mailboxes.map(({ state }) => state.notice),
  concerned: new Map(
    mailboxes.flatMap((mailbox) =>
      [mailbox.state.notice, mailbox.state.blockedAction].flatMap(
        (outcome): Array<[string, Concern]> =>
          outcome === undefined
            ? []
            : [
                [
                  motionIdentity(mailbox, outcome.message.id),
                  { outcome, mailbox: mailbox.id },
                ],
              ],
      ),
    ),
  ),
  working: mailboxes.filter(unfinished).map(({ id }) => id),
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
    ([identity, { outcome }]) =>
      tracked.concerned.get(identity)?.outcome === outcome,
  ) &&
  shown.sections.length === tracked.sections.length &&
  shown.sections.every((section, index) => {
    const previous = tracked.sections[index];
    return (
      previous !== undefined &&
      section.key === previous.key &&
      sameValues(section.data.map(shown.keyOf), previous.data.map(shown.keyOf))
    );
  });

// What unfinished work keeps owning: the messages it took away that are still absent.
const stillAttributed = <I>(
  owned: ReadonlyMap<string, string>,
  shown: ShownRows<I>,
  present: ReadonlySet<string>,
) =>
  new Map(
    [...owned].filter(
      ([identity, mailbox]) =>
        !present.has(identity) && shown.working.includes(mailbox),
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
      new Map(
        [...shown.concerned].map(([identity, { mailbox }]) => [
          identity,
          mailbox,
        ]),
      ),
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
        ([identity, { outcome }]) =>
          tracked.concerned.get(identity)?.outcome !== outcome,
      )
      .map(([identity]) => identity),
  );
  const owned = new Map([
    ...tracked.attributed,
    ...[...shown.concerned]
      .filter(([identity]) => fresh.has(identity))
      .map(([identity, { mailbox }]): [string, string] => [identity, mailbox]),
  ]);
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
      ...(sameOutcome
        ? [...tracked.returning].filter((key) => now.has(key))
        : []),
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
