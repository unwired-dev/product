import type { Draft, Recipient } from './draft-model.ts';
import type { Asset, Block, Mark } from './semantic-document.ts';

import { assetsOf } from './draft-model.ts';
import { imagesOf } from './semantic-document.ts';

// An outgoing RFC 5322 message as native code sends it: literal ASCII text, and Draft Assets whose
// verified bytes native code inserts as base64 lines, so an asset's bytes never cross the bridge.
export type MessageSegment =
  | Readonly<{ text: string }>
  | Readonly<{ asset: Readonly<{ id: string; digest: string }> }>;

export type OutgoingMessage = Readonly<{
  segments: readonly MessageSegment[];
  // The exact size of the assembled message in bytes, assets included.
  size: number;
}>;

// The largest message Gmail accepts through its messages.send upload.
export const gmailMessageLimit = 35 * 1024 * 1024;

const crlf = '\r\n';
const lineLength = 76;

// Base64 in lines of 76 characters, as native code also writes an asset's bytes.
export const base64Lines = (bytes: Readonly<Uint8Array>) => {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCodePoint(byte);
  }
  const encoded = btoa(binary);
  const lines: string[] = [];
  for (let at = 0; at < encoded.length; at += lineLength) {
    lines.push(encoded.slice(at, at + lineLength));
  }
  return lines.join(crlf);
};
const base64Size = (bytes: number) => {
  const encoded = 4 * Math.ceil(bytes / 3);
  return encoded + 2 * Math.max(0, Math.ceil(encoded / lineLength) - 1);
};
const utf8 = (text: string) => new TextEncoder().encode(text);

// Header text never carries a line break or other control character.
const headerText = (text: string) =>
  text.replaceAll(/[\p{Cc}\u2028\u2029]+/gu, ' ').trim();
const printable = /^[\u0020-\u007E]*$/u;

// RFC 2047 encoded words of at most 45 UTF-8 bytes each, never splitting a character.
const encodedWords = (text: string) => {
  const words: string[] = [];
  let word = '';
  for (const character of text) {
    if (utf8(word + character).length > 45) {
      words.push(word);
      word = '';
    }
    word += character;
  }
  words.push(word);
  return words.map(
    (each) => `=?UTF-8?B?${base64Lines(utf8(each)).replaceAll(crlf, '')}?=`,
  );
};

// Header items, folded onto continuation lines so no line exceeds 78 characters where items allow.
const header = (name: string, items: readonly string[], separator = ' ') => {
  const lines = [`${name}:`];
  for (const [index, item] of items.entries()) {
    const line = lines.at(-1) ?? '';
    const joiner = index === 0 ? ' ' : separator;
    if (index > 0 && line.length + joiner.length + item.length > 78) {
      lines[lines.length - 1] = line + separator.trimEnd();
      lines.push(` ${item}`);
    } else {
      lines[lines.length - 1] = line + joiner + item;
    }
  }
  return lines.join(crlf) + crlf;
};
const unstructured = (name: string, text: string) => {
  const value = headerText(text);
  return printable.test(value) &&
    value.split(' ').every((word) => word.length <= 60)
    ? header(
        name,
        value.split(' ').filter((word) => word !== ''),
      )
    : header(name, encodedWords(value));
};

const quotedName = (name: string) =>
  printable.test(name) && name.length <= 60
    ? `"${name.replaceAll(/["\\]/gu, String.raw`\$&`)}"`
    : encodedWords(name).join(`${crlf} `);
const mailbox = ({ name, address }: Recipient) => {
  const shown = name === undefined ? '' : headerText(name);
  return shown === '' ? address : `${quotedName(shown)} <${address}>`;
};
const addressList = (name: string, recipients: readonly Recipient[]) =>
  recipients.length === 0 ? '' : header(name, recipients.map(mailbox), ', ');

const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const two = (value: number) => value.toString().padStart(2, '0');
const dateOf = (at: number) => {
  const date = new Date(at);
  return `${weekdays[date.getUTCDay()]}, ${two(date.getUTCDate())} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()} ${two(date.getUTCHours())}:${two(date.getUTCMinutes())}:${two(date.getUTCSeconds())} +0000`;
};

// Parameter values: quoted when printable, otherwise RFC 2231 percent-encoded UTF-8.
const parameter = (name: string, value: string) => {
  const text = headerText(value);
  if (printable.test(text) && text.length <= 60) {
    return `${name}="${text.replaceAll(/["\\]/gu, String.raw`\$&`)}"`;
  }
  const parts = [''];
  for (const byte of utf8(text)) {
    const token = /[\w.~-]/u.test(String.fromCodePoint(byte))
      ? String.fromCodePoint(byte)
      : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
    if ((parts.at(-1)?.length ?? 0) + token.length > 60) {
      parts.push('');
    }
    parts[parts.length - 1] += token;
  }
  return parts.length === 1
    ? `${name}*=UTF-8''${parts[0]}`
    : parts
        .map(
          (part, index) =>
            `${name}*${index}*=${index === 0 ? "UTF-8''" : ''}${part}`,
        )
        .join(`;${crlf} `);
};
// A picker-reported type is used only when it is a plain MIME type.
const contentType = (asset: Asset) =>
  /^[\w.+-]+\/[\w.+-]+$/u.test(asset.type)
    ? asset.type.toLowerCase()
    : 'application/octet-stream';
export const contentIdOf = (asset: Pick<Asset, 'id'>) =>
  `${asset.id}@unwired.invalid`;

const escapeHtml = (text: string) =>
  text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
const tags: Readonly<Record<Mark, string>> = {
  code: 'code',
  bold: 'strong',
  italic: 'em',
  underline: 'u',
  strikethrough: 's',
};
const htmlSpans = (spans: Block['spans']) =>
  spans
    .map((span) => {
      const inner =
        'image' in span
          ? `<img src="cid:${contentIdOf(span.image)}" alt="${escapeHtml(span.image.name)}">`
          : escapeHtml(span.text);
      return (span.marks ?? []).reduceRight(
        (html, mark) => `<${tags[mark]}>${html}</${tags[mark]}>`,
        inner,
      );
    })
    .join('');
const containers: Partial<Record<Block['kind'], string>> = {
  bulleted: 'ul',
  numbered: 'ol',
  quote: 'blockquote',
  code: 'pre',
};
const headings: Partial<Record<Block['kind'], string>> = {
  heading1: 'h1',
  heading2: 'h2',
  heading3: 'h3',
};
const htmlBlock = ({ kind, spans }: Block) => {
  const inner = htmlSpans(spans);
  const heading = headings[kind];
  if (heading !== undefined) {
    return `<${heading}>${inner}</${heading}>`;
  }
  if (kind === 'bulleted' || kind === 'numbered') {
    return `<li>${inner}</li>`;
  }
  return kind === 'code' ? inner : `<p>${inner === '' ? '<br>' : inner}</p>`;
};
// Consecutive list items, quotes and code lines share one container.
// fallow-ignore-next-line complexity -- One pass opens and closes each run of blocks in reading order.
const htmlOf = (document: readonly Block[]) => {
  let html = '';
  for (const [index, block] of document.entries()) {
    const container = containers[block.kind];
    const previous = document[index - 1]?.kind;
    const opens = container !== undefined && previous !== block.kind;
    if (opens) {
      html += block.kind === 'code' ? '<pre><code>' : `<${container}>`;
    } else if (block.kind === 'code') {
      html += '\n';
    }
    html += htmlBlock(block);
    if (container !== undefined && document[index + 1]?.kind !== block.kind) {
      html += block.kind === 'code' ? '</code></pre>' : `</${container}>`;
    }
  }
  return html;
};

const plainOf = (document: readonly Block[]) => {
  let number = 0;
  return document
    .map(({ kind, spans }) => {
      number = kind === 'numbered' ? number + 1 : 0;
      const text = spans
        .map((span) => ('image' in span ? `[${span.image.name}]` : span.text))
        .join('');
      if (kind === 'bulleted') {
        return `- ${text}`;
      }
      if (kind === 'numbered') {
        return `${number}. ${text}`;
      }
      return kind === 'quote' ? `> ${text}` : text;
    })
    .join(crlf);
};

type Part = Readonly<{ head: string; body: readonly MessageSegment[] }>;
const textPart = (type: string, text: string): Part => ({
  head: `Content-Type: ${type}; charset=UTF-8${crlf}Content-Transfer-Encoding: base64${crlf}`,
  body: [{ text: base64Lines(utf8(text)) }],
});
const assetPart = (asset: Asset, inline: boolean): Part => {
  if (asset.state !== 'complete') {
    throw new Error('Only complete assets are sent');
  }
  const disposition = inline
    ? `inline; ${parameter('filename', asset.name)}${crlf}Content-ID: <${contentIdOf(asset)}>`
    : `attachment; ${parameter('filename', asset.name)}`;
  return {
    head: `Content-Type: ${contentType(asset)}; ${parameter('name', asset.name)}${crlf}Content-Disposition: ${disposition}${crlf}Content-Transfer-Encoding: base64${crlf}`,
    body: [{ asset: { id: asset.id, digest: asset.digest } }],
  };
};
const multipart = (
  subtype: string,
  boundary: string,
  parts: readonly Part[],
): Part => ({
  head: `Content-Type: multipart/${subtype}; boundary="${boundary}"${crlf}`,
  body: [
    ...parts.flatMap(({ head, body }) => [
      { text: `--${boundary}${crlf}${head}${crlf}` },
      ...body,
      { text: crlf },
    ]),
    { text: `--${boundary}--` },
  ],
});
// One part alone stays as it is; several are wrapped in a multipart.
const nested = (subtype: string, boundary: string, parts: readonly Part[]) =>
  parts.length === 1 && parts[0] !== undefined
    ? parts[0]
    : multipart(subtype, boundary, parts);

const sizeOf = (
  segments: readonly MessageSegment[],
  assets: readonly Asset[],
) => {
  const sizes = new Map(
    assets.flatMap((asset) =>
      asset.state === 'complete' ? [[asset.id, asset.size] as const] : [],
    ),
  );
  return segments.reduce(
    (total, segment) =>
      total +
      ('text' in segment
        ? segment.text.length
        : base64Size(sizes.get(segment.asset.id) ?? 0)),
    0,
  );
};

// The message Gmail sends for a Draft: its recipients, subject and reply headers, the formatted body
// with a plain-text alternative, inline images by Content-ID and attachments. Boundaries start with
// `=_`, which base64 and the encoded headers never produce at the start of a line. Every asset must
// be complete.
export function outgoingMessage(
  draft: Draft,
  { date, boundary }: Readonly<{ date: number; boundary: string }>,
): OutgoingMessage {
  const body = [...draft.body, ...(draft.quoted ?? [])];
  // A repeated image is one part, however often the body shows it.
  const images = [
    ...new Map(
      [
        ...imagesOf(draft.body),
        ...(draft.quoted === undefined ? [] : imagesOf(draft.quoted)),
      ].map((image) => [image.id, image]),
    ).values(),
  ];
  const alternative = multipart('alternative', `=_${boundary}_a`, [
    textPart('text/plain', plainOf(body)),
    textPart(
      'text/html',
      `<!DOCTYPE html><html><body>${htmlOf(body)}</body></html>`,
    ),
  ]);
  const related = nested('related', `=_${boundary}_r`, [
    alternative,
    ...images.map((image) => assetPart(image, true)),
  ]);
  const content = nested('mixed', `=_${boundary}_m`, [
    related,
    ...(draft.attachments ?? []).map((asset) => assetPart(asset, false)),
  ]);
  const { response } = draft;
  const threading =
    response === undefined || response.kind === 'forward'
      ? ''
      : (response.inReplyTo === undefined
          ? ''
          : header('In-Reply-To', [headerText(response.inReplyTo)])) +
        (response.references.length === 0
          ? ''
          : header('References', response.references.map(headerText)));
  // Gmail delivers to Bcc recipients and removes the header from what others receive.
  const head = `From: ${draft.from}${crlf}${addressList('To', draft.to)}${addressList('Cc', draft.cc)}${addressList('Bcc', draft.bcc)}${unstructured('Subject', draft.subject)}Date: ${dateOf(date)}${crlf}${threading}MIME-Version: 1.0${crlf}`;
  const segments = [
    { text: head + content.head + crlf },
    ...content.body,
  ].reduce<MessageSegment[]>((joined, segment) => {
    const last = joined.at(-1);
    if ('text' in segment && last !== undefined && 'text' in last) {
      joined[joined.length - 1] = { text: last.text + segment.text };
    } else {
      joined.push(segment);
    }
    return joined;
  }, []);
  return { segments, size: sizeOf(segments, assetsOf(draft)) };
}
