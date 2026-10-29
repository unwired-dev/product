import * as Arr from 'effect/Array';
import * as Struct from 'effect/Struct';

import type {
  GmailMessage,
  GraphFolderHistory,
  GraphHistory,
  MailboxDocument,
} from './mailbox-document.ts';

import { listed, restarted, segmentNames, shownPass } from './gmail-history.ts';
import { newestFirst } from './mailbox-document.ts';

// A Microsoft mailbox's Historical Metadata Backfill keeps each folder's metadata in encrypted
// segments beside the mailbox document, one per listed page, as Gmail's does for All Mail. Each
// folder's own delta link reports the changes its segments then miss.

// Messages each listing asks for: the page size the native Graph request prefers.
export const historyPage = 50;

// Inbox, Sent Items and Archive, then the mailbox's own folders. Deleted Items, Junk Email, Drafts
// and Outbox stay out, as Trash and Spam stay out of Gmail's All Mail. Move to lists every own
// folder unless the mailbox has more than it lists; then the walked inventory names them too, and
// they are `known` once a walk completed.
export const historyFolders = (document: MailboxDocument) => {
  const limited = document.labelsLimited === true;
  const inventory = document.graphHistory?.inventory;
  return {
    wanted: [
      ...new Set([
        'INBOX',
        'SENT',
        'ARCHIVE',
        ...(document.labels ?? []).map(({ id }) => id),
        ...(limited
          ? [...(inventory?.found ?? []), ...(inventory?.walk?.seen ?? [])]
          : []),
      ]),
    ],
    known: !limited || inventory?.found !== undefined,
  };
};

export const newFolder = (folder: string, total: number) => ({
  folder,
  history: { total, current: { segments: [] }, changes: [] },
});

// After Graph expired the folder's delta link, a new round and pass list it again; the last pass
// stays shown until the new one completes.
export const restartedFolder = (
  entry: GraphFolderHistory,
): GraphFolderHistory => ({
  folder: entry.folder,
  history: restarted(entry.history),
});

// Adds one listed page as the pass's next segment; the page that ends the folder completes it.
// Messages listed at the page's oldest receipt are skipped by the next page, which lists from that
// receipt again so equal receipts across pages are neither lost nor repeated. While a page stays at
// the receipt it listed from, the next one follows Graph's continuation `next` instead.
export const listedFolder = (
  entry: GraphFolderHistory,
  page: readonly GmailMessage[],
  { name, next }: Readonly<{ name: string; next: string | undefined }>,
): GraphFolderHistory => {
  const end = next === undefined;
  const messages = Arr.sort(page, newestFirst);
  const oldest = messages.at(-1)?.receivedAt;
  const until = entry.history.current.pageToken;
  const edge = [
    ...(oldest === until ? (entry.edge ?? []) : []),
    ...messages.flatMap(({ id, receivedAt }) =>
      receivedAt === oldest ? [id] : [],
    ),
  ];
  const history = listed(
    entry.history,
    { name, count: messages.length },
    {
      pageToken: end ? undefined : (oldest ?? until),
      ids: messages.map(({ id }) => id),
    },
  );
  return {
    ...Struct.omit(entry, ['edge', 'scan']),
    ...(end ? {} : { edge: oldest === undefined ? (entry.edge ?? []) : edge }),
    ...(next !== undefined && (oldest === undefined || oldest === until)
      ? { scan: next }
      : {}),
    history,
  };
};

// Progress across folders, unknown in total and incomplete until the mailbox's folders are known. A
// folder whose pass after an expired link is still listing counts its last complete pass, so
// downloaded history never rewinds.
export const graphProgress = (document: MailboxDocument) => {
  const { known } = historyFolders(document);
  const folders = document.graphHistory?.folders ?? [];
  const passes = folders.map(({ history }) => shownPass(history));
  const totals = folders.map(({ history }) => history.total);
  return {
    downloaded: passes.reduce(
      (sum, { segments }) =>
        segments.reduce((count, segment) => count + segment.count, sum),
      0,
    ),
    ...(known && totals.every((total) => total !== undefined)
      ? { total: totals.reduce((sum, total) => sum + total, 0) }
      : {}),
    complete: known && passes.every(({ complete }) => complete === true),
  };
};

export const graphSegmentNames = ({ folders }: GraphHistory) =>
  folders.flatMap(({ history }) => segmentNames(history));
