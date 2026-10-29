import type { HistoryProgress } from './gmail-inbox.ts';
import type {
  HistoryRead,
  ImapDocument,
  ImapFolderHistory,
  ImapMessage,
} from './imap-model.ts';

import { inboxFolder, listedMessage } from './imap-model.ts';

// ponytail: messages per history read and per saved segment, without Gmail's folding; a million
// messages name 2,000 segments in the document. Fold segments if that ever slows its commits.
const historyPage = 500;

const downloaded = (history: ImapFolderHistory) =>
  history.segments.reduce((sum, { count }) => sum + count, 0);

// The folders Historical Metadata Backfill downloads, the Inbox first.
const historyFolders = (document: ImapDocument) => [
  inboxFolder,
  ...document.folders
    .filter(({ name, selectable }) => selectable && name !== inboxFolder)
    .map(({ name }) => name),
];

// The first folder with history left to read. `settled` folders were read up to date, or are gone,
// since this connection opened. A cached UIDVALIDITY change or a later UIDNEXT makes one eligible
// again. Other folders begin or continue a pass or expunge check, or learn what changed.
export function nextHistoryFolder(
  document: ImapDocument,
  settled: ReadonlySet<string>,
) {
  const histories = new Map(
    (document.history ?? []).map((history) => [history.folder, history]),
  );
  const cached = new Map(
    document.mailboxes.map(({ name, cache }) => [name, cache]),
  );
  return historyFolders(document).find((name) => {
    const history = histories.get(name);
    const cache = cached.get(name);
    return (
      !settled.has(name) ||
      (history !== undefined &&
        cache !== undefined &&
        (cache.uidValidity !== history.uidValidity ||
          cache.uidNext > history.top))
    );
  });
}

// The folder's next history read: the rest of its pass, or no messages but the UIDs `known` that
// remain, its UIDNEXT and its count.
export const historyRequest = (
  folder: string,
  history: ImapFolderHistory | undefined,
  known: readonly number[],
) =>
  history === undefined
    ? { folder, above: 1, limit: historyPage, known }
    : {
        folder,
        above: history.above,
        below: history.below,
        limit: historyPage,
        known,
      };

type Step = Readonly<{
  // Absent when the folder's UIDVALIDITY changed: only its history starts over.
  history?: ImapFolderHistory;
  written: ReadonlyMap<string, readonly ImapMessage[]>;
  // Read up to date for now.
  settled: boolean;
}>;

// After a pass, or a read with nothing left to download: a pass over what arrived since, a check of
// the saved segments when they hold more messages than the folder now does, or settled.
const decided = (
  history: ImapFolderHistory,
  read: HistoryRead,
  checked: boolean,
): Omit<Step, 'written'> => {
  if (read.uidNext > history.top) {
    return {
      history: {
        ...history,
        above: history.top,
        below: read.uidNext,
        top: read.uidNext,
      },
      settled: false,
    };
  }
  if (!checked && downloaded(history) > read.total) {
    return { history: { ...history, checking: 0 }, settled: false };
  }
  const { checking: _, ...rest } = history;
  return { history: { ...rest, complete: true }, settled: true };
};

// An expunge check of the segment being checked: only its `kept` messages remain, saved as segment
// `name`.
function reconciled(
  history: ImapFolderHistory,
  kept: readonly ImapMessage[],
  name: string,
) {
  const at = history.checking ?? 0;
  const before = history.segments.slice(0, at);
  const after = history.segments.slice(at + 1);
  if (kept.length === history.segments[at]?.count) {
    return { segments: history.segments, next: at + 1, written: new Map() };
  }
  if (kept.length === 0) {
    return { segments: [...before, ...after], next: at, written: new Map() };
  }
  return {
    segments: [...before, { name, count: kept.length }, ...after],
    next: at + 1,
    written: new Map([[name, kept]]),
  };
}

// Applies one history read to the folder's history. A pass saves the read's messages as segment
// `name`; an expunge check keeps only the `checked` segment's messages the server still holds.
export function applyHistoryRead(
  history: ImapFolderHistory | undefined,
  {
    folder,
    read,
    name,
    checked,
  }: Readonly<{
    folder: string;
    read: HistoryRead;
    name: string;
    checked: readonly ImapMessage[];
  }>,
): Step {
  if (history !== undefined && history.uidValidity !== read.uidValidity) {
    return { written: new Map(), settled: false };
  }
  const base: ImapFolderHistory = {
    folder,
    uidValidity: read.uidValidity,
    top: read.uidNext,
    above: 1,
    below: read.uidNext,
    segments: [],
    ...history,
    total: read.total,
  };
  if (base.checking !== undefined) {
    const present = new Set(read.present);
    const { segments, next, written } = reconciled(
      base,
      checked.filter(({ uid }) => present.has(uid)),
      name,
    );
    const updated = { ...base, segments, checking: next };
    return next < segments.length
      ? { history: updated, written, settled: false }
      : { ...decided(updated, read, true), written };
  }
  if (base.below <= base.above) {
    return { ...decided(base, read, false), written: new Map() };
  }
  const messages = read.messages.map((message) =>
    listedMessage(folder, read.uidValidity, message),
  );
  const updated = {
    ...base,
    below: Math.max(read.below, base.above),
    segments:
      messages.length === 0
        ? base.segments
        : [...base.segments, { name, count: messages.length }],
  };
  const written = new Map(messages.length === 0 ? [] : [[name, messages]]);
  return updated.below > updated.above
    ? { history: updated, written, settled: false }
    : { ...decided(updated, read, false), written };
}

// Every segment the document's history names, which a history commit keeps.
export const historySegmentNames = (document: ImapDocument) =>
  (document.history ?? []).flatMap(({ segments }) =>
    segments.map(({ name }) => name),
  );

// The connection's progress, absent before its first history read. The total is known once every
// folder began, and the backfill completes once every folder was downloaded once.
export function historyProgress(
  document: ImapDocument,
): HistoryProgress | undefined {
  if (document.history === undefined || document.history.length === 0) {
    return undefined;
  }
  const histories = new Map(
    document.history.map((history) => [history.folder, history]),
  );
  const folders = historyFolders(document).map((name) => histories.get(name));
  const begun = folders.filter((history) => history !== undefined);
  return {
    downloaded: begun.reduce(
      (sum, history) => sum + Math.min(downloaded(history), history.total),
      0,
    ),
    ...(begun.length === folders.length
      ? { total: begun.reduce((sum, { total }) => sum + total, 0) }
      : {}),
    complete:
      begun.length === folders.length &&
      begun.every(({ complete }) => complete === true),
  };
}
