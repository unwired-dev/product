import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type { BodyLink, InlineImage, RemoteImage } from './html-sanitizer.ts';
import type { BodyDocument } from './message-body.ts';
import type { ReadableBody } from './readable-text.ts';

import { sanitizeHtml } from './html-sanitizer.ts';
import { readableText, withoutQuotedText } from './readable-text.ts';

// What the reader shows: an isolated rich document when the HTML is renderable, with readable
// text as the plain-text presentation and the fallback for every rich failure.
export interface MessagePresentation {
  readonly rich?: Readonly<{
    document: string;
    // Remote images change only their marked nodes, never this navigation's source document.
    initialDocument: string;
    links: readonly BodyLink[];
    // Remote Message Content: every visible HTTPS image occurrence, indexed as the placeholders'
    // `data-remote` markers, and the distinct sources still shown as placeholders.
    remote: Readonly<{
      images: readonly string[];
      pending: readonly string[];
      updates: string;
    }>;
  }>;
  readonly readable: ReadableBody;
  // The same body without trailing quoted history; absent for inline replies and quote-only mail.
  readonly withoutQuotedHistory?: MessagePresentation;
}

// Decode the patched WebKit view's native measurement at the shared boundary.
const decodeContentSize = Schema.decodeUnknownOption(
  Schema.Struct({
    contentSize: Schema.Struct({
      width: Schema.Finite.check(Schema.isGreaterThan(0)),
      height: Schema.Finite.check(Schema.isGreaterThan(0)),
    }),
  }),
);

export const decodeMessageContentSize = (
  nativeEvent: unknown,
): Readonly<{ width: number; height: number }> | undefined =>
  decodeContentSize(nativeEvent).pipe(
    Option.map(({ contentSize }) => ({
      width: contentSize.width,
      height: Math.ceil(contentSize.height),
    })),
    Option.getOrUndefined,
  );

const decodeRemotePositions = Schema.decodeUnknownOption(
  Schema.Struct({
    remoteImages: Schema.Array(
      Schema.Struct({
        index: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
        top: Schema.Finite,
        bottom: Schema.Finite,
      }),
    ),
  }),
);

// The measured document offsets of blocked remote image placeholders, by `data-remote` index;
// none when the measurement carries no readable positions.
export const decodeRemoteImagePositions = (
  nativeEvent: unknown,
): ReadonlyArray<Readonly<{ index: number; top: number; bottom: number }>> =>
  decodeRemotePositions(nativeEvent).pipe(
    Option.map(({ remoteImages }) => remoteImages),
    Option.getOrElse(() => []),
  );

// App-owned sanitized nodes cross the native prop as data, never as executable script.
// oxlint-disable-next-line node/no-sync -- Pure serialization of prepared reader markup.
const encodeRemoteNodes = Schema.encodeSync(
  Schema.fromJsonString(Schema.Array(Schema.String)),
);

// Keep only the latest inline admission per body; remote updates reuse it without retaining
// every document variant produced by changing reader budgets. The body with and without its
// quoted history keep one each.
type InitialDocuments = WeakMap<
  BodyDocument,
  Readonly<{ images: readonly InlineImage[]; document: string }>
>;
const initialDocuments: Readonly<
  Record<'full' | 'collapsed', InitialDocuments>
> = { full: new WeakMap(), collapsed: new WeakMap() };
const initialDocument = (
  document: BodyDocument,
  images: readonly InlineImage[],
  omitQuoted: boolean,
) => {
  const prepared = initialDocuments[omitQuoted ? 'collapsed' : 'full'];
  const cached = prepared.get(document);
  if (
    cached !== undefined &&
    cached.images.length === images.length &&
    images.every((image, index) => image === cached.images[index])
  ) {
    return cached.document;
  }
  const sanitized = sanitizeHtml(
    document.html ?? '',
    new Map(images.map((image) => [image.contentId, image])),
    { omitQuoted },
  ).document;
  prepared.set(document, { images: [...images], document: sanitized });
  return sanitized;
};

interface PresentationOptions {
  readonly remote: ReadonlyMap<string, RemoteImage>;
  readonly omitQuoted: boolean;
}

// The sanitized rich view of a body's HTML; undefined when it has none or nothing renderable.
function richOf(
  document: BodyDocument,
  images: readonly InlineImage[],
  { remote, omitQuoted }: PresentationOptions,
) {
  if (document.html === undefined) {
    return undefined;
  }
  try {
    const sanitized = sanitizeHtml(
      document.html,
      new Map(images.map((image) => [image.contentId, image])),
      { remote, omitQuoted },
    );
    return sanitized.renderable
      ? {
          view: {
            document: sanitized.document,
            initialDocument:
              remote.size === 0
                ? sanitized.document
                : initialDocument(document, images, omitQuoted),
            links: sanitized.links,
            remote: {
              images: sanitized.remoteImages,
              updates: encodeRemoteNodes(sanitized.remoteNodes),
              pending: [...new Set(sanitized.remoteImages)].filter(
                (url) => !remote.has(url),
              ),
            },
          },
          readable: sanitized.readable,
          quoted: sanitized.quoted,
        }
      : undefined;
  } catch {
    // Preparation failure is terminal plain text; untrusted HTML never reaches WebKit.
    return undefined;
  }
}

export function presentation(
  document: BodyDocument,
  images: readonly InlineImage[] = document.images?.admitted ?? [],
  remote: ReadonlyMap<string, RemoteImage> = new Map(),
): MessagePresentation {
  const text =
    document.text === undefined ? undefined : readableText(document.text);
  const rich = richOf(document, images, {
    remote,
    omitQuoted: false,
  });
  const shown: MessagePresentation =
    rich === undefined
      ? { readable: text ?? { paragraphs: [], hidesImages: false } }
      : {
          rich: rich.view,
          // Keep the blocked-image notice even when the sender supplied a plain alternative.
          readable: {
            ...(text ?? rich.readable),
            hidesImages: rich.readable.hidesImages,
          },
        };
  const shortened =
    rich === undefined && document.text !== undefined
      ? withoutQuotedText(document.text)
      : undefined;
  if (rich === undefined ? shortened === undefined : !rich.quoted) {
    return shown;
  }
  const collapsed = richOf(document, images, {
    remote,
    omitQuoted: true,
  });
  // A quote-only HTML body must remain readable, just like a quote-only plain body.
  if (rich !== undefined && collapsed === undefined) {
    return shown;
  }
  return {
    ...shown,
    withoutQuotedHistory:
      collapsed === undefined
        ? { readable: readableText(shortened ?? document.text ?? '') }
        : { rich: collapsed.view, readable: collapsed.readable },
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
