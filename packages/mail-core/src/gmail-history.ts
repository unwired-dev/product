import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Random from 'effect/Random';
import * as Struct from 'effect/Struct';

import type { HistoryPass, MailboxHistory } from './mailbox-document.ts';
import type { GmailMessage } from './mailbox-message.ts';

import { allMail, inView } from './gmail-actions.ts';
import { newestFirst } from './mailbox-document.ts';

// Gmail's Historical Metadata Backfill keeps All Mail in encrypted segments, one per listed page,
// beside the mailbox document. Changes Gmail reports later wait in the document until a fold
// writes them into the segments.

// Messages each listed page, and so each segment, holds.
export const historyPageSize = 100;
// A fresh segment name: lowercase base-36 digits, as the native store admits.
export const segmentName = Effect.map(
  Effect.all([
    Random.nextIntBetween(0, 2 ** 31 - 1),
    Random.nextIntBetween(0, 2 ** 31 - 1),
  ]),
  ([high, low]) => `${high.toString(36)}${low.toString(36)}`,
);
// Recorded changes past this many are folded into the segments, keeping the document small.
const foldAt = 200;
// ponytail: segments one fold step rewrites; a fold over a large history spans many steps.
const foldSegments = 20;

type Found = readonly [string, GmailMessage | undefined];

// Spam and Trash stay out of All Mail, and so out of its history.
const inAllMail = (message: GmailMessage | undefined) =>
  message !== undefined && inView(allMail, message.labels ?? []);

// The pass the views show: the last complete one while a new pass lists everything again.
export const shownPass = (history: MailboxHistory) =>
  history.previous ?? history.current;

// The names of every segment the document still refers to.
export const segmentNames = (history: MailboxHistory) =>
  [...history.current.segments, ...(history.previous?.segments ?? [])].map(
    ({ name }) => name,
  );

// Messages outside the cached views whose bodies the device keeps.
export const keptBodies = (history: MailboxHistory | undefined) => [
  ...(history?.bodies ?? []),
  ...(history?.reconciling ?? []),
];

const withBodies = (
  history: MailboxHistory,
  bodies: readonly string[],
  reconciling: readonly string[],
): MailboxHistory => ({
  ...Struct.omit(history, ['bodies', 'reconciling']),
  ...(bodies.length === 0 ? {} : { bodies: [...new Set(bodies)] }),
  ...(reconciling.length === 0
    ? {}
    : { reconciling: [...new Set(reconciling)] }),
});

// Keeps the bodies of opened messages. While a pass after an expired history ID runs, the shown
// pass may still list messages that already left All Mail, so their bodies wait for the new pass
// to list them; one it listed before the body was kept is dropped and read online again.
export const keepingBodies = (
  history: MailboxHistory,
  ids: readonly string[],
): MailboxHistory => {
  const bodies = history.bodies ?? [];
  const reconciling = history.reconciling ?? [];
  if (history.reconcilingThrough !== undefined) {
    const kept = new Set(bodies);
    return withBodies(history, bodies, [
      ...reconciling,
      ...ids.filter((id) => !kept.has(id)),
    ]);
  }
  const kept = new Set(ids);
  return withBodies(
    history,
    [...bodies, ...ids],
    reconciling.filter((id) => !kept.has(id)),
  );
};

// Forgets kept bodies the device no longer stores, such as those the budget evicted.
export const storedBodies = (
  history: MailboxHistory,
  stored: ReadonlySet<string>,
) =>
  withBodies(
    history,
    (history.bodies ?? []).filter((id) => stored.has(id)),
    (history.reconciling ?? []).filter((id) => stored.has(id)),
  );

export const progress = (history: MailboxHistory) => ({
  downloaded: history.current.segments.reduce(
    (sum, { count }) => sum + count,
    0,
  ),
  ...(history.total === undefined ? {} : { total: history.total }),
  complete: history.current.complete === true,
});

// Records each message's newest state, replacing an earlier change no fold is writing yet. A
// message that left All Mail takes its kept body with it.
export const recorded = (
  history: MailboxHistory,
  found: readonly Found[],
): MailboxHistory => {
  if (found.length === 0) {
    return history;
  }
  const through = history.folding?.through ?? history.reconcilingThrough ?? 0;
  const ids = new Set(found.map(([id]) => id));
  const left = new Set(
    found.flatMap(([id, message]) => (inAllMail(message) ? [] : [id])),
  );
  return withBodies(
    {
      ...history,
      changes: [
        ...history.changes.filter(
          ({ id }, index) => index < through || !ids.has(id),
        ),
        ...found.map(([id, message]) =>
          message !== undefined && inAllMail(message)
            ? { id, message }
            : { id },
        ),
      ],
    },
    (history.bodies ?? []).filter((id) => !left.has(id)),
    (history.reconciling ?? []).filter((id) => !left.has(id)),
  );
};

// Segment messages with the recorded changes applied; a message that left All Mail is dropped.
export const overlaid = (
  recordedChanges: MailboxHistory['changes'],
  messages: readonly GmailMessage[],
) => {
  const changes = new Map(
    recordedChanges.map(({ id, message }) => [id, message]),
  );
  return messages.flatMap((message) => {
    if (!changes.has(message.id)) {
      return [message];
    }
    const changed = changes.get(message.id);
    return changed === undefined ? [] : [changed];
  });
};

// After Gmail expired the history ID or a page token, a new pass lists All Mail again; the last
// pass stays shown until it completes. Folding waits for that pass, and kept bodies wait for it
// to list their messages.
export const restarted = (history: MailboxHistory): MailboxHistory => {
  const previous =
    history.previous ??
    (history.current.segments.length === 0 ? undefined : history.current);
  return withBodies(
    {
      ...(history.total === undefined ? {} : { total: history.total }),
      current: { segments: [] },
      ...(previous === undefined ? {} : { previous }),
      reconcilingThrough: history.changes.length,
      changes: history.changes,
    },
    [],
    keptBodies(history),
  );
};

// Adds a listed page, holding the messages `ids` names, as the pass's next segment; their waiting
// bodies stay. The last page completes the pass, which then replaces the previous one, and drops
// the bodies it never listed.
export const listed = (
  history: MailboxHistory,
  segment: HistoryPass['segments'][number],
  {
    pageToken,
    ids,
  }: Readonly<{ pageToken: string | undefined; ids: readonly string[] }>,
): MailboxHistory => {
  const segments =
    segment.count === 0
      ? history.current.segments
      : [...history.current.segments, segment];
  const page = new Set(ids);
  const reconciling = history.reconciling ?? [];
  const bodies = [
    ...(history.bodies ?? []),
    ...reconciling.filter((id) => page.has(id)),
  ];
  if (pageToken !== undefined) {
    return withBodies(
      { ...history, current: { segments, pageToken } },
      bodies,
      reconciling.filter((id) => !page.has(id)),
    );
  }
  return withBodies(
    {
      ...(history.total === undefined ? {} : { total: history.total }),
      current: { segments, complete: true },
      changes: history.changes.slice(history.reconcilingThrough ?? 0),
    },
    bodies,
    [],
  );
};

// A complete pass folds even without segments: its arrivals become the first one. An incomplete
// pass without segments waits for its listing to reach them.
export const foldDue = (history: MailboxHistory) =>
  history.folding !== undefined ||
  (history.previous === undefined &&
    history.reconcilingThrough === undefined &&
    history.changes.length >= foldAt &&
    (history.current.segments.length > 0 || history.current.complete === true));

// Changed messages no segment held whose receipt falls within a segment's range, as mail restored
// from Spam or Trash is; mail newer than the pass waits for the first segment. A receipt equal to
// the segment's oldest may belong to a later segment that has not been read yet, so it waits too.
const restoredInto = (
  changes: ReadonlyMap<string, GmailMessage | undefined>,
  held: ReadonlySet<string>,
  {
    oldest,
    newest,
  }: Readonly<{
    oldest: string | undefined;
    newest: string | undefined;
  }>,
) =>
  [...changes.values()].filter(
    (message): message is GmailMessage =>
      message !== undefined &&
      !held.has(message.id) &&
      oldest !== undefined &&
      newest !== undefined &&
      message.receivedAt > oldest &&
      message.receivedAt < newest,
  );

// Writes the recorded changes into the next segments, keeping them newest first: a changed message
// no earlier segment held joins the first one whose oldest receipt is older, as mail restored
// from Spam or Trash does. When the last segment is written, mail that arrived after the pass
// began joins a new first segment and, once the pass is complete, older mail a new last one; a
// later page lists the others.
// fallow-ignore-next-line complexity -- One step writes changed, restored, arrived and older mail into date-ordered segments.
export const foldStep = Effect.fnUntraced(function* <E>(
  history: MailboxHistory,
  read: (name: string) => Effect.Effect<readonly GmailMessage[], E>,
  newName: Effect.Effect<string>,
) {
  const folding = history.folding ?? {
    segment: 0,
    through: history.changes.length,
    found: [],
  };
  const changes = new Map(
    history.changes
      .slice(0, folding.through)
      .map(({ id, message }) => [id, message]),
  );
  const pass = history.current;
  const kept = pass.segments.slice(0, folding.segment);
  const rest = pass.segments.slice(folding.segment + foldSegments);
  const written: Array<readonly [string, readonly GmailMessage[]]> = [];
  const found = new Set(folding.found);
  let { newest } = folding;
  for (const segment of pass.segments.slice(
    folding.segment,
    folding.segment + foldSegments,
  )) {
    const stored = yield* read(segment.name);
    newest ??= stored[0]?.receivedAt;
    const oldest = stored.at(-1)?.receivedAt;
    // Removes the duplicates an earlier fold placed before the segment that already held them.
    const messages = stored.filter(({ id }) => !found.has(id));
    const changed = messages.filter(({ id }) => changes.has(id));
    for (const { id } of changed) {
      found.add(id);
    }
    const placed = restoredInto(changes, found, { oldest, newest });
    if (
      messages.length === stored.length &&
      changed.length === 0 &&
      placed.length === 0
    ) {
      kept.push(segment);
    } else {
      for (const { id } of placed) {
        found.add(id);
      }
      const next = Arr.sort(
        overlaid(history.changes.slice(0, folding.through), [
          ...messages,
          ...placed,
        ]),
        newestFirst,
      );
      if (next.length > 0) {
        const name = yield* newName;
        written.push([name, next]);
        kept.push({ name, count: next.length });
      }
    }
  }
  if (rest.length > 0) {
    return {
      history: {
        ...history,
        current: { ...pass, segments: [...kept, ...rest] },
        folding: {
          segment: kept.length,
          through: folding.through,
          found: [...found],
          ...(newest === undefined ? {} : { newest }),
        },
      },
      written,
    };
  }
  const unheld = Arr.sort(
    [...changes].flatMap(([id, message]) =>
      found.has(id) || message === undefined ? [] : [message],
    ),
    newestFirst,
  );
  const arrived = unheld.filter(
    ({ receivedAt }) => newest === undefined || receivedAt >= newest,
  );
  const older =
    pass.complete === true
      ? unheld.filter(
          ({ receivedAt }) => newest !== undefined && receivedAt < newest,
        )
      : [];
  if (arrived.length > 0) {
    const name = yield* newName;
    written.push([name, arrived]);
    kept.unshift({ name, count: arrived.length });
  }
  if (older.length > 0) {
    const name = yield* newName;
    written.push([name, older]);
    kept.push({ name, count: older.length });
  }
  return {
    history: withBodies(
      {
        ...(history.total === undefined ? {} : { total: history.total }),
        current: { ...pass, segments: kept },
        changes: history.changes.slice(folding.through),
      },
      history.bodies ?? [],
      history.reconciling ?? [],
    ),
    written,
  };
});
