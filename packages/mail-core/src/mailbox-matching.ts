import { messageDay } from '@private-email/localization';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

// Normalize and strip accents before casing to expose compatibility letters. Lowercase so `ẞ` joins `ß`,
// then uppercase to expand sharp S and keep sigma independent of its position in a word.
export const folded = (text: string) =>
  text
    .normalize('NFKD')
    .replaceAll(/\p{M}/gu, '')
    .toLowerCase()
    .toUpperCase()
    .normalize('NFKD')
    .replaceAll(/\p{M}/gu, '');

export type InboxFilter = Readonly<{
  excluded: ReadonlySet<string>;
  unread: boolean;
  today: boolean;
}>;

// Every criterion narrows the list; Today is the list's own UTC day. Only the offered connections
// can be left out. The host owns the filter's settings and whether it applies.
export function filterMessages<
  M extends Readonly<{
    mailbox: Readonly<{ id: string }>;
    message: Readonly<{ unread: boolean; receivedAt: string }>;
  }>,
>(
  entries: readonly M[],
  {
    filter: { excluded, unread, today },
    connections,
    now,
  }: Readonly<{
    filter: InboxFilter;
    connections: ReadonlyArray<Readonly<{ id: string }>>;
    now: number;
  }>,
) {
  return entries.filter(
    ({ mailbox, message }) =>
      !(
        excluded.has(mailbox.id) &&
        connections.some(({ id }) => id === mailbox.id)
      ) &&
      (!unread || message.unread) &&
      (!today || messageDay(message.receivedAt, now) === 'today'),
  );
}

export const queryWords = (query: string) =>
  folded(query)
    .split(/\s+/u)
    .filter((word) => word.length > 0);

// `text` folded one code point at a time, with the span of `text` each folded letter came from.
const foldedLetters = (text: string) => {
  let folds = '';
  const spans: Array<readonly [number, number]> = [];
  let at = 0;
  for (const point of text) {
    for (const letter of folded(point)) {
      folds += letter;
      spans.push([at, at + point.length]);
      // String searches count both UTF-16 units of a supplementary letter.
      if (letter.length === 2) {
        spans.push([at, at + point.length]);
      }
    }
    at += point.length;
  }
  return { folds, spans };
};

// Sorted ranges with overlapping ones joined.
const joined = (ranges: ReadonlyArray<readonly [number, number]>) => {
  const sorted = Arr.sort(
    ranges,
    Order.mapInput(Order.Number, ([start]: readonly [number, number]) => start),
  );
  const merged: Array<[number, number]> = [];
  for (const [start, end] of sorted) {
    const last = merged.at(-1);
    if (last !== undefined && start <= last[1]) {
      last[1] = Math.max(last[1], end);
    } else {
      merged.push([start, end]);
    }
  }
  return merged;
};

/**
 * Find where the query's words appear in a shown field, matched as
 * `searchMessages` matches them, so a result can mark them.
 *
 * @example
 *   matchedRanges('Café on Saturday', 'cafe'); // [[0, 4]]
 *
 * @param {string} text - A result's sender name or subject as shown.
 * @param {string} query - The search query.
 * @returns {[number, number][]} Ordered, non-overlapping `[start, end)` UTF-16
 *   ranges of `text`.
 */
export function matchedRanges(
  text: string,
  query: string,
): ReadonlyArray<readonly [number, number]> {
  const { folds, spans } = foldedLetters(text);
  const found: Array<readonly [number, number]> = [];
  for (const word of queryWords(query)) {
    for (
      let index = folds.indexOf(word);
      index !== -1;
      index = folds.indexOf(word, index + 1)
    ) {
      const [start] = spans[index] ?? [0, 0];
      let [, end] = spans[index + word.length - 1] ?? [0, text.length];
      // A combining accent belongs to the letter before it.
      for (const point of text.slice(end)) {
        if (!/^\p{M}$/u.test(point)) {
          break;
        }
        end += point.length;
      }
      found.push([start, end]);
    }
  }
  return joined(found);
}
