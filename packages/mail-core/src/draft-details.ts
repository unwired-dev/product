import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import type { SemanticDocument, Selection } from './semantic-document.ts';

import { replaceSelection, selectedLinks } from './semantic-document.ts';

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

export type DetailChange = Readonly<
  { kind: DetailKind; label?: string } & (
    | { status: 'changed' | 'uncertain'; original: string; result: string }
    | { status: 'removed'; original: string; result?: never }
    | { status: 'added'; original?: never; result: string }
  )
>;

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
const weekdayName = anyCase('(?:mon|tues|wednes|thurs|fri|satur|sun)day');
const weekday = `(?:${weekdayName}|${anyCase('mon|tues?|wed|thurs?|thu|fri|sat|sun')})`;
const unambiguousMonth = anyCase(
  'january|february|april|june|july|september|october|november|december',
);
const month = `(?:${unambiguousMonth}|${anyCase('march|may|august|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec')})(?:\\.(?=,?\\s\\d))?`;
const day = `\\d{1,2}(?:${anyCase('st|nd|rd|th')})?`;
// An exponent belongs to its number: `1e3` and `1e4` differ.
const unsigned = String.raw`(?:(?:\d{1,3}(?:[ \u00a0\u202f]\d{3})+|\d+)(?:[.,]\d+)*|[.,]\d+)(?:[eE][-+]?\d+)?`;
// A sign belongs to its number: `-40` and `40` differ.
const sign = '[-−+]';
const figure = `${sign}?${unsigned}`;
// A full stop after `pm` ends the sentence; only `p.m.` takes its own.
const meridiem = String.raw`[aApP](?:\.[mM]\.?|[mM])`;
const clock = String.raw`\d{1,2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?`;
const zone = `(?:${anyCase('UTC|GMT|CEST|CET|EST|EDT|CST|CDT|MST|MDT|PST|PDT|BST|IST|JST|AEST|AEDT|ACST|ACDT|AWST|NZST|NZDT')})(?:[-+]\\d{1,2}(?::?\\d{2})?)?|[zZ]|[-+]\\d{2}(?::?\\d{2})?`;
// An apostrophe can join an address's local part, but a leading one is a quotation mark.
const emailStart = String.raw`[\p{L}\p{N}._%+!#$&*/=?^\x60{|}~-]`;
const emailRest = String.raw`[\p{L}\p{N}._%+!#$&'*/=?^\x60{|}~-]*`;
const linkEnd = String.raw`[^\s<>"“”«»]`;
const host = `(?:[\\p{L}\\p{N}-]+\\.)+(?:\\p{L}{2,}|${anyCase('xn')}--[\\p{L}\\p{N}-]+)(?![@\\p{L}\\p{N}-])`;
const web = `${host}(?::\\d+)?`;
const currency = String.raw`\p{Sc}|[A-Z]{3}|Kč`;
// A detail never ends inside a word or before the rest of a number, so `0.5` is not read as `0`.
const edge = String.raw`(?![\p{L}\p{N}]|[.,]\p{N})`;

// A detail starts and ends outside a word. Earlier alternatives win where details overlap, so an
// amount's number or a date's day is not counted again. Quotes are read separately because they
// may hold other details.
const patterns: ReadonlyArray<readonly [DetailKind, string]> = [
  // A path/query can contain an email address; its case-sensitive destination wins first.
  [
    'link',
    `${anyCase('mailto')}:${linkEnd}+\\?${linkEnd}*|${anyCase('https?')}://${linkEnd}+|${web}[/?#]${linkEnd}*`,
  ],
  // Before bare domains, so a dotted local part is not split. Apostrophes may occur inside it.
  [
    'email',
    String.raw`${emailStart}${emailRest}@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+`,
  ],
  ['link', web],
  [
    'date',
    [
      String.raw`\d{4}[./-]\d{1,2}[./-]\d{1,2}(?:[tT]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:[zZ]|[-+]\d{2}(?::?\d{2})?)?)?`,
      `\\d{1,2}[./]\\d{1,2}[./]\\d{2,4}`,
      // A day and month in figures without a year are written with a slash; `11.01` is a decimal.
      `\\d{1,2}/\\d{1,2}`,
      `(?:${weekday},?\\s)?(?:${day}\\s${month}|${month}\\s${day})(?:,?\\s\\d{4})?`,
      weekdayName,
      `${month}\\s\\d{4}`,
      unambiguousMonth,
      // Ambiguous standalone names need capitals, so `you may` and `sat down` are words.
      `(?=\\p{Lu})(?:${weekday}|${month})`,
      anyCase('today|tomorrow|tonight|yesterday'),
    ].join('|'),
  ],
  [
    'amount',
    // After dates, so an all-caps month after a day (`3 NOV`) is not read as a currency code.
    `${sign}?(?:${currency})\\s?${figure}(?:\\s?(?:${currency}))?|${figure}\\s?(?:${currency})`,
  ],
  [
    'time',
    `(?:${clock}(?:\\s?${meridiem})?|\\d{1,2}\\s?${meridiem})(?:\\.?\\s?(?:${zone}))?`,
  ],
  // A number may carry a unit (`0.5s`, `3rd`); only its figures are compared.
  [
    'number',
    String.raw`${figure}(?:\s*[/–—−:-]\s*${figure})*(?:\s?%)?(?![.,]?\p{N})`,
  ],
];
const kinds = patterns.map(([kind]) => kind);
const pattern = new RegExp(
  `(?:^|[^\\p{L}\\p{N}])(?:${patterns.map(([kind, source]) => `(${source})${kind === 'number' ? '' : edge}`).join('|')})`,
  'gu',
);
const quote =
  /(?<![\p{L}\p{N}])"[^"]+"(?![\p{L}\p{N}])|“[^”]+”|„[^“”]+[“”]|«[^»]+»/gu;

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
  const affixes = amount.replace(number, '');
  const signed = first(sign, affixes);
  return `${affixes.replace(signed, '').replaceAll(/\s/gu, '')} ${signed}${number}`;
};
const keys: Partial<Record<DetailKind, (spaced: string) => string>> = {
  email: (spaced) => spaced.toLowerCase(),
  date: (spaced) => spaced.toLowerCase(),
  time: (spaced) =>
    spaced
      .toLowerCase()
      .replaceAll(/(?<period>[ap])\.?m\.?/gu, '$<period>m')
      .replaceAll(' ', ''),
  number: (spaced) =>
    spaced.replaceAll(/\s*(?<separator>[/–—−:%-])\s*/gu, '$<separator>'),
  amount: amountKey,
};
const keyOf = (kind: DetailKind, value: string) => {
  const spaced = value.replaceAll(
    /\s+/gu,
    kind === 'email' || kind === 'link' ? '' : ' ',
  );
  return keys[kind]?.(spaced) ?? spaced;
};

const detail = (kind: DetailKind, value: string, label?: string): Detail => ({
  kind,
  value,
  key: keyOf(kind, value),
  ...(label === undefined ? {} : { label }),
});

// Any run of spaces or line breaks reads as one space, so wrapping never splits a detail.
const detailsIn = (source: string): Detail[] => {
  const text = source.replaceAll(/\s{2,}|\n/gu, ' ');
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
      href.replace(/^(?<root>https?:\/\/[^/?#]+)\/$/u, '$<root>'),
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
  key.replaceAll(/(?<digit>\d)[., ](?=\d{3}(?!\d))/gu, '$<digit>');
// Keep date spacing above so an added year stays separate from a day. `3 Nov` is not in `13 Nov`.
const within = (whole: string, part: string) =>
  new RegExp(
    `(?:^|\\D)${part.replaceAll(/[.*+?^${}()|[\]\\/]/gu, String.raw`\$&`)}(?!\\d)`,
    'u',
  ).test(whole);
const named = (key: string) => /\p{L}/u.test(key);
const similar: Partial<
  Record<DetailKind, (one: string, other: string) => boolean>
> = {
  date: (one, other) =>
    within(one, other) || within(other, one) || named(one) !== named(other),
  number: (one, other) => ungrouped(one) === ungrouped(other),
  amount: (one, other) => ungrouped(one) === ungrouped(other),
  link: (one, other) =>
    one.replace(/[!?]+$/u, '') === other.replace(/[!?]+$/u, ''),
};
const changeOf = (each: Detail, paired: Detail | undefined): DetailChange => {
  const original = {
    kind: each.kind,
    ...(each.label === undefined ? {} : { label: each.label }),
    original: each.value,
  };
  return paired === undefined
    ? { ...original, status: 'removed' }
    : {
        ...original,
        status:
          similar[each.kind]?.(each.key, paired.key) === true
            ? 'uncertain'
            : 'changed',
        result: paired.value,
      };
};

// The text that replaces captured Draft text: the result, trimmed for the preview, between the
// capture's own leading and trailing whitespace so neighbouring words stay separated.
export const draftReplacement = (selected: string, replacement: string) =>
  `${/^\s*/u.exec(selected)?.[0] ?? ''}${replacement.trim()}${/\s*$/u.exec(selected)?.[0] ?? ''}`;

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
  // The applied Draft, not the plain result, carries the links: replaced text keeps the link of
  // its first replaced character.
  const start = Math.min(original.selection.start, original.selection.end);
  const applied = replaceSelection(
    original.draft.body,
    original.selection,
    draftReplacement(original.text, result),
  );
  const after = [
    ...detailsIn(result),
    ...hiddenLinks(applied.document, {
      start,
      end: applied.selection?.end ?? start,
    }),
  ];
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
