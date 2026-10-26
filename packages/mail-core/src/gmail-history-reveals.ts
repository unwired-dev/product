import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Semaphore from 'effect/Semaphore';

import type {
  HistoryPass,
  MailboxDocument,
  MailboxHistory,
  MailboxScope,
} from './mailbox-document.ts';
import type { GmailMessage } from './mailbox-message.ts';

import { inView, labelsOf } from './gmail-actions.ts';
import { overlaid, shownPass } from './gmail-history.ts';
import { cacheLimit, newestFirst } from './mailbox-document.ts';

// A fold or replacement pass invalidates a cursor; appended pages keep its prefix valid.
const samePrefix = (names: readonly string[], pass: HistoryPass) =>
  names.every((name, index) => pass.segments[index]?.name === name);

interface Reveal {
  names: string[];
  messages: GmailMessage[];
  // The oldest receipt in the segments read so far.
  frontier?: string | undefined;
  target: number;
  // The older messages last rendered, kept while a fold's renamed segments are read again.
  shown: readonly GmailMessage[];
}

// Mail is in chronological order down to the read segments' frontier; once every segment of a
// complete pass is read, nothing older is missing.
const frontierOf = (
  {
    names,
    frontier,
  }: Readonly<{ names: readonly string[]; frontier?: string | undefined }>,
  history: MailboxHistory,
  oldest: string | undefined,
) => {
  const pass = shownPass(history);
  if (!samePrefix(names, pass)) {
    return oldest;
  }
  return pass.complete === true && names.length === pass.segments.length
    ? undefined
    : (frontier ?? oldest);
};

const cachedOf = (document: MailboxDocument | undefined, label: string) =>
  label === 'INBOX'
    ? (document?.messages ?? [])
    : (document?.views?.find((view) => view.label === label)?.messages ?? []);

// Owns only the device-memory cursors. The Inbox supplies its current snapshot, decoded segment
// reads and publication, retaining mailbox fencing and failure recovery at that boundary.
export function createHistoryReveals<E>({
  snapshot,
  read,
  publish,
}: Readonly<{
  snapshot: () =>
    | Readonly<{ scope: MailboxScope; document: MailboxDocument | undefined }>
    | undefined;
  read: (
    scope: MailboxScope,
    name: string,
  ) => Effect.Effect<Option.Option<readonly GmailMessage[]>, E>;
  publish: () => void;
}>) {
  const reveals = new Map<string, Reveal>();
  const revealing = Semaphore.makeUnsafe(1);
  // A view's cached messages, then the older stored ones it revealed.
  const withRevealed = (
    label: string,
    cached: readonly GmailMessage[],
    history: MailboxHistory | undefined,
  ) => {
    const entry = reveals.get(label);
    if (history === undefined || entry === undefined) {
      return cached;
    }
    const oldest = cached.at(-1)?.receivedAt;
    const frontier = frontierOf(entry, history, oldest);
    const within = (message: GmailMessage) =>
      frontier === undefined || message.receivedAt >= frontier;
    // Mail arriving while a pass lists can move a message onto the next page as well.
    const ids = new Set(cached.map(({ id }) => id));
    // A later change can admit a message this view skipped when its segment was read, but only
    // within the frontier: older restored mail waits until the mail between is read.
    const older = overlaid(history.changes, [
      ...(samePrefix(entry.names, shownPass(history)) ? entry.messages : []),
      ...history.changes.flatMap(({ message }) =>
        message !== undefined && within(message) ? [message] : [],
      ),
      // Equal receipts can span segments; only reading past that date confirms their membership.
      ...entry.shown.filter(
        (message) => frontier !== undefined && message.receivedAt <= frontier,
      ),
    ]).filter((message) => {
      const kept =
        !ids.has(message.id) &&
        (oldest === undefined || message.receivedAt <= oldest) &&
        inView(label, labelsOf(message));
      ids.add(message.id);
      return kept;
    });
    entry.shown = older;
    return older.length === 0
      ? cached
      : Arr.sort([...cached, ...older], newestFirst);
  };
  // Adds a read segment's messages the view can show, and moves the frontier to its oldest
  // receipt. Segments of a pass still listing can overlap, so the frontier is the oldest seen.
  const advance = ({
    label,
    name,
    segment,
    history,
  }: Readonly<{
    label: string;
    name: string;
    segment: readonly GmailMessage[];
    history: MailboxHistory;
  }>) => {
    const entry = reveals.get(label);
    if (entry === undefined) {
      return;
    }
    const changed = new Set(history.changes.map(({ id }) => id));
    entry.names.push(name);
    const last = segment.at(-1)?.receivedAt;
    if (
      last !== undefined &&
      (entry.frontier === undefined || last < entry.frontier)
    ) {
      entry.frontier = last;
    }
    entry.messages.push(
      ...segment.filter(
        (message) =>
          changed.has(message.id) || inView(label, labelsOf(message)),
      ),
    );
  };
  // A short cache is complete only after its listing finishes; a removal can leave a refill
  // interrupted. Otherwise every segment must be revealed. Spam and Trash stay outside history.
  const revealedAll = (
    { label, messages, listing }: NonNullable<MailboxDocument['views']>[number],
    history: MailboxHistory | undefined,
  ) => {
    const pass = history === undefined ? undefined : shownPass(history);
    if (label === 'SPAM' || label === 'TRASH' || pass?.complete !== true) {
      return false;
    }
    return (
      (messages.length < cacheLimit && listing === undefined) ||
      reveals.get(label)?.names.length === pass.segments.length
    );
  };
  // Reads further segments until the view has the messages it asked for or the pass runs out; a
  // fold or a completed pass rewrote the segments, so the view reads them again.
  const reveal = (label: string) =>
    revealing.withPermit(
      // fallow-ignore-next-line complexity -- Each guard decides whether one more stored segment can still serve the view.
      Effect.gen(function* () {
        for (;;) {
          const current = snapshot();
          const history = current?.document?.history;
          const entry = reveals.get(label);
          if (
            current === undefined ||
            history === undefined ||
            entry === undefined
          ) {
            return;
          }
          const names = shownPass(history).segments.map(({ name }) => name);
          if (!samePrefix(entry.names, shownPass(history))) {
            entry.names = [];
            entry.messages = [];
            entry.frontier = undefined;
          }
          const name = names[entry.names.length];
          const cached = cachedOf(current.document, label);
          const visible = withRevealed(label, cached, history).length;
          const frontier = frontierOf(
            entry,
            history,
            cached.at(-1)?.receivedAt,
          );
          // Rows kept from before a fold must be read again before the view stops; rows its
          // segments already returned are not waiting.
          const returned = new Set(entry.messages.map(({ id }) => id));
          const carried = entry.shown.some(
            (message) =>
              frontier !== undefined &&
              message.receivedAt <= frontier &&
              !returned.has(message.id),
          );
          if ((visible >= entry.target && !carried) || name === undefined) {
            break;
          }
          const segment = yield* read(current.scope, name);
          // When a commit changed the shown document meanwhile, the next round reads against it.
          if (snapshot() === current) {
            if (Option.isNone(segment)) {
              break;
            }
            advance({ label, name, segment: segment.value, history });
          }
        }
        publish();
      }),
    );
  const revealAll = Effect.suspend(() =>
    Effect.forEach([...reveals.keys()], reveal, { discard: true }),
  );

  return {
    clear: () => {
      reveals.clear();
    },
    withRevealed,
    revealedAll,
    revealAll,
    // fallow-ignore-next-line complexity -- Each guard keeps a reveal to a view with a full cache or a running listing.
    request: (label: string, count: number) => {
      if (label === 'SPAM' || label === 'TRASH') {
        return undefined;
      }
      const document = snapshot()?.document;
      const view = document?.views?.find((entry) => entry.label === label);
      const cached = label === 'INBOX' ? document?.messages : view?.messages;
      const listing =
        label === 'INBOX'
          ? document?.checkpoint.kind === 'backfill'
          : view?.listing !== undefined;
      if (
        document?.history === undefined ||
        cached === undefined ||
        (cached.length < cacheLimit && !listing && !reveals.has(label))
      ) {
        return undefined;
      }
      const entry = reveals.get(label) ?? {
        names: [],
        messages: [],
        target: 0,
        shown: [],
      };
      const visible = withRevealed(label, cached, document.history).length;
      if (visible >= entry.target) {
        entry.target = visible + count;
      }
      reveals.set(label, entry);
      return reveal(label);
    },
  };
}
