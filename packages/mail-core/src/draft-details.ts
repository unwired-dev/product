import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';

import { selectedLinks } from './semantic-document.ts';
import type { SemanticDocument, Selection } from './semantic-document.ts';

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

const weekday = '(?:[Mm]on|[Tt]ues|[Ww]ednes|[Tt]hurs|[Ff]ri|[Ss]atur|[Ss]un)day';
const month =
  '(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)(?:\\.(?=,?\\s\\d))?';
const day = '\\d{1,2}(?:st|nd|rd|th)?';
const figure = '\\d+(?:[.,]\\d+)*';
const currency = '\\p{Sc}|\\b[A-Z]{3}\\b|Kč';
const edge = '(?![\\p{L}\\p{N}])';

// A detail starts and ends outside a word. Earlier alternatives win where details overlap, so an
// amount's number or a date's day is not counted again. Quotes are read separately because they
// may hold other details.
const patterns: ReadonlyArray<readonly [DetailKind, string]> = [
  ['link', '(?:https?://|www\\.)[^\\s<>"“”«»]+'],
  ['email', '[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+'],
  [
    'amount',
    `(?:${currency})\\s?${figure}|${figure}\\s?(?:${currency})`,
  ],
  [
    'date',
    [
      `\\d{4}-\\d{1,2}-\\d{1,2}`,
      `\\d{1,2}[./]\\d{1,2}[./]\\d{2,4}`,
      `(?:${weekday},?\\s)?(?:${day}\\s${month}|${month}\\s${day})(?:,?\\s\\d{4})?`,
      weekday,
      '[Tt]oday|[Tt]omorrow|[Tt]onight|[Yy]esterday',
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
const quote = /"([^"\n]+)"|“([^”\n]+)”|„([^“”\n]+)[“”]|«([^»\n]+)»/gu;

// A written link ends before sentence punctuation or a closing quote, and before a closing
// parenthesis it did not open.
const trimLink = (link: string): string => {
  const trimmed = link.replace(/[.,;:!?'"’”»]+$/u, '');
  return trimmed.endsWith(')') &&
    trimmed.split(')').length > trimmed.split('(').length
    ? trimLink(trimmed.slice(0, -1))
    : trimmed;
};

// Only unambiguous differences in writing compare equal: spacing, the case of an email address,
// a date or "p.m.", and whether a currency comes before or after its amount. Anything else, such as a
// reformatted date, a number written as a word or a regrouped number, stays visible to compare.
const keyOf = (kind: DetailKind, value: string) => {
  const spaced = value.replace(/\s+/gu, kind === 'quote' ? ' ' : '');
  if (kind === 'email' || kind === 'date') {
    return spaced.toLowerCase();
  }
  if (kind === 'time') {
    return spaced.toLowerCase().replaceAll('.', '');
  }
  if (kind === 'amount') {
    const number = new RegExp(figure, 'u').exec(spaced)?.[0] ?? '';
    return `${spaced.replace(number, '')} ${number}`;
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
  const found: Array<Detail & { at: number }> = [];
  for (const match of text.matchAll(pattern)) {
    const group = match.slice(1).findIndex((each) => each !== undefined);
    const written = match[group + 1] ?? '';
    const kind = kinds[group] ?? 'number';
    found.push({
      ...detail(kind, kind === 'link' ? trimLink(written) : written),
      at: match.index + match[0].length - written.length,
    });
  }
  for (const match of text.matchAll(quote)) {
    const inner = match.slice(1).find((each) => each !== undefined) ?? '';
    found.push({ ...detail('quote', inner.trim()), at: match.index });
  }
  return Arr.sort(
    found,
    Order.mapInput(Order.Number, ({ at }: { at: number }) => at),
  ).map(({ at: _, ...each }) => each);
};

// A link whose destination its words do not show is still a detail: plain result text cannot
// carry it, so it is removed unless the result writes the destination out.
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
    return text.includes(href) ? [] : [detail('link', href, text)];
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
  const kept: string[] = [];
  const removed: Detail[] = [];
  for (const each of before) {
    const index = after.findIndex(
      (other) => other.kind === each.kind && other.key === each.key,
    );
    if (index === -1) {
      removed.push(each);
    } else {
      after.splice(index, 1);
      if (!kept.includes(each.value)) {
        kept.push(each.value);
      }
    }
  }
  const changes: DetailChange[] = [];
  for (const each of removed) {
    const index = after.findIndex((other) => other.kind === each.kind);
    const [paired] = index === -1 ? [] : after.splice(index, 1);
    changes.push({
      kind: each.kind,
      status: paired === undefined ? 'removed' : 'changed',
      ...(each.label === undefined ? {} : { label: each.label }),
      original: each.value,
      ...(paired === undefined ? {} : { result: paired.value }),
    });
  }
  for (const each of after) {
    changes.push({ kind: each.kind, status: 'added', result: each.value });
  }
  return { kept, changes };
}
