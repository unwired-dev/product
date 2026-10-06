import { vettedHref } from './link-inspection.ts';

// Readable message text with vetted links: the plain-text presentation, and the fallback when
// rich presentation is unavailable. Nothing in it renders markup or loads anything.
export interface BodySpan {
  readonly text: string;
  // Only http, https, mailto and tel destinations; the host confirms before opening one.
  readonly href?: string;
}
export interface ReadableBody {
  readonly paragraphs: ReadonlyArray<readonly BodySpan[]>;
  // The message referenced images that are not shown.
  readonly hidesImages: boolean;
}

// The most links one message offers. Each becomes a native control, so later addresses stay
// readable text that does not open.
export const messageLinkLimit = 200;

// Format and combining characters, and spacing, never make a body readable on their own.
const invisible = /^[\s\p{Cf}\p{Mn}\p{Z}]*$/u;

export const hasVisibleText = (text: string) => !invisible.test(text);

export const hasReadableText = (body: ReadableBody) =>
  body.paragraphs.some((spans) =>
    spans.some(({ text }) => hasVisibleText(text)),
  );

// Collects spans into paragraphs, merging neighbours that share a link.
export function paragraphBuilder() {
  const paragraphs: BodySpan[][] = [];
  let spans: BodySpan[] = [];
  let links = 0;
  const add = (text: string, href: string | undefined) => {
    const last = spans.at(-1);
    if (last !== undefined && last.href === href) {
      spans[spans.length - 1] = { ...last, text: last.text + text };
    } else if (text !== '') {
      spans.push(href === undefined ? { text } : { text, href });
    }
  };
  const end = () => {
    const trimmed = spans
      .map((span) => ({
        ...span,
        text: span.text.replaceAll(/ {2,}/gu, ' ').replaceAll(/ *\n */gu, '\n'),
      }))
      .filter((span) => span.text !== '');
    const first = trimmed.at(0);
    if (first !== undefined) {
      trimmed[0] = { ...first, text: first.text.trimStart() };
    }
    const last = trimmed.at(-1);
    if (last !== undefined) {
      trimmed[trimmed.length - 1] = { ...last, text: last.text.trimEnd() };
    }
    if (trimmed.some((span) => span.text.trim() !== '')) {
      // One HTML anchor can cross many paragraphs. Hosts offer a control for each linked
      // span, so count finalized fallback spans independently of collected rich anchors.
      paragraphs.push(
        trimmed.map((span) => {
          if (span.href === undefined || !hasVisibleText(span.text)) {
            return { text: span.text };
          }
          if (links >= messageLinkLimit) {
            return { text: span.text };
          }
          links += 1;
          return span;
        }),
      );
    }
    spans = [];
  };
  return { add, end, paragraphs };
}

const link = /(?:https?:\/\/|mailto:|tel:)[^\s<>"]+/giu;

// Plain text keeps its line breaks; blank lines separate paragraphs and addresses become links.
export function readableText(content: string): ReadableBody {
  const builder = paragraphBuilder();
  let links = 0;
  for (const paragraph of content
    .replaceAll(/\r\n?/gu, '\n')
    .split(/\n\s*\n/u)) {
    let start = 0;
    for (const match of paragraph.matchAll(link)) {
      // Sentence punctuation after an address is not part of it.
      const href = match[0].replace(/[.,;:!?)\]'"]+$/u, '');
      builder.add(paragraph.slice(start, match.index), undefined);
      const destination =
        links < messageLinkLimit ? vettedHref(href) : undefined;
      links += destination === undefined ? 0 : 1;
      builder.add(href, destination);
      start = match.index + href.length;
    }
    builder.add(paragraph.slice(start), undefined);
    builder.end();
  }
  return { paragraphs: builder.paragraphs, hidesImages: false };
}

const entities = new Map([
  ['amp', '&'],
  ['lt', '<'],
  ['gt', '>'],
  ['quot', '"'],
  ['apos', "'"],
  ['nbsp', ' '],
  ['ndash', '–'],
  ['mdash', '—'],
  ['lsquo', '‘'],
  ['rsquo', '’'],
  ['ldquo', '“'],
  ['rdquo', '”'],
  ['hellip', '…'],
  ['bull', '•'],
  ['middot', '·'],
  ['copy', '©'],
  ['reg', '®'],
  ['trade', '™'],
  ['euro', '€'],
  ['zwnj', ''],
  ['zwj', ''],
  ['shy', ''],
]);

// Decodes character references in Gmail's HTML-escaped snippets; an unknown name stays as written.
export const unescapeHtml = (text: string) =>
  text.replaceAll(/&#?[\da-z]{1,8};/giu, (whole) => {
    const body = whole.slice(1, -1).toLowerCase();
    let code = Number.NaN;
    if (/^#\d+$/u.test(body)) {
      code = Number(body.slice(1));
    } else if (/^#x[\da-f]+$/u.test(body)) {
      code = Number.parseInt(body.slice(2), 16);
    } else {
      return entities.get(body) ?? whole;
    }
    return code > 0 && code <= 1_114_111 ? String.fromCodePoint(code) : whole;
  });
