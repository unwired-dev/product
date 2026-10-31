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
  status: 'changed' | 'uncertain' | 'removed' | 'added';
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
const day = `\\d{1,2}(?:${anyCase('st|nd|rd|th')})?`;
const unsigned = String.raw`(?:\d+(?:[.,]\d+)*|[.,]\d+)`;
// A sign belongs to its number: `-40` and `40` differ.
const sign = '[-−+]';
const figure = `${sign}?${unsigned}`;
const linkEnd = String.raw`[^\s<>"“”«»]`;
const currency = String.raw`\p{Sc}|\b[A-Z]{3}\b|Kč`;
// A detail never ends inside a word or before the rest of a number, so `0.5` is not read as `0`.
const edge = String.raw`(?![\p{L}\p{N}]|[.,]\p{N})`;

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
  // A number may carry a unit (`0.5s`, `3rd`); only its figures are compared.
  ['number', String.raw`${figure}(?![.,]?\p{N})`],
];
const kinds = patterns.map(([kind]) => kind);
const pattern = new RegExp(
  `(?:^|[^\\p{L}\\p{N}])(?:${patterns.map(([kind, source]) => `(${source})${kind === 'number' ? '' : edge}`).join('|')})`,
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
const first = (source: string, text: string) =>
  new RegExp(source, 'u').exec(text)?.[0] ?? '';
const amountKey = (amount: string) => {
  const number = first(unsigned, amount);
  const signed = first(sign, amount);
  return `${amount.replace(number, '').replace(signed, '')} ${signed}${number}`;
};
const keys: Partial<Record<DetailKind, (spaced: string) => string>> = {
  email: (spaced) => spaced.toLowerCase(),
  date: (spaced) => spaced.toLowerCase(),
  time: (spaced) => spaced.toLowerCase().replaceAll('.', ''),
  amount: amountKey,
};
const keyOf = (kind: DetailKind, value: string) => {
  const spaced = value.replaceAll(/\s+/gu, kind === 'quote' ? ' ' : '');
  return keys[kind]?.(spaced) ?? spaced;
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
    const written = detailsIn(text);
    // Query fields can change the recipients or content, so the whole mail link stays visible.
    const address =
      href.startsWith('mailto:') && !href.includes('?')
        ? href.slice('mailto:'.length)
        : undefined;
    if (address !== undefined) {
      return written.some(
        (each) => each.kind === 'email' && each.key === keyOf('email', address),
      )
        ? []
        : [detail('email', address, text)];
    }
    // A complete written address may omit the scheme or the root slash, never a path's slash.
    const shown = href.replace(/^https?:\/\//u, '');
    const forms = new Set([
      href,
      shown,
      shown.replace(/^(?<host>[^/?#]+)\/$/u, '$<host>'),
    ]);
    return trimLink(href) === href &&
      written.some((each) => each.kind === 'link' && forms.has(each.value))
      ? []
      : [detail('link', href, text)];
  });

// Removes and returns the first detail that matches.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- it removes the match from the caller's list.
const take = (details: Detail[], matches: (other: Detail) => boolean) => {
  const index = details.findIndex(matches);
  return index === -1 ? undefined : details.splice(index, 1)[0];
};

// Differences that may be another way to write the same detail stay visible as uncertain rather
// than kept: a date that gains or loses a part (`Saturday` and `Saturday, 1 Nov`) or is written in
// figures on one side only (`2026-11-01` and `1 November 2026`), a regrouped number or amount
// (`1,000` and `1000`), and a link that differs only by punctuation at its end.
// Only a separator before a group of three digits can be grouping.
const ungrouped = (key: string) =>
  key.replaceAll(/(?<digit>\d)[.,](?=\d{3}(?!\d))/gu, '$<digit>');
const named = (key: string) => /\p{L}/u.test(key);
const similar: Partial<
  Record<DetailKind, (one: string, other: string) => boolean>
> = {
  date: (one, other) =>
    one.includes(other) || other.includes(one) || named(one) !== named(other),
  number: (one, other) => ungrouped(one) === ungrouped(other),
  amount: (one, other) => ungrouped(one) === ungrouped(other),
  link: (one, other) =>
    one.replace(/[!?]+$/u, '') === other.replace(/[!?]+$/u, ''),
};
const statusOf = (each: Detail, paired: Detail | undefined) => {
  if (paired === undefined) {
    return 'removed';
  }
  return similar[each.kind]?.(each.key, paired.key) === true
    ? 'uncertain'
    : 'changed';
};

const changeOf = (each: Detail, paired: Detail | undefined): DetailChange => ({
  kind: each.kind,
  status: statusOf(each, paired),
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
