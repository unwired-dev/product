import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';

import type { HistoryPass, MailboxHistory } from './mailbox-document.ts';
import type { GmailMessage } from './mailbox-message.ts';

import { allMail, inView } from './gmail-actions.ts';
import { newestFirst } from './mailbox-document.ts';

// Gmail's Historical Metadata Backfill keeps All Mail in encrypted segments, one per listed page,
// beside the mailbox document. Changes Gmail reports later wait in the document until a fold
// writes them into the segments.

// Messages each listed page, and so each segment, holds.
export const historyPageSize = 100;
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

export const progress = (history: MailboxHistory) => ({
  downloaded: history.current.segments.reduce(
    (sum, { count }) => sum + count,
    0,
  ),
  ...(history.total === undefined ? {} : { total: history.total }),
  complete: history.current.complete === true,
});

// Records each message's newest state, replacing an earlier change no fold is writing yet.
export const recorded = (
  history: MailboxHistory,
  found: readonly Found[],
): MailboxHistory => {
  if (found.length === 0) {
    return history;
  }
  const through = history.folding?.through ?? history.reconcilingThrough ?? 0;
  const ids = new Set(found.map(([id]) => id));
  return {
    ...history,
    changes: [
      ...history.changes.filter(
        ({ id }, index) => index < through || !ids.has(id),
      ),
      ...found.map(([id, message]) =>
        message !== undefined && inAllMail(message) ? { id, message } : { id },
      ),
    ],
  };
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
// pass stays shown until it completes. Folding waits for that pass.
export const restarted = (history: MailboxHistory): MailboxHistory => {
  const previous =
    history.previous ??
    (history.current.segments.length === 0 ? undefined : history.current);
  return {
    ...(history.total === undefined ? {} : { total: history.total }),
    current: { segments: [] },
    ...(previous === undefined ? {} : { previous }),
    reconcilingThrough: history.changes.length,
    changes: history.changes,
  };
};

// Adds a listed page as the pass's next segment. The last page completes the pass, which then
// replaces the previous one.
export const listed = (
  history: MailboxHistory,
  segment: HistoryPass['segments'][number],
  pageToken: string | undefined,
): MailboxHistory => {
  const segments =
    segment.count === 0
      ? history.current.segments
      : [...history.current.segments, segment];
  if (pageToken !== undefined) {
    return { ...history, current: { segments, pageToken } };
  }
  return {
    ...(history.total === undefined ? {} : { total: history.total }),
    current: { segments, complete: true },
    changes: history.changes.slice(history.reconcilingThrough ?? 0),
  };
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
// from Spam or Trash is; mail newer than the pass waits for the first segment.
const restoredInto = (
  changes: ReadonlyMap<string, GmailMessage | undefined>,
  held: ReadonlySet<string>,
  { oldest, newest }: Readonly<{ oldest?: string; newest?: string }>,
) =>
  [...changes.values()].filter(
    (message): message is GmailMessage =>
      message !== undefined &&
      !held.has(message.id) &&
      oldest !== undefined &&
      newest !== undefined &&
      message.receivedAt >= oldest &&
      message.receivedAt < newest,
  );

// Writes the recorded changes into the next segments, keeping them newest first: a changed message
// no earlier segment held joins the first one whose oldest receipt is not newer, as mail restored
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
  const found = [...folding.found];
  let { newest } = folding;
  for (const segment of pass.segments.slice(
    folding.segment,
    folding.segment + foldSegments,
  )) {
    const messages = yield* read(segment.name);
    newest ??= messages[0]?.receivedAt;
    const oldest = messages.at(-1)?.receivedAt;
    const changed = messages.filter(({ id }) => changes.has(id));
    const ids = new Set([...found, ...changed.map(({ id }) => id)]);
    const placed = restoredInto(changes, ids, { oldest, newest });
    if (changed.length === 0 && placed.length === 0) {
      kept.push(segment);
    } else {
      found.push(...changed.map(({ id }) => id), ...placed.map(({ id }) => id));
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
          found,
          ...(newest === undefined ? {} : { newest }),
        },
      },
      written,
    };
  }
  const held = new Set(found);
  const unheld = Arr.sort(
    [...changes].flatMap(([id, message]) =>
      held.has(id) || message === undefined ? [] : [message],
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
    history: {
      ...(history.total === undefined ? {} : { total: history.total }),
      current: { ...pass, segments: kept },
      changes: history.changes.slice(folding.through),
    },
    written,
  };
});
