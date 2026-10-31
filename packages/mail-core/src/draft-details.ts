import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import type { SemanticDocument, Selection } from './semantic-document.ts';

import { selectedLinks } from './semantic-document.ts';

// Details a Writing tools result must not change unnoticed. The check reads text only: it cannot
// tell whether meaning, questions or commitments survived, so people still read the result.
export type DetailKind =
  | 'link'
  | 'email'
  | 'quote'
  | 'date'
  | 'time'
  | 'amount'
  | 'number';

type Detail = Readonly<{
  kind: DetailKind;
  value: string;
  // The linked words of a link whose destination is not written out.
  label?: string;
  key: string;
}>;

export type DetailChange = Readonly<{
  kind: DetailKind;
  status: 'changed' | 'removed' | 'added';
  label?: string;
  original?: string;
  result?: string;
}>;

export type DetailCheck = Readonly<{
  kept: readonly string[];
  changes: readonly DetailChange[];
}>;

// Names match in any letter case without the `i` flag, which would also loosen currency codes.
const anyCase = (words: string) =>
  words.replaceAll(
    /\p{L}/gu,
    (letter) => `[${letter.toLowerCase()}${letter.toUpperCase()}]`,
  );
const weekday = anyCase('(?:mon|tues|wednes|thurs|fri|satur|sun)day');
const month = `${anyCase('(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)')}(?:\\.(?=,?\\s\\d))?`;
const day = String.raw`\d{1,2}(?:st|nd|rd|th)?`;
const unsigned = String.raw`(?:\d+(?:[.,]\d+)*|[.,]\d+)`;
// A sign belongs to its number: `-40` and `40` differ.
const sign = '[-−+]';
const figure = `${sign}?${unsigned}`;
const linkEnd = String.raw`[^\s<>"“”«»]`;
const currency = String.raw`\p{Sc}|\b[A-Z]{3}\b|Kč`;
const edge = String.raw`(?![\p{L}\p{N}])`;

// A detail starts and ends outside a word. Earlier alternatives win where details overlap, so an
// amount's number or a date's day is not counted again. Quotes are read separately because they
// may hold other details.
const patterns: ReadonlyArray<readonly [DetailKind, string]> = [
  [
    'link',
    // A bare address ends in a label of letters, as in link inspection, and is not an email's
    // local part.
    `https?://${linkEnd}+|(?:[\\p{L}\\p{N}-]+\\.)+\\p{L}{2,}(?![@\\p{L}\\p{N}-])(?:[/?#]${linkEnd}*)?`,
  ],
  ['email', String.raw`[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+`],
  [
    'amount',
    `${sign}?(?:${currency})\\s?${unsigned}|${figure}\\s?(?:${currency})`,
  ],
  [
    'date',
    [
      `\\d{4}-\\d{1,2}-\\d{1,2}`,
      `\\d{1,2}[./]\\d{1,2}[./]\\d{2,4}`,
      `(?:${weekday},?\\s)?(?:${day}\\s${month}|${month}\\s${day})(?:,?\\s\\d{4})?`,
      weekday,
      anyCase('today|tomorrow|tonight|yesterday'),
    ].join('|'),
  ],
  ['time', `\\d{1,2}(?::\\d{2})?\\s?[aApP]\\.?[mM]\\.?${edge}|\\d{1,2}:\\d{2}`],
  ['number', figure],
];
const kinds = patterns.map(([kind]) => kind);
const pattern = new RegExp(
  `(?:^|[^\\p{L}\\p{N}])(?:${patterns.map(([, source]) => `(${source})`).join('|')})${edge}`,
  'gu',
);
const quote = /"[^"\n]+"|“[^”\n]+”|„[^“”\n]+[“”]|«[^»\n]+»/gu;

// A written link ends before a closing quote, a full stop, comma, colon or semicolon, and before a
// closing parenthesis it did not open. `!` and `?` can end an address, so they stay part of it.
const trimLink = (link: string): string => {
  const trimmed = link.replace(/[.,;:'"’”»]+$/u, '');
  return trimmed.endsWith(')') &&
    trimmed.split(')').length > trimmed.split('(').length
    ? trimLink(trimmed.slice(0, -1))
    : trimmed;
};

// Only unambiguous differences in writing compare equal: spacing, the case of an email address,
// a date or "p.m.", and whether a currency comes before or after its amount. Anything else, such as a
// reformatted date, a number written as a word or a regrouped number, stays visible to compare.
const keyOf = (kind: DetailKind, value: string) => {
  const spaced = value.replaceAll(/\s+/gu, kind === 'quote' ? ' ' : '');
  if (kind === 'email' || kind === 'date') {
    return spaced.toLowerCase();
  }
  if (kind === 'time') {
    return spaced.toLowerCase().replaceAll('.', '');
  }
  if (kind === 'amount') {
    const number = new RegExp(unsigned, 'u').exec(spaced)?.[0] ?? '';
    const signed = new RegExp(sign, 'u').exec(spaced)?.[0] ?? '';
    return `${spaced.replace(number, '').replace(signed, '')} ${signed}${number}`;
  }
  return spaced;
};

const detail = (kind: DetailKind, value: string, label?: string): Detail => ({
  kind,
  value,
  key: keyOf(kind, value),
  ...(label === undefined ? {} : { label }),
});

const detailsIn = (text: string): Detail[] => {
  const found: Array<readonly [number, Detail]> = [];
  for (const match of text.matchAll(pattern)) {
    const group = match.slice(1).findIndex((each) => each !== undefined);
    const written = match[group + 1] ?? '';
    const kind = kinds[group] ?? 'number';
    found.push([
      match.index + match[0].length - written.length,
      detail(kind, kind === 'link' ? trimLink(written) : written),
    ]);
  }
  // Every quote mark is one character.
  for (const match of text.matchAll(quote)) {
    found.push([match.index, detail('quote', match[0].slice(1, -1).trim())]);
  }
  return Arr.sort(
    found,
    Order.mapInput(Order.Number, ([at]: readonly [number, Detail]) => at),
  ).map(([, each]) => each);
};

// A link whose destination its words do not show exactly is still a detail: plain result text
// cannot carry it, so it is removed unless the result writes the destination out.
const hiddenLinks = (document: SemanticDocument, selection: Selection) =>
  selectedLinks(document, selection).flatMap(({ text, href }) => {
    const address = href.startsWith('mailto:')
      ? href.slice('mailto:'.length).split('?')[0]
      : undefined;
    if (address !== undefined) {
      return text.toLowerCase().includes(address.toLowerCase())
        ? []
        : [detail('email', address, text)];
    }
    // Linked words may show the destination without its scheme, as link inspection does.
    const shown = href.replace(/^https?:\/\//u, '').replace(/\/$/u, '');
    return trimLink(href) === href &&
      (text.includes(href) || text.includes(shown))
      ? []
      : [detail('link', href, text)];
  });

// Removes and returns the first detail that matches.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- it removes the match from the caller's list.
const take = (details: Detail[], matches: (other: Detail) => boolean) => {
  const index = details.findIndex(matches);
  return index === -1 ? undefined : details.splice(index, 1)[0];
};

const changeOf = (each: Detail, paired: Detail | undefined): DetailChange => ({
  kind: each.kind,
  status: paired === undefined ? 'removed' : 'changed',
  ...(each.label === undefined ? {} : { label: each.label }),
  original: each.value,
  ...(paired === undefined ? {} : { result: paired.value }),
});

// Compares the details of captured Draft text with a Writing tools result. Equal details are kept;
// left-over details of one kind pair up in order as changed; the rest were removed or added.
export function checkDetails(
  original: Readonly<{
    text: string;
    draft: Readonly<{ body: SemanticDocument }>;
    selection: Selection;
  }>,
  result: string,
): DetailCheck {
  const before = [
    ...detailsIn(original.text),
    ...hiddenLinks(original.draft.body, original.selection),
  ];
  const after = detailsIn(result);
  const removed = before.filter(
    (each) =>
      take(
        after,
        (other) => other.kind === each.kind && other.key === each.key,
      ) === undefined,
  );
  const kept = Arr.dedupe(
    before.filter((each) => !removed.includes(each)).map(({ value }) => value),
  );
  const changes = removed.map((each) =>
    changeOf(
      each,
      take(after, (other) => other.kind === each.kind),
    ),
  );
  return {
    kept,
    changes: [
      ...changes,
      ...after.map((each): DetailChange => ({
        kind: each.kind,
        status: 'added',
        result: each.value,
      })),
    ],
  };
}
