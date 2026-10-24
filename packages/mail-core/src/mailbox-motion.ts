import * as Schema from 'effect/Schema';

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
  concerned: readonly string[];
  scope: readonly unknown[];
  covered: boolean;
  // Messages an organizing outcome concerns, by `motionIdentity`: those the current outcomes name
  // and those that left with one and have not returned. Only their rows move.
  attributed: ReadonlySet<string>;
  leaving: ReadonlyArray<Leaving<I>>;
  returning: ReadonlySet<string>;
}>;

export type ShownRows<I> = Readonly<{
  sections: ReadonlyArray<RowSection<I>>;
  keyOf: (item: I) => string;
  // A row's message across folders and UIDs, by `motionIdentity`; undefined for other rows.
  identityOf: (item: I) => string | undefined;
  // Each shown mailbox's organizing outcome. Only an action, its Undo or their reconciliation
  // changes one; synchronization and view changes never do.
  outcomes: readonly unknown[];
  // The messages those outcomes and any blocked change concern, by `motionIdentity`.
  concerned: readonly string[];
  // View/search/filter choices and the live mailbox owners. Replacing them retires row motion.
  scope: readonly unknown[];
  // Whether a native reader transition must finish before the leaving row starts.
  covered: boolean;
}>;

const MotionMessageSchema = Schema.Struct({
  sender: Schema.String,
  subject: Schema.String,
  receivedAt: Schema.String,
});
type MotionMessage = typeof MotionMessageSchema.Type;
const isNamed = Schema.is(Schema.Struct({ message: MotionMessageSchema }));
const isMessageRow = Schema.is(
  Schema.Struct({
    mailbox: Schema.Struct({ id: Schema.String }),
    message: MotionMessageSchema,
  }),
);

// A message's identity for row motion. IMAP gives a message a new UID in each folder, so a message
// an Undo moves back is recognized by what the row shows rather than by its ID.
const motionIdentity = (mailbox: string, message: MotionMessage) =>
  [mailbox, message.sender, message.subject, message.receivedAt].join('\n');

// The message an outcome or a blocked change names, when it names one.
const messageOf = (value: unknown) =>
  isNamed(value) ? value.message : undefined;

// The message a list row shows, which an organizing outcome may concern; undefined for Drafts and
// the Outbox.
export const motionIdentityOf = (item: object) =>
  isMessageRow(item)
    ? motionIdentity(item.mailbox.id, item.message)
    : undefined;

// The messages each ready mailbox's organizing outcome and blocked change concern.
export const organizingConcerns = (
  mailboxes: ReadonlyArray<Readonly<{ id: string; state: object }>>,
): string[] =>
  mailboxes.flatMap(({ id, state }) =>
    [
      'notice' in state ? messageOf(state.notice) : undefined,
      'blockedAction' in state ? messageOf(state.blockedAction) : undefined,
    ].flatMap((message) =>
      message === undefined ? [] : [motionIdentity(id, message)],
    ),
  );

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

const unchanged = <I>(tracked: RowMotionState<I>, shown: ShownRows<I>) =>
  sameValues(shown.scope, tracked.scope) &&
  shown.covered === tracked.covered &&
  sameValues(shown.outcomes, tracked.outcomes) &&
  sameValues(shown.concerned, tracked.concerned) &&
  shown.sections.length === tracked.sections.length &&
  shown.sections.every((section, index) => {
    const previous = tracked.sections[index];
    return (
      previous !== undefined &&
      section.key === previous.key &&
      sameValues(section.data.map(shown.keyOf), previous.data.map(shown.keyOf))
    );
  });

// The motion state for a list before any outcome.
export const restingRowMotion = <I>(
  shown: ShownRows<I>,
): RowMotionState<I> => ({
  order: shown.sections.flatMap(({ data }) => data.map(shown.keyOf)),
  sections: shown.sections,
  outcomes: shown.outcomes,
  concerned: shown.concerned,
  scope: shown.scope,
  covered: shown.covered,
  attributed: new Set(shown.concerned),
  leaving: [],
  returning: new Set(),
});

// The list after a render. A row an organizing outcome concerns keeps leaving when it goes and
// returns when it comes back, whenever its outcome's publication and its row's arrive. Every other
// row changes without motion. A new outcome finishes rows still leaving, unless they return.
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
  const order = shown.sections.flatMap(({ data }) => data.map(shown.keyOf));
  const now = new Set(order);
  const before = new Set(tracked.order);
  const owned = new Set([...tracked.attributed, ...shown.concerned]);
  const concerns = (item: I) => {
    const identity = shown.identityOf(item);
    return identity !== undefined && owned.has(identity);
  };
  const positions = new Map(tracked.order.map((key, index) => [key, index]));
  const left = tracked.sections.flatMap((section) =>
    section.data.flatMap((item): Array<Leaving<I>> => {
      const key = shown.keyOf(item);
      const index = positions.get(key);
      return now.has(key) || index === undefined || !concerns(item)
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
  // A new outcome takes effect at once, so rows still leaving or returning from an earlier one
  // finish.
  const sameOutcome = sameOrganizingOutcomes(shown.outcomes, tracked.outcomes);
  const still = sameOutcome
    ? tracked.leaving.filter(({ key }) => !now.has(key))
    : [];
  const items = shown.sections.flatMap(({ data }) => data);
  const back = items.flatMap((item) => {
    const key = shown.keyOf(item);
    return (!before.has(key) && concerns(item)) || reversing.has(key)
      ? [key]
      : [];
  });
  // Messages that left with an outcome stay attributed until they return.
  const present = new Set(
    items.flatMap((item) => {
      const identity = shown.identityOf(item);
      return identity === undefined ? [] : [identity];
    }),
  );
  return {
    order,
    sections: shown.sections,
    outcomes: shown.outcomes,
    concerned: shown.concerned,
    scope: shown.scope,
    covered: shown.covered,
    attributed: new Set([
      ...shown.concerned,
      ...[...owned].filter((identity) => !present.has(identity)),
    ]),
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
