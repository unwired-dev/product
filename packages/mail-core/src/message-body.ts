import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { BodyLink, InlineImage } from './html-sanitizer.ts';
import type { ReadableBody } from './readable-text.ts';

import { sanitizeHtml } from './html-sanitizer.ts';
import { inlineImageLimits, inspectImage } from './inline-images.ts';
import { readableText } from './readable-text.ts';

export type { BodyLink, InlineImage } from './html-sanitizer.ts';
export type { BodySpan, ReadableBody } from './readable-text.ts';
export { unescapeHtml } from './readable-text.ts';

// One part of a Gmail `format=full` or `format=metadata` message.
export interface GmailPart {
  readonly mimeType?: string;
  readonly filename?: string;
  readonly headers?: ReadonlyArray<Readonly<{ name: string; value: string }>>;
  readonly body?: Readonly<{
    data?: string;
    attachmentId?: string;
    size: number;
  }>;
  readonly parts?: readonly GmailPart[];
}
const GmailPartSchema = Schema.Struct({
  mimeType: Schema.optionalKey(Schema.String),
  filename: Schema.optionalKey(Schema.String),
  headers: Schema.optionalKey(
    Schema.Array(Schema.Struct({ name: Schema.String, value: Schema.String })),
  ),
  body: Schema.optionalKey(
    Schema.Struct({
      size: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
      data: Schema.optionalKey(Schema.String),
      attachmentId: Schema.optionalKey(
        Schema.String.check(Schema.isPattern(/^[\w-]+$/u)),
      ),
    }),
  ),
  parts: Schema.optionalKey(
    Schema.Array(
      Schema.suspend((): Schema.Codec<GmailPart> => GmailPartSchema),
    ),
  ),
});

// Real messages nest a few multipart levels. A larger tree is refused before the recursive part
// decoder and the body traversals run, so a crafted message fails as malformed instead of
// exhausting the stack. Every part counts, including discarded attachment subtrees.
const mimeTreeLimits = { depth: 32, parts: 10_000 };

const childParts = (part: unknown): readonly unknown[] =>
  Predicate.hasProperty(part, 'parts') && Array.isArray(part.parts)
    ? part.parts
    : [];

const withinMimeLimits = (payload: unknown) => {
  let level = [payload];
  let parts = 0;
  for (let depth = 0; level.length > 0; depth += 1) {
    parts += level.length;
    if (depth > mimeTreeLimits.depth || parts > mimeTreeLimits.parts) {
      return false;
    }
    level = level.flatMap(childParts);
  }
  return true;
};

export const decodeFullMessage = Schema.decodeUnknownEffect(
  Schema.fromJsonString(
    Schema.Struct({
      id: Schema.String,
      payload: Schema.Unknown.check(
        Schema.makeFilter(withinMimeLimits, {
          message: `more than ${mimeTreeLimits.depth} nested or ${mimeTreeLimits.parts} MIME parts`,
        }),
      ).pipe(Schema.decodeTo(GmailPartSchema)),
    }),
  ),
);
export const decodeAttachment = Schema.decodeUnknownEffect(
  Schema.fromJsonString(
    Schema.Struct({
      data: Schema.String,
      size: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
    }),
  ),
);

const InlineImageSchema = Schema.Struct({
  contentId: Schema.String,
  mimeType: Schema.Literals([
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
  ]),
  data: Schema.String.check(Schema.isPattern(/^[\d+/A-Za-z]*={0,2}$/u)),
  width: Schema.Int,
  height: Schema.Int,
});

// The decoded body kept in the Bounded Encrypted Body Cache. It names its message, so a cached
// entry is never shown for another one. `html` is the original decoded alternative; sanitizing
// changes only its presentation. `images` records MIME Inline Image resolution for an explicit
// open; without it, an online open resolves the HTML's references first. An `excluded` entry
// records that prefetch found no single readable part, and holds no body.
const BodyDocumentSchema = Schema.Struct({
  version: Schema.Literal(2),
  id: Schema.String,
  text: Schema.optionalKey(Schema.String),
  html: Schema.optionalKey(Schema.String),
  images: Schema.optionalKey(
    Schema.Struct({
      admitted: Schema.Array(InlineImageSchema),
      refused: Schema.Array(Schema.String),
    }),
  ),
  excluded: Schema.optionalKey(Schema.Literal(true)),
  // Received attachment metadata, without bytes; absent in bodies cached before it was kept.
  attachments: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        locator: Schema.String.check(Schema.isPattern(/^\d+(?:\.\d+)*$/u)),
        name: Schema.String,
        mimeType: Schema.String,
        size: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
      }),
    ),
  ),
});
export type BodyDocument = typeof BodyDocumentSchema.Type;
export const decodeBodyDocument = Schema.decodeUnknownOption(
  Schema.fromJsonString(BodyDocumentSchema),
);
// The native cache's reply; an unreadable document reads as none and is fetched again.
export const decodeCachedBody = Schema.decodeUnknownEffect(
  Schema.Struct({ document: Schema.NullOr(Schema.String) }),
);
export const encodeBodyDocument = Schema.encodeEffect(
  Schema.fromJsonString(BodyDocumentSchema),
);

export const header = (part: GmailPart, name: string) =>
  part.headers?.find((candidate) => candidate.name.toLowerCase() === name)
    ?.value ?? '';

const headerValues = (part: GmailPart, name: string) =>
  (part.headers ?? [])
    .filter((candidate) => candidate.name.toLowerCase() === name)
    .map(({ value }) => value);

const commentNesting = new Map([
  ['(', 1],
  [')', -1],
]);

// The offset after a nested comment; an unterminated comment has no valid end.
const commentEnd = (value: string, from: number) => {
  let depth = 1;
  let at = from;
  while (at < value.length && depth > 0) {
    const character = value[at] ?? '';
    depth += commentNesting.get(character) ?? 0;
    at += character === '\\' ? 2 : 1;
  }
  return depth === 0 ? at : undefined;
};

const commentDelimiters = (value: string) =>
  [...value.matchAll(/"(?:\\.|[^"\\])*"|[()]/gu)].filter(
    (match) => match[0].length === 1,
  );

// RFC comments may be nested and may escape parentheses; they are not header tokens.
// Comments become the separator, empty by default; a Content-ID passes a space so a comment
// inside the ID leaves whitespace there instead of joining its halves.
const withoutComments = (value: string, separator = '') => {
  let from = 0;
  let output = '';
  for (const delimiter of commentDelimiters(value)) {
    if (delimiter.index >= from) {
      const end =
        delimiter[0] === '('
          ? commentEnd(value, delimiter.index + 1)
          : undefined;
      if (end === undefined) {
        return '';
      }
      output += value.slice(from, delimiter.index) + separator;
      from = end;
    }
  }
  return output + value.slice(from);
};

const headerToken = (value: string) =>
  /^\s*(?<token>[\w/-]+)(?=\s|;|$)/u
    .exec(withoutComments(value))?.[1]
    ?.toLowerCase() ?? '';

const mimeType = (part: GmailPart) => {
  const types = headerValues(part, 'content-type').map(headerToken);
  if (types.length === 0) {
    return part.mimeType?.toLowerCase() ?? '';
  }
  return types.every((type) => type === types[0]) ? (types[0] ?? '') : '';
};

// Any present disposition other than a recognized inline one, including a malformed or
// extension value, keeps a part out of the body and out of prefetch.
// Every Content-Disposition token a part carries. Untrusted parts can repeat the header, so
// each occurrence counts, never only the first.
const dispositions = (part: GmailPart) =>
  headerValues(part, 'content-disposition').map(headerToken);

// Inline only when it declares a disposition and every occurrence is a recognized inline one.
const declaredInline = (part: GmailPart) => {
  const tokens = dispositions(part);
  return tokens.length > 0 && tokens.every((token) => token === 'inline');
};

const isAttachment = (part: GmailPart) =>
  dispositions(part).some((token) => token !== 'inline');

// Attached messages and attachment subtrees never supply the body or its inline images.
const isContainerOutsideBody = (part: GmailPart) =>
  isAttachment(part) ||
  mimeType(part) === 'message/rfc822' ||
  ((part.parts ?? []).length > 0 && (part.filename ?? '') !== '');

// Parts never searched for the body: attachments, attached messages and named files.
const outsideBody = (part: GmailPart) =>
  isContainerOutsideBody(part) || (part.filename ?? '') !== '';

// Multipart containers searched for the body and its inline images. Signed and report
// containers carry an ordinary readable first part; an unrecognized or extension container,
// such as multipart/x-*, contributes nothing without an explicit attachment download.
const recognizedContainers = new Set([
  'multipart/mixed',
  'multipart/related',
  'multipart/alternative',
  'multipart/signed',
  'multipart/report',
]);

// Children that can carry the body or its inline images. Only the first part of a signed or
// report container is message content; later parts are its signature or report data.
const firstPartOnly = new Set(['multipart/signed', 'multipart/report']);

const contentChildren = (part: GmailPart) => {
  const type = mimeType(part);
  if (!recognizedContainers.has(type)) {
    return [];
  }
  const children = part.parts ?? [];
  return firstPartOnly.has(type) ? children.slice(0, 1) : children;
};

// Readable leaves in document order, each with the multipart scopes enclosing it.
const readableLeaves = (
  part: GmailPart,
  ancestors: readonly GmailPart[] = [],
): ReadonlyArray<
  Readonly<{ part: GmailPart; ancestors: readonly GmailPart[] }>
> => {
  if (outsideBody(part)) {
    return [];
  }
  if (!mimeType(part).startsWith('multipart/')) {
    return [{ part, ancestors }];
  }
  return contentChildren(part).flatMap((child) =>
    readableLeaves(child, [...ancestors, part]),
  );
};

// The message's readable alternatives: HTML and plain text outside attachments and attached
// messages, with the scopes around the HTML part for inline image resolution.
export function bodyParts(payload: GmailPart): Readonly<{
  html?: GmailPart;
  text?: GmailPart;
  path: readonly GmailPart[];
}> {
  const leaves = readableLeaves(payload);
  const html = leaves.find(({ part }) => mimeType(part) === 'text/html');
  const text = leaves.find(({ part }) => mimeType(part) === 'text/plain');
  return {
    ...(html === undefined ? {} : { html: html.part }),
    ...(text === undefined ? {} : { text: text.part }),
    path: html?.ancestors ?? [],
  };
}

// A Content-ID without its surrounding comments, folding whitespace and angle brackets. Whitespace
// inside the ID is malformed, so it never matches a reference.
const contentIdOf = (part: GmailPart) => {
  const ids = headerValues(part, 'content-id').map((value) => {
    const id = withoutComments(value, ' ').trim().replaceAll(/^<|>$/gu, '');
    return /\s/u.test(id) ? '' : id;
  });
  return ids.every((id) => id === ids[0]) ? (ids[0] ?? '') : '';
};

// Image parts eligible under one MIME scope, skipping attachments and attached messages. An
// inline image leaf may carry a filename.
// Content the reader discarded: every child of an alternative container off the selected path,
// whatever its type, and any other related or alternative subtree.
const isOtherAlternative = (
  part: GmailPart,
  enclosingType: string,
  path: readonly GmailPart[],
) =>
  !path.includes(part) &&
  (enclosingType === 'multipart/alternative' ||
    ['multipart/related', 'multipart/alternative'].includes(mimeType(part)));

const isNamedImageAttachment = (part: GmailPart, enclosingType: string) =>
  (part.filename ?? '') !== '' &&
  enclosingType !== 'multipart/related' &&
  !declaredInline(part);

const collectImage = (part: GmailPart, found: Map<string, GmailPart>) => {
  const contentId = contentIdOf(part);
  if (contentId !== '' && !found.has(contentId)) {
    found.set(contentId, part);
  }
};

const imagesUnder = (
  scope: GmailPart,
  path: readonly GmailPart[],
  found: Map<string, GmailPart>,
) => {
  const visit = (part: GmailPart, enclosingType: string) => {
    if (
      isContainerOutsideBody(part) ||
      isOtherAlternative(part, enclosingType, path)
    ) {
      return;
    }
    const type = mimeType(part);
    const children = part.parts ?? [];
    if (type.startsWith('image/') && children.length === 0) {
      if (isNamedImageAttachment(part, enclosingType)) {
        return;
      }
      collectImage(part, found);
    }
    for (const child of contentChildren(part)) {
      visit(child, type);
    }
  };
  visit(scope, '');
};

// Inline image parts by Content-ID: the HTML part's nearest enclosing scope first, then each
// outer scope, so the closest related part wins.
export function inlineImageParts(
  path: readonly GmailPart[],
): ReadonlyMap<string, GmailPart> {
  const found = new Map<string, GmailPart>();
  for (const scope of Arr.reverse(path)) {
    imagesUnder(scope, path, found);
  }
  return found;
}

// ponytail: Gmail's own per-message limit; larger attachments are not offered on this device.
export const attachmentLimit = 25 * 1024 * 1024;

// Count a Unicode code point without depending on a host TextEncoder polyfill.
const filenameBytes = (character: string) => {
  const point = character.codePointAt(0) ?? 0;
  if (point <= 127) {
    return 1;
  }
  if (point <= 2047) {
    return 2;
  }
  if (point <= 65_535) {
    return 3;
  }
  return 4;
};

// A name that is safe to show and to use as a file name: no path separators, control or
// direction-overriding characters, no leading dot, and a bounded length that keeps the extension.
export const safeFilename = (name: string) => {
  const cleaned = name
    .normalize('NFC')
    .replaceAll(/[\p{Cc}\p{Cf}\u2028\u2029]/gu, '')
    .replaceAll(/[/\\:]/gu, '_')
    .replaceAll(/\s+/gu, ' ')
    .replace(/^[\s.]+/u, '')
    .replace(/[\s.]+$/u, '');
  const characters = [...cleaned];
  if (
    characters.length <= 120 &&
    characters.reduce(
      (bytes, character) => bytes + filenameBytes(character),
      0,
    ) <= 255
  ) {
    return cleaned === '' ? 'attachment' : cleaned;
  }
  const extension = /\.[^.\s]{1,16}$/u.exec(cleaned)?.[0] ?? '';
  const ending = [...extension];
  let bytes = ending.reduce(
    (size, character) => size + filenameBytes(character),
    0,
  );
  const prefix: string[] = [];
  for (const character of characters.slice(
    0,
    characters.length - ending.length,
  )) {
    if (
      prefix.length + ending.length === 120 ||
      bytes + filenameBytes(character) > 255
    ) {
      break;
    }
    prefix.push(character);
    bytes += filenameBytes(character);
  }
  return prefix.join('') + extension;
};

// Leaf parts with their child-index locators, never descending into attached messages.
const attachmentLeaves = (
  part: GmailPart,
  locator: readonly number[],
): ReadonlyArray<Readonly<{ part: GmailPart; locator: readonly number[] }>> => {
  if (mimeType(part) === 'message/rfc822') {
    return [];
  }
  const children = part.parts ?? [];
  return children.length === 0
    ? [{ part, locator }]
    : children.flatMap((child, index) =>
        attachmentLeaves(child, [...locator, index]),
      );
};

const namedOrAttached = (part: GmailPart) =>
  (part.filename ?? '') !== '' || isAttachment(part);

// Received attachments in MIME order, located by child indexes from the payload: named or
// attachment-disposition leaves outside attached messages, except the readable body and the
// inline images its HTML can resolve.
export function receivedAttachments(payload: GmailPart) {
  const { html, text, path } = bodyParts(payload);
  const body = new Set<GmailPart>([
    ...(html === undefined ? [] : [html]),
    ...(text === undefined ? [] : [text]),
    ...inlineImageParts(path).values(),
  ]);
  return attachmentLeaves(payload, [0]).flatMap(({ part, locator }) =>
    body.has(part) || part.body === undefined || !namedOrAttached(part)
      ? []
      : [
          {
            locator: locator.join('.'),
            name: safeFilename(part.filename ?? ''),
            mimeType: mimeType(part) || 'application/octet-stream',
            size: part.body.size,
            part,
          },
        ],
  );
}

const mimeToken = "[!#$%&'*+.^_`|~0-9A-Za-z-]+";

// A header's parameters by lower-cased name, read structurally after its leading token: comments
// are removed and quoted values are consumed whole, so a name inside another parameter's value or
// a longer name that ends in it never matches. The first occurrence of a name wins.
const headerParameters = (value: string) => {
  const bare = withoutComments(value.replaceAll(/\r\n(?=[ \t])/gu, ''));
  const parameters = new Map<string, string>();
  const leading = new RegExp(
    `^[ \\t]*${mimeToken}(?:/${mimeToken})?(?=[ \\t]*(?:;|$))`,
    'u',
  ).exec(bare);
  const next = new RegExp(
    `[ \\t]*;[ \\t]*(${mimeToken})[ \\t]*=[ \\t]*(${mimeToken}|"(?:[^"\\\\\\r\\n]|\\\\[^\\r\\n])*")[ \\t]*(?=;|$)`,
    'uy',
  );
  let consumed = leading?.[0].length ?? bare.length;
  next.lastIndex = consumed;
  for (let match = next.exec(bare); match !== null; match = next.exec(bare)) {
    consumed = next.lastIndex;
    const name = (match[1] ?? '').toLowerCase();
    const raw = match[2] ?? '';
    if (!parameters.has(name)) {
      parameters.set(
        name,
        raw.startsWith('"')
          ? raw.slice(1, -1).replaceAll(/\\(?<escaped>.)/gu, '$<escaped>')
          : raw,
      );
    }
  }
  return {
    parameters,
    wellFormed: leading !== null && /^[ \t]*$/u.test(bare.slice(consumed)),
  };
};

const wellFormedHeaders = (part: GmailPart) =>
  ['content-type', 'content-disposition'].every((name) =>
    headerValues(part, name).every(
      (value) => headerParameters(value).wellFormed,
    ),
  );

// Prefetch reads only messages Gmail reports as one plain-text or HTML part with wholly well-
// formed MIME headers; any malformed header keeps the body on demand.
export const singleReadablePart = (payload: GmailPart) =>
  (mimeType(payload) === 'text/plain' || mimeType(payload) === 'text/html') &&
  (payload.parts ?? []).length === 0 &&
  wellFormedHeaders(payload) &&
  !outsideBody(payload);

// Windows-1252 differs from ISO-8859-1 only in 0x80–0x9F; browsers treat both labels alike.
const windows1252 = '€\u0081‚ƒ„…†‡ˆ‰Š‹Œ\u008DŽ\u008F\u0090‘’“”•–—˜™š›œ\u009DžŸ';
const westernLabels = new Set([
  'iso-8859-1',
  'latin1',
  'l1',
  'windows-1252',
  'cp1252',
  'us-ascii',
  'ascii',
]);

// Base64url data whose decoded length matches Gmail's declared size.
export const partBytes = (data: string, size: number | undefined) => {
  const bytes = Base64Url.decode(data);
  return Result.isFailure(bytes) ||
    size === undefined ||
    bytes.success.length !== size
    ? undefined
    : bytes.success;
};

// Gmail returns part bytes in the part's own charset. A label the host cannot decode falls back
// to UTF-8, with replacement characters for invalid sequences.
const decodeText = (
  data: string,
  charset: string,
  size: number | undefined,
) => {
  const bytes = partBytes(data, size);
  if (bytes === undefined) {
    return undefined;
  }
  // Western labels decode here, never through a host decoder that may only know UTF-8.
  if (westernLabels.has(charset)) {
    return Array.from(bytes, (byte) =>
      byte >= 128 && byte < 160
        ? windows1252.charAt(byte - 128)
        : String.fromCodePoint(byte),
    ).join('');
  }
  try {
    return new TextDecoder(charset).decode(bytes);
  } catch {
    return new TextDecoder().decode(bytes);
  }
};

class InvalidBodyEncoding extends Schema.TaggedError<InvalidBodyEncoding>()(
  'InvalidBodyEncoding',
  {},
) {}

export const partText = Effect.fnUntraced(function* (
  part: GmailPart,
  data: string,
  size: number | undefined = part.body?.size,
) {
  const charset =
    headerParameters(header(part, 'content-type'))
      .parameters.get('charset')
      ?.toLowerCase() ?? 'utf8';
  const text = decodeText(data, charset, size);
  if (text === undefined) {
    return yield* new InvalidBodyEncoding();
  }
  return text;
});

// Standard base64 for an app-generated `data:` source.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Decoded bytes are only read.
export const standardBase64 = (bytes: Uint8Array) =>
  Base64Url.encode(bytes).replaceAll('-', '+').replaceAll('_', '/') +
  '='.repeat((3 - (bytes.length % 3)) % 3);

// A part's provider-declared size; an undeclared size never fits the bounds.
const declared = (part: GmailPart) =>
  part.body?.size ?? Number.POSITIVE_INFINITY;

// Admission of one explicit open's inline images within the per-message bounds. A transient
// download failure leaves the resolution incomplete, so it is not recorded and a later open retries.
export function imageTally() {
  const admitted: InlineImage[] = [];
  const refused: string[] = [];
  let bytes = 0;
  let pixels = 0;
  let complete = true;
  return {
    // Reserves the part's declared bytes when it may be requested: every download counts
    // toward the aggregate bound, whether or not its image is admitted.
    request: (part: GmailPart, attempt: number) => {
      const allowed =
        attempt < inlineImageLimits.attempts &&
        admitted.length < inlineImageLimits.admitted &&
        declared(part) <= inlineImageLimits.bytesPerImage &&
        bytes + declared(part) <= inlineImageLimits.aggregateBytes;
      if (allowed) {
        bytes += declared(part);
      }
      return allowed;
    },
    refuse: (contentId: string) => {
      refused.push(contentId);
    },
    receive: (contentId: string, part: GmailPart, data: string | undefined) => {
      if (data === undefined) {
        complete = false;
        return;
      }
      const raw = partBytes(data, declared(part));
      const facts = raw === undefined ? undefined : inspectImage(raw);
      if (
        raw === undefined ||
        facts === undefined ||
        pixels + facts.width * facts.height > inlineImageLimits.aggregatePixels
      ) {
        refused.push(contentId);
        return;
      }
      pixels += facts.width * facts.height;
      admitted.push({ contentId, ...facts, data: standardBase64(raw) });
    },
    result: () => ({ images: { admitted, refused }, complete }),
  };
}

// What the reader shows: an isolated rich document when the HTML is renderable, with readable
// text as the plain-text presentation and the fallback for every rich failure.
export interface MessagePresentation {
  readonly rich?: Readonly<{ document: string; links: readonly BodyLink[] }>;
  readonly readable: ReadableBody;
}

// Decode the patched WebKit view's native measurement at the shared boundary.
const decodeContentSize = Schema.decodeUnknownOption(
  Schema.Struct({
    contentSize: Schema.Struct({
      height: Schema.Finite.check(Schema.isGreaterThan(0)),
    }),
  }),
);

export const decodeMessageContentHeight = (
  nativeEvent: unknown,
): number | undefined =>
  decodeContentSize(nativeEvent).pipe(
    Option.map(({ contentSize }) => Math.ceil(contentSize.height)),
    Option.getOrUndefined,
  );

export function presentation(
  document: BodyDocument,
  images: readonly InlineImage[] = document.images?.admitted ?? [],
): MessagePresentation {
  const text =
    document.text === undefined ? undefined : readableText(document.text);
  if (document.html !== undefined) {
    try {
      const sanitized = sanitizeHtml(
        document.html,
        new Map(images.map((image) => [image.contentId, image])),
      );
      if (sanitized.renderable) {
        return {
          rich: { document: sanitized.document, links: sanitized.links },
          // Keep the blocked-image notice even when the sender supplied a plain alternative.
          readable: {
            ...(text ?? sanitized.readable),
            hidesImages: sanitized.readable.hidesImages,
          },
        };
      }
    } catch {
      // Preparation failure is terminal plain text; untrusted HTML never reaches WebKit.
    }
  }
  return {
    readable: text ?? { paragraphs: [], hidesImages: false },
  };
}

// The visible Content-ID references of a body's HTML, for MIME resolution on an explicit open.
export const contentIdsOf = (document: BodyDocument): readonly string[] => {
  try {
    return document.html === undefined
      ? []
      : sanitizeHtml(document.html).contentIds;
  } catch {
    // Failed preparation cannot authorize image requests.
    return [];
  }
};

// Newest received first, then ascending Stable Provider Message Identity.
interface Candidate {
  readonly id: string;
  readonly received: number;
}
const newestThenId = Order.combine(
  Order.flip(
    Order.mapInput(Order.Number, (candidate: Candidate) => candidate.received),
  ),
  Order.mapInput(Order.String, (candidate: Candidate) => candidate.id),
);

const recentDays = 30;
const recentLimit = 500;

// The recent working set at one reference instant: messages received from 30 days before it
// through it, newest first, then by ascending message ID, at most 500.
export function recentWorkingSet(
  messages: ReadonlyArray<Readonly<{ id: string; receivedAt: string }>>,
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Effect's immutable DateTime.
  now: DateTime.Utc,
): readonly string[] {
  const from = DateTime.subtract(now, { days: recentDays });
  const recent = messages.flatMap((message) =>
    DateTime.make(message.receivedAt).pipe(
      Option.filter(
        (received) =>
          !DateTime.isLessThan(received, from) &&
          !DateTime.isGreaterThan(received, now),
      ),
      Option.match({
        onNone: () => [],
        onSome: (received) => [
          { id: message.id, received: DateTime.toEpochMillis(received) },
        ],
      }),
    ),
  );
  return Arr.sort(recent, newestThenId)
    .slice(0, recentLimit)
    .map(({ id }) => id);
}
