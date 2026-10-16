import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { RemoteImage } from './html-sanitizer.ts';
import type { MailboxScope } from './mailbox-document.ts';
import type { MessagePresentation } from './message-presentation.ts';

import { rejectionCode, runLogged } from './diagnostics.ts';
import {
  decodedSize,
  inlineImageLimits,
  inspectImage,
} from './inline-images.ts';
import { malformed, rejected } from './mailbox-read.ts';

export interface NativeRemoteContentCache {
  // The Authorized Remote Content Cache, bound to the mailbox, message and exact source. Opening
  // resolves `{ data }`, standard base64 or null when absent; it never contacts a server.
  readonly openRemoteContent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    resource: RemoteResource,
  ) => Promise<unknown>;
  // Marks a cached resource as shown, so least-recently-used eviction keeps it longer; opening
  // alone does not.
  readonly touchRemoteContent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    resource: RemoteResource,
  ) => Promise<unknown>;
  // Fetches one authorized HTTPS image through the isolated native path and resolves `{ data }`.
  // Rejects with 'refused' when its destination or response is not allowed.
  readonly fetchRemoteContent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    url: string,
    request: Readonly<{ session: string; request: string }>,
  ) => Promise<unknown>;
  readonly cancelRemoteContent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    session: string,
    finished: boolean,
  ) => Promise<unknown>;
  // Stores validated bytes, evicting least recently shown entries outside the displayed
  // `[connection, id, url]` resources; resolves `{ admitted }`, false when they cannot fit.
  readonly commitRemoteContent: (
    mailbox: Readonly<{ address: string; generation: string }>,
    resource: RemoteResource,
    admission: Readonly<{
      data: string;
      protected: ReadonlyArray<readonly [string, string, string]>;
    }>,
  ) => Promise<unknown>;
}

// One message's remote image source: the cache's scope below the mailbox.
export type RemoteResource = Readonly<{ id: string; url: string }>;

// A remote image a connection holds within the device-wide display budget.
export type RetainedRemote = Readonly<{
  resource: readonly [string, string, string];
  image: RemoteImage;
}>;

// One remote image source of an opened message.
type RemoteImageState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'loaded'; readonly image: RemoteImage }
  // Not in the cache, and the presentation has not authorized fetching it.
  | { readonly kind: 'absent' }
  // A full display budget or a transient native failure; a later request may retry it.
  | { readonly kind: 'deferred' }
  | { readonly kind: 'failed' };

type RemoteImageResult =
  | RemoteImageState
  | { readonly kind: 'restored'; readonly image: RemoteImage };

type PresentedRemote = NonNullable<MessagePresentation['rich']>['remote'];

const RemoteData = Schema.Struct({ data: Schema.NullOr(Schema.String) });

const remoteImageLoaded = (result: RemoteImageResult) =>
  result.kind === 'loaded' || result.kind === 'restored';
let nextRemoteSession = 0;

// The rich presentations an Inbox's readers show of a message: each window's reader by its
// symbol, and the legacy readers by the message ID while any is open.
export const shownRemote = ({
  viewReaders,
  viewBodies,
  bodies,
  legacyReaders,
}: Readonly<{
  viewReaders: ReadonlyMap<symbol, string>;
  viewBodies: ReadonlyMap<
    symbol,
    Readonly<{ kind: string; presentation?: MessagePresentation }>
  >;
  bodies: ReadonlyMap<
    string,
    Readonly<{ kind: string; presentation?: MessagePresentation }>
  >;
  legacyReaders: ReadonlyMap<string, number>;
}>) => {
  const presented = (id: string, reader: string | symbol) => {
    if (typeof reader === 'symbol' && viewReaders.get(reader) !== id) {
      return undefined;
    }
    const body =
      typeof reader === 'symbol' ? viewBodies.get(reader) : bodies.get(id);
    return body?.kind === 'ready' ? body.presentation?.rich?.remote : undefined;
  };
  return {
    presented,
    displayed: (id: string) =>
      [
        ...[...viewReaders]
          .filter(([, message]) => message === id)
          .map(([reader]) => reader),
        ...((legacyReaders.get(id) ?? 0) > 0 ? [id] : []),
      ].flatMap((reader) => presented(id, reader) ?? []),
  };
};

// Remote bytes become content only as one complete supported image within the per-image bounds.
const admittedRemote = (data: string): RemoteImage | undefined => {
  const bytes = Result.getOrUndefined(Base64.decode(data));
  const facts = bytes === undefined ? undefined : inspectImage(bytes);
  return facts === undefined ? undefined : { ...facts, data };
};

// A Gmail Inbox's Remote Message Content: per-message loads with their lanes and retention, and
// the Authorized Remote Content Cache. The Inbox keeps the readers, their presentations and the
// inline image budget; remote images it presents are admitted within what that budget leaves.
export function createRemoteContentLoader(
  native: NativeRemoteContentCache,
  {
    connection,
    shared,
    scope,
    presented,
    displayed,
    inlineImages,
    present,
    notify,
    failed = () => Effect.void,
  }: Readonly<{
    connection: string;
    // Twelve requests account-wide, and the images every connection holds for display.
    shared: Readonly<{
      remote: Semaphore.Semaphore;
      remoteImages: Map<symbol, ReadonlyMap<string, RetainedRemote>>;
    }>;
    // The mailbox an open reader reads this message from, while the message is readable.
    scope: (id: string) => MailboxScope | undefined;
    // A reader's rich presentation of the message, as its sources and their placeholders.
    presented: (
      id: string,
      reader: string | symbol,
    ) => PresentedRemote | undefined;
    // Every rich presentation displaying the message.
    displayed: (id: string) => readonly PresentedRemote[];
    // The message's admitted MIME Inline Images.
    inlineImages: (id: string) => number;
    // Presents the message's readers again; true when a presentation changed.
    present: (id: string) => boolean;
    notify: () => void;
    // Lets the Inbox retire its readable state when native storage or ownership is lost.
    failed?: (mailbox: MailboxScope, cause: unknown) => Effect.Effect<void>;
  }>,
) {
  interface RemoteLoad {
    readonly images: Map<string, RemoteImageState>;
    readonly session: string;
    readonly scope: MailboxScope;
    readonly abort: AbortController;
    readonly network: boolean;
    readonly readers: Map<
      string | symbol,
      Readonly<{ urls: ReadonlySet<string>; network: boolean }>
    >;
    networkUrls: ReadonlySet<string>;
    near: ReadonlySet<string>;
    attempts: number;
    sequence: number;
    admitted: number;
  }
  const owner = Symbol('remote-images');
  // Advances when the open Inbox closes, so a load for the previous owner is dropped.
  let generation = 0;
  const loads = new Map<string, RemoteLoad>();
  // Retired work keeps its lane until it settles, so reopening cannot double the six permits.
  const lanes = new Map<
    string,
    { permits: Semaphore.Semaphore; pending: number }
  >();
  const retained = new Map<string, RetainedRemote>();

  const release = (
    id: string,
    disposition: 'close' | 'policy' | 'mode' = 'close',
  ) => {
    const remote = loads.get(id);
    if (remote === undefined) {
      return;
    }
    loads.delete(id);
    remote.abort.abort();
    if (disposition !== 'mode') {
      for (const key of retained.keys()) {
        if (key.startsWith(`${id}\n`)) {
          retained.delete(key);
        }
      }
    }
    void runLogged(
      Effect.tryPromise({
        try: () =>
          native.cancelRemoteContent(
            remote.scope,
            remote.session,
            disposition === 'close',
          ),
        catch: (cause) => rejected(cause, 'failed'),
      }).pipe(
        Effect.catchTag('SyncFailure', ({ diagnostic }) =>
          Effect.logError('Remote content cancellation failed:', diagnostic),
        ),
      ),
    );
    if (disposition === 'policy') {
      loads.set(id, {
        ...remote,
        images: new Map(),
        abort: new AbortController(),
        network: false,
        near: new Set(),
        networkUrls: new Set(),
        readers: new Map(),
        admitted: 0,
      });
    }
    if (lanes.get(id)?.pending === 0) {
      lanes.delete(id);
    }
  };

  // Remote Message Content currently shown, which the cache keeps while admitting more.
  const displayedRemote = () =>
    [...shared.remoteImages.values()].flatMap((images) =>
      [...images.values()].map(({ resource }) => resource),
    );

  const refreshInterest = (id: string) => {
    const previous = loads.get(id);
    if (previous === undefined) {
      return undefined;
    }
    const interest = [...previous.readers.values()];
    const near = new Set(interest.flatMap(({ urls }) => [...urls]));
    const networkUrls = new Set(
      interest
        .filter(({ network }) => network)
        .flatMap(({ urls }) => [...urls]),
    );
    const network = networkUrls.size > 0;
    const withdrawn = [...previous.networkUrls].some(
      (url) => !networkUrls.has(url),
    );
    if (previous.network === network && !withdrawn) {
      previous.near = near;
      previous.networkUrls = networkUrls;
      return previous;
    }
    release(id, 'mode');
    const remote = {
      ...previous,
      images: new Map<string, RemoteImageState>([
        ...[...previous.images].filter(([, image]) => image.kind === 'failed'),
        ...[...retained.values()]
          .filter(({ resource }) => resource[1] === id)
          .map(({ resource, image }): [string, RemoteImageState] => [
            resource[2],
            { kind: 'loaded', image },
          ]),
      ]),
      abort: new AbortController(),
      near,
      networkUrls,
      network,
    };
    loads.set(id, remote);
    present(id);
    notify();
    return remote;
  };

  const shownRemoteImages = (id: string) =>
    new Set(
      displayed(id).flatMap(({ images, pending }) =>
        images.filter((url) => !pending.includes(url)),
      ),
    );

  const releaseUnshown = (id: string) => {
    const remote = loads.get(id);
    if (remote === undefined) {
      return;
    }
    const shown = shownRemoteImages(id);
    const wanted = new Set(
      [...remote.readers.values()].flatMap(({ urls }) => [...urls]),
    );
    for (const [key, { resource }] of retained) {
      // A healthy reader's unfinished batch still owns its tentative retention.
      const settling =
        remote.images.get(resource[2])?.kind === 'loading' &&
        wanted.has(resource[2]);
      if (resource[1] === id && !shown.has(resource[2]) && !settling) {
        retained.delete(key);
        remote.admitted -= 1;
        remote.images.set(resource[2], { kind: 'deferred' });
      }
    }
  };

  const settle = (
    id: string,
    results: ReadonlyArray<readonly [string, RemoteImageResult]>,
    current: () => boolean,
  ) => {
    const remote = loads.get(id);
    if (remote === undefined || !current()) {
      return [];
    }
    for (const [url, result] of results) {
      if (!remote.near.has(url) && result.kind !== 'loaded') {
        remote.images.delete(url);
      } else {
        remote.images.set(
          url,
          result.kind === 'restored'
            ? { kind: 'loaded', image: result.image }
            : result,
        );
      }
    }
    if (!results.some(([, result]) => remoteImageLoaded(result))) {
      return [];
    }
    const changed = present(id);
    const shown = shownRemoteImages(id);
    // Retention is not display admission: repeated occurrences and inline images also cost pixels.
    const admitted = results.filter(([url, result]) => {
      if (!remoteImageLoaded(result)) {
        return false;
      }
      if (shown.has(url)) {
        return true;
      }
      retained.delete(`${id}\n${url}`);
      remote.admitted -= 1;
      remote.images.set(url, { kind: 'deferred' });
      return false;
    });
    // Subscribers can replace viewport interest synchronously; publish only reconciled retention.
    if (changed) {
      notify();
    }
    return admitted;
  };

  const reserve = (resource: RemoteResource, image: RemoteImage) => {
    const { id, url } = resource;
    const remote = loads.get(id);
    if (
      remote === undefined ||
      !remote.near.has(url) ||
      remote.admitted + inlineImages(id) >= inlineImageLimits.admitted
    ) {
      return false;
    }
    let bytes = decodedSize(image.data);
    let pixels = image.width * image.height;
    for (const images of shared.remoteImages.values()) {
      for (const held of images.values()) {
        bytes += decodedSize(held.image.data);
        pixels += held.image.width * held.image.height;
      }
    }
    if (
      bytes > inlineImageLimits.aggregateBytes ||
      pixels > inlineImageLimits.aggregatePixels
    ) {
      return false;
    }
    remote.admitted += 1;
    retained.set(`${id}\n${url}`, {
      resource: [connection, id, url],
      image,
    });
    shared.remoteImages.set(owner, retained);
    return true;
  };

  // One remote image from the Authorized Remote Content Cache, or, when the presentation
  // authorized it, through the isolated native fetch, validated and then cached.
  const restoreRemoteContent = Effect.fnUntraced(function* (
    mailbox: MailboxScope,
    resource: RemoteResource,
  ) {
    const cached = yield* Effect.tryPromise({
      try: () => native.openRemoteContent(mailbox, resource),
      catch: (cause) => rejected(cause, 'failed'),
    }).pipe(
      Effect.flatMap((reply) =>
        Schema.decodeUnknownEffect(RemoteData)(reply).pipe(
          Effect.mapError((error) => malformed(error, 'failed')),
        ),
      ),
    );
    return cached.data === null ? undefined : admittedRemote(cached.data);
  });

  // Shown cached content becomes most recently used; a failure only ages it sooner.
  const markRemoteShown = (mailbox: MailboxScope, resource: RemoteResource) =>
    Effect.tryPromise({
      try: () => native.touchRemoteContent(mailbox, resource),
      catch: (cause) => rejected(cause, 'failed'),
    }).pipe(
      Effect.tapError(({ cause }) => failed(mailbox, cause)),
      Effect.catchTag('SyncFailure', ({ cause, diagnostic }) =>
        rejectionCode(cause) === 'locked'
          ? Effect.void
          : Effect.logError('Remote content use was not recorded:', diagnostic),
      ),
    );

  const remoteImage = Effect.fnUntraced(
    function* (
      mailbox: MailboxScope,
      resource: RemoteResource,
      authorized: Readonly<{
        network: () => boolean;
        request: Readonly<{ session: string; request: string }>;
        current: () => boolean;
        retain: (image: RemoteImage) => boolean;
      }>,
    ) {
      const { network, request, current, retain } = authorized;
      if (!current()) {
        return { kind: 'failed' } as const;
      }
      const { url } = resource;
      const restored = yield* restoreRemoteContent(mailbox, resource);
      if (!current()) {
        return { kind: 'failed' } as const;
      }
      if (restored !== undefined) {
        if (!retain(restored)) {
          return { kind: 'deferred' } as const;
        }
        return { kind: 'restored', image: restored } as const;
      }
      if (!network()) {
        return { kind: 'absent' } as const;
      }
      const fetched = yield* Effect.tryPromise({
        try: () => native.fetchRemoteContent(mailbox, url, request),
        catch: (cause) => rejected(cause, 'failed'),
      }).pipe(
        Effect.flatMap((reply) =>
          Schema.decodeUnknownEffect(Schema.Struct({ data: Schema.String }))(
            reply,
          ).pipe(Effect.mapError((error) => malformed(error, 'failed'))),
        ),
      );
      const image = admittedRemote(fetched.data);
      if (!current() || image === undefined) {
        return { kind: 'failed' } as const;
      }
      // An image the display budget cannot hold yet is neither shown nor cached, so the cache's
      // recency follows display; a later request may fetch it again within the attempt limit.
      if (!retain(image)) {
        return { kind: 'deferred' } as const;
      }
      return { kind: 'loaded', image } as const;
    },
    (effect, mailbox) =>
      effect.pipe(Effect.tapError(({ cause }) => failed(mailbox, cause))),
    // A refusal is final; transient failures can retry if the Inbox keeps access open.
    Effect.catchTag('SyncFailure', ({ cause, diagnostic }) => {
      const code = rejectionCode(cause);
      if (code === 'refused') {
        return Effect.succeed<RemoteImageState>({ kind: 'failed' });
      }
      return Effect.logError('Remote content failed:', diagnostic).pipe(
        Effect.as<RemoteImageState>(
          code === 'unavailable' || code === 'locked'
            ? { kind: 'deferred' }
            : { kind: 'failed' },
        ),
      );
    }),
  );

  // Cache only bytes admitted by the reader; a full cache still leaves the image displayed.
  const cacheRemoteShown = Effect.fnUntraced(function* (
    mailbox: MailboxScope,
    resource: RemoteResource,
    image: RemoteImage,
  ) {
    yield* Effect.tryPromise({
      try: () =>
        native.commitRemoteContent(mailbox, resource, {
          data: image.data,
          protected: displayedRemote(),
        }),
      catch: (cause) => rejected(cause, 'failed'),
    }).pipe(
      Effect.flatMap((reply) =>
        Schema.decodeUnknownEffect(Schema.Struct({ admitted: Schema.Boolean }))(
          reply,
        ).pipe(Effect.mapError((error) => malformed(error, 'failed'))),
      ),
      Effect.tapError(({ cause }) => failed(mailbox, cause)),
      Effect.catchTag('SyncFailure', ({ diagnostic }) =>
        Effect.logError('Remote content could not be cached:', diagnostic),
      ),
    );
  });

  const prepare = (
    id: string,
    urls: readonly string[],
    authorization: boolean | Readonly<{ network: boolean; reader: symbol }>,
  ) => {
    const mailbox = scope(id);
    if (mailbox === undefined) {
      return undefined;
    }
    const interest =
      typeof authorization === 'boolean'
        ? { network: authorization, reader: id }
        : authorization;
    const sources = presented(id, interest.reader)?.images;
    if (sources === undefined) {
      return undefined;
    }
    const initial = loads.get(id) ?? {
      images: new Map<string, RemoteImageState>(),
      session: `remote-${(nextRemoteSession += 1)}`,
      scope: mailbox,
      abort: new AbortController(),
      network: false,
      near: new Set<string>(),
      networkUrls: new Set<string>(),
      readers: new Map<
        string | symbol,
        Readonly<{ urls: ReadonlySet<string>; network: boolean }>
      >(),
      attempts: 0,
      sequence: 0,
      admitted: 0,
    };
    loads.set(id, initial);
    const allowed = new Set(sources);
    initial.readers.set(interest.reader, {
      urls: new Set(urls.filter((url) => allowed.has(url))),
      network: interest.network,
    });
    return refreshInterest(id) ?? initial;
  };

  return {
    // Six requests run per message and twelve account-wide; the readers are presented again once
    // the requested sources settle.
    load: (
      id: string,
      urls: readonly string[],
      authorization: boolean | Readonly<{ network: boolean; reader: symbol }>,
    ) => {
      const remote = prepare(id, urls, authorization);
      if (remote === undefined) {
        return Promise.resolve();
      }
      const { scope: mailbox } = remote;
      const reading = generation;
      const current = (url: string) =>
        generation === reading &&
        !remote.abort.signal.aborted &&
        loads.get(id) === remote &&
        remote.near.has(url) &&
        scope(id) !== undefined;
      return runLogged(
        Effect.gen(function* () {
          // Each source is attempted at most once per request, so a deferred one cannot spin.
          const probed = new Set<string>();
          while (loads.get(id) === remote) {
            const eligible = [...remote.near].filter((url) => {
              const known = remote.images.get(url);
              return (
                !probed.has(url) &&
                (known === undefined ||
                  known.kind === 'deferred' ||
                  (remote.networkUrls.has(url) && known.kind === 'absent'))
              );
            });
            const network = eligible
              .filter((url) => remote.networkUrls.has(url))
              .slice(0, inlineImageLimits.attempts - remote.attempts);
            const cached = eligible
              .filter((url) => !remote.networkUrls.has(url))
              .slice(0, inlineImageLimits.attempts);
            const wanted = [...network, ...cached];
            if (wanted.length === 0) {
              return;
            }
            for (const url of wanted) {
              probed.add(url);
              remote.images.set(url, { kind: 'loading' });
            }
            const lane = lanes.get(id) ?? {
              permits: Semaphore.makeUnsafe(6),
              pending: 0,
            };
            lanes.set(id, lane);
            lane.pending += wanted.length;
            const attemptStart = remote.sequence;
            remote.sequence += wanted.length;
            remote.attempts += network.length;
            yield* Effect.forEach(
              wanted,
              (url) =>
                lane.permits
                  .withPermit(
                    shared.remote.withPermit(
                      remoteImage(
                        mailbox,
                        { id, url },
                        {
                          network: () => remote.networkUrls.has(url),
                          request: {
                            session: remote.session,
                            request: `${remote.session}:${attemptStart + wanted.indexOf(url)}`,
                          },
                          current: () => current(url),
                          retain: (image) => reserve({ id, url }, image),
                        },
                      ),
                    ),
                  )
                  .pipe(
                    Effect.map((result) => [url, result] as const),
                    Effect.ensuring(
                      Effect.sync(() => {
                        lane.pending -= 1;
                        if (lane.pending === 0 && !loads.has(id)) {
                          lanes.delete(id);
                        }
                      }),
                    ),
                  ),
              { concurrency: 'unbounded' },
            ).pipe(
              Effect.flatMap((results) =>
                Effect.sync(() =>
                  settle(id, results, () => loads.get(id) === remote),
                ),
              ),
              Effect.flatMap((admittedResults) =>
                Effect.forEach(
                  admittedResults,
                  ([url, result]) => {
                    if (!current(url)) {
                      return Effect.void;
                    }
                    const resource = { id, url };
                    if (result.kind === 'restored') {
                      return markRemoteShown(mailbox, resource);
                    }
                    return result.kind === 'loaded'
                      ? cacheRemoteShown(mailbox, resource, result.image)
                      : Effect.void;
                  },
                  { discard: true },
                ),
              ),
            );
            // Misses publish no presentation; keep scanning only the current nearby sources.
            if (cached.length !== inlineImageLimits.attempts) {
              return;
            }
          }
        }),
      );
    },
    // A message's loaded Remote Message Content admitted within what the shared presentation
    // budget leaves after its inline images; resolves the images and the bytes and pixels reserved.
    admit: (
      id: string,
      occurrences: readonly string[],
      budget: Readonly<{ bytes: number; pixels: number; count: number }>,
    ) => {
      const loaded = loads.get(id)?.images;
      const admitted = new Map<string, RemoteImage>();
      let bytes = 0;
      let pixels = 0;
      for (const url of new Set(occurrences)) {
        const known = loaded?.get(url);
        if (known?.kind === 'loaded') {
          const copies =
            budget.count *
            occurrences.filter((source) => source === url).length;
          const size = decodedSize(known.image.data) * copies;
          const area = known.image.width * known.image.height * copies;
          if (
            budget.bytes + bytes + size <= inlineImageLimits.aggregateBytes &&
            budget.pixels + pixels + area <= inlineImageLimits.aggregatePixels
          ) {
            bytes += size;
            pixels += area;
            admitted.set(url, known.image);
          }
        }
      }
      return { admitted, bytes, pixels };
    },
    // Whether the message has Remote Message Content in memory.
    has: (id: string) => loads.has(id),
    // A closed reader's interest ends; the readers that remain decide what still loads.
    withdraw: (id: string, reader: string | symbol) => {
      loads.get(id)?.readers.delete(reader);
      refreshInterest(id);
    },
    // A failed rich view's interest ends, and so does retention none of the readers shows.
    discard: (id: string, reader: string | symbol) => {
      loads.get(id)?.readers.delete(reader);
      releaseUnshown(id);
      refreshInterest(id);
    },
    // Cached bytes stay until eviction or Clear Remote Content.
    forget: (id: string) => {
      if (loads.has(id)) {
        release(id, 'policy');
        present(id);
        notify();
      }
    },
    // The message's body left memory.
    release: (id: string) => {
      release(id);
    },
    // The open Inbox closed: every load ends and the connection holds no display budget.
    releaseAll: () => {
      generation += 1;
      for (const id of loads.keys()) {
        release(id);
      }
      shared.remoteImages.delete(owner);
    },
  };
}
