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
  const reveals = new Map<
    string,
    { names: string[]; messages: GmailMessage[]; target: number }
  >();
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
    if (!samePrefix(entry.names, shownPass(history))) {
      return cached;
    }
    const oldest = cached.at(-1)?.receivedAt;
    // Mail arriving while a pass lists can move a message onto the next page as well.
    const ids = new Set(cached.map(({ id }) => id));
    // A later change can admit a message this view skipped when its segment was read.
    const older = overlaid(history.changes, [
      ...entry.messages,
      ...history.changes.flatMap(({ message }) =>
        message === undefined ? [] : [message],
      ),
    ]).filter((message) => {
      const kept =
        !ids.has(message.id) &&
        (oldest === undefined || message.receivedAt <= oldest) &&
        inView(label, labelsOf(message));
      ids.add(message.id);
      return kept;
    });
    return older.length === 0
      ? cached
      : Arr.sort([...cached, ...older], newestFirst);
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
          }
          const name = names[entry.names.length];
          if (entry.messages.length >= entry.target || name === undefined) {
            break;
          }
          const segment = yield* read(current.scope, name);
          // When a commit changed the shown document meanwhile, the next round reads against it.
          if (snapshot() === current) {
            if (Option.isNone(segment)) {
              break;
            }
            const changed = new Set(history.changes.map(({ id }) => id));
            entry.names.push(name);
            entry.messages.push(
              ...segment.value.filter(
                (message) =>
                  changed.has(message.id) || inView(label, labelsOf(message)),
              ),
            );
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
      };
      if (entry.messages.length >= entry.target) {
        entry.target = Math.max(entry.messages.length, cached.length) + count;
      }
      reveals.set(label, entry);
      return reveal(label);
    },
  };
}
