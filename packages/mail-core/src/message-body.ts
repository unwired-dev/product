import * as Arr from 'effect/Array';
import * as DateTime from 'effect/DateTime';
import * as Effect from 'effect/Effect';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
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

export const decodeFullMessage = Schema.decodeUnknownEffect(
  Schema.fromJsonString(
    Schema.Struct({ id: Schema.String, payload: GmailPartSchema }),
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
const withoutComments = (value: string) => {
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
      output += value.slice(from, delimiter.index);
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
  return recognizedContainers.has(mimeType(part))
    ? (part.parts ?? []).flatMap((child) =>
        readableLeaves(child, [...ancestors, part]),
      )
    : [];
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

// A Content-ID as MIME declares it, without comments, folding whitespace or angle brackets.
const contentIdOf = (part: GmailPart) => {
  const ids = headerValues(part, 'content-id').map((value) =>
    withoutComments(value).replaceAll(/\s+/gu, '').replaceAll(/^<|>$/gu, ''),
  );
  return ids.every((id) => id === ids[0]) ? (ids[0] ?? '') : '';
};

// Image parts eligible under one MIME scope, skipping attachments and attached messages. An
// inline image leaf may carry a filename.
const isOtherAlternative = (part: GmailPart, path: readonly GmailPart[]) =>
  ['multipart/related', 'multipart/alternative'].includes(mimeType(part)) &&
  !path.includes(part);

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
    if (isContainerOutsideBody(part) || isOtherAlternative(part, path)) {
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
    if (recognizedContainers.has(type)) {
      for (const child of children) {
        visit(child, type);
      }
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

// Prefetch reads only messages Gmail reports as one plain-text or HTML part.
export const singleReadablePart = (payload: GmailPart) =>
  (mimeType(payload) === 'text/plain' || mimeType(payload) === 'text/html') &&
  (payload.parts ?? []).length === 0 &&
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
    /charset\s*=\s*"?(?<label>[\w.:-]+)/iu
      .exec(header(part, 'content-type'))?.[1]
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
    requestable: (part: GmailPart, attempt: number) =>
      attempt < inlineImageLimits.attempts &&
      admitted.length < inlineImageLimits.admitted &&
      declared(part) <= inlineImageLimits.bytesPerImage &&
      bytes + declared(part) <= inlineImageLimits.aggregateBytes,
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
      bytes += raw.length;
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
