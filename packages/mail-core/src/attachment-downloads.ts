import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

import type { SyncFailure } from './mailbox-read.ts';
import type { BodyDocument } from './message-body.ts';

import { rejectionCode, runLogged } from './diagnostics.ts';
import { malformed, rejected } from './mailbox-read.ts';
import { attachmentLimit, partBytes } from './message-body.ts';

// A received attachment's availability on this device. 'oversized' attachments are listed but
// never downloaded; 'damaged' means the provider's bytes were incomplete or did not decode.
export type AttachmentState =
  | {
      readonly kind: 'available' | 'oversized' | 'downloading' | 'downloaded';
    }
  | {
      readonly kind: 'unavailable';
      readonly reason:
        | 'download'
        | 'authentication'
        | 'missing'
        | 'locked'
        | 'failed'
        | 'damaged';
    };

export type ReceivedAttachment = Readonly<{
  locator: string;
  name: string;
  mimeType: string;
  size: number;
  state: AttachmentState;
}>;

export type AttachmentFailure = Extract<
  AttachmentState,
  { kind: 'unavailable' }
>['reason'];

type Descriptor = NonNullable<BodyDocument['attachments']>[number];
type Scope = Readonly<{ address: string; generation: string }>;

// The native module's Downloaded Attachment operations for one Mailbox Connection.
export interface NativeAttachments {
  // Writes a verified Downloaded Attachment's base64url bytes into the connection's private
  // temporary storage, which native code clears with the connection. Resolves `{ file }`, an opaque
  // name; the data never leaves this device.
  readonly saveAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    attachment: Readonly<{ name: string; data: string; size: number }>,
  ) => Promise<unknown>;
  // Deletes a saved attachment; deleting is allowed after the mailbox's generation changed.
  readonly discardAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    file: string,
  ) => Promise<unknown>;
  // Shows the system Attachment Preview, or the system share sheet, for a saved attachment.
  readonly presentAttachment: (
    mailbox: Readonly<{ address: string; generation: string }>,
    file: string,
    action: 'open' | 'share',
  ) => Promise<unknown>;
}

const attachmentStates = {
  available: { kind: 'available' },
  oversized: { kind: 'oversized' },
  downloading: { kind: 'downloading' },
  downloaded: { kind: 'downloaded' },
} as const satisfies Record<string, AttachmentState>;

const decodeSavedAttachment = Schema.decodeUnknownEffect(
  Schema.Struct({
    file: Schema.String.check(Schema.isPattern(/^[\dA-Fa-f-]{36}$/u)),
  }),
);

// The provider sent bytes that do not decode to the attachment's declared size.
export class AttachmentDamaged extends Schema.TaggedError<AttachmentDamaged>()(
  'AttachmentDamaged',
  {},
) {}

export const sameAttachment = (left: Descriptor, right: Descriptor) =>
  left.locator === right.locator &&
  left.name === right.name &&
  left.mimeType === right.mimeType &&
  left.size === right.size;

const attachmentKey = (id: string, locator: string) => `${id}\n${locator}`;

// Each opened message's attachment downloads by `id\nlocator`, for one mailbox's Inbox. A saved
// file belongs to the mailbox scope it was saved in; the Inbox discards it when its message
// leaves memory. `fetch` reads the listed attachment's base64url bytes again from the provider,
// and `failed` says what the row shows for a failed fetch or save: a reason, or 'stale' to offer
// Download again.
export function createAttachmentDownloads<S extends Scope, E>(
  native: NativeAttachments,
  {
    scope,
    owner,
    readable,
    listed,
    fetch,
    failed,
    notify,
  }: Readonly<{
    // The open mailbox generation, and a value that changes when the open Inbox closes.
    scope: () => S | undefined;
    owner: () => number;
    readable: (id: string) => boolean;
    listed: (id: string) => readonly Descriptor[] | undefined;
    fetch: (
      scope: S,
      id: string,
      attachment: Descriptor,
    ) => Effect.Effect<
      Readonly<{ data: string; size?: number | undefined }>,
      E
    >;
    failed: (
      // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- Failures are tagged values.
      failure: Exclude<E, AttachmentDamaged> | SyncFailure,
      reading: number,
      id: string,
    ) => Effect.Effect<AttachmentFailure | 'stale'>;
    notify: () => void;
  }>,
) {
  type Download = Readonly<{
    state: AttachmentState;
    saved?: Readonly<{ scope: S; file: string }>;
    abort?: AbortController;
  }>;
  const downloads = new Map<string, Download>();
  const views = new Map<string, readonly ReceivedAttachment[]>();
  const discardSaved = (
    saved: Readonly<{ scope: S; file: string }> | undefined,
  ) => {
    if (saved !== undefined) {
      void runLogged(
        Effect.tryPromise({
          try: () => native.discardAttachment(saved.scope, saved.file),
          catch: (cause) => rejected(cause, 'failed'),
        }).pipe(
          Effect.catchTag('SyncFailure', ({ diagnostic }) =>
            Effect.logError('Attachment was not discarded:', diagnostic),
          ),
        ),
      );
    }
  };
  const setDownload = (
    id: string,
    locator: string,
    // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The controller is only kept to abort.
    next: Download | undefined,
  ) => {
    const key = attachmentKey(id, locator);
    if (next === undefined) {
      downloads.delete(key);
    } else {
      downloads.set(key, next);
    }
    views.delete(id);
    notify();
  };
  const drop = (key: string) => {
    const download = downloads.get(key);
    downloads.delete(key);
    download?.abort?.abort();
    discardSaved(download?.saved);
  };
  const descriptor = (id: string, locator: string) =>
    listed(id)?.find((attachment) => attachment.locator === locator);

  // Downloads one listed attachment into private temporary storage. Cancelling, closing the
  // message or a change of mailbox drops the result and deletes any file saved for it.
  const download = (id: string, locator: string) => {
    const opened = scope();
    const attachment = descriptor(id, locator);
    const current = downloads.get(attachmentKey(id, locator))?.state.kind;
    if (
      opened === undefined ||
      !readable(id) ||
      attachment === undefined ||
      attachment.size > attachmentLimit ||
      current === 'downloading' ||
      current === 'downloaded'
    ) {
      return Promise.resolve();
    }
    const reading = owner();
    const abort = new AbortController();
    setDownload(id, locator, { state: attachmentStates.downloading, abort });
    const live = () =>
      owner() === reading &&
      downloads.get(attachmentKey(id, locator))?.abort === abort;
    // Saving and recording the file cannot be interrupted, so a cancelled download still deletes it.
    const save = (data: string, size: number) =>
      Effect.tryPromise({
        try: () =>
          native.saveAttachment(opened, { name: attachment.name, data, size }),
        catch: (cause) => rejected(cause, 'failed'),
      }).pipe(
        Effect.flatMap(decodeSavedAttachment),
        Effect.mapError((failure) =>
          Schema.isSchemaError(failure)
            ? malformed(failure, 'failed')
            : failure,
        ),
        Effect.flatMap(({ file }) =>
          Effect.sync(() => {
            const saved = { scope: opened, file };
            if (live()) {
              setDownload(id, locator, {
                state: attachmentStates.downloaded,
                saved,
              });
            } else {
              discardSaved(saved);
            }
          }),
        ),
        Effect.uninterruptible,
      );
    const program = fetch(opened, id, attachment).pipe(
      // Only base64url data decoding to exactly its size is kept.
      Effect.flatMap(
        ({
          data,
          size,
        }): Effect.Effect<void, SyncFailure | AttachmentDamaged> =>
          size === undefined ||
          size > attachmentLimit ||
          partBytes(data, size) === undefined
            ? Effect.fail(new AttachmentDamaged())
            : save(data, size),
      ),
      Effect.asVoid,
      Effect.catchIf(
        (failure): failure is AttachmentDamaged =>
          failure instanceof AttachmentDamaged,
        () =>
          Effect.logError('Attachment download failed:', 'damaged').pipe(
            Effect.as('damaged' as const),
          ),
      ),
      // oxlint-disable-next-line promise/prefer-await-to-then, promise/prefer-await-to-callbacks -- Effect's typed error channel.
      Effect.catch((error) => failed(error, reading, id)),
      Effect.flatMap((failure) =>
        Effect.sync(() => {
          if (failure === undefined || !live()) {
            return;
          }
          setDownload(
            id,
            locator,
            failure === 'stale'
              ? undefined
              : { state: { kind: 'unavailable', reason: failure } },
          );
        }),
      ),
    );
    // Cancelling ends the download as soon as its uninterruptible save, if any, completes.
    const cancelled = Effect.callback<unknown>((resume) => {
      if (abort.signal.aborted) {
        resume(Effect.void);
      }
      abort.signal.addEventListener('abort', () => {
        resume(Effect.void);
      });
    });
    return runLogged(Effect.raceFirst(program, cancelled).pipe(Effect.asVoid));
  };

  return {
    // An opened message's received attachments with their availability, once its body is ready;
    // listing them never downloads their bytes.
    messageAttachments: (id: string) => {
      const attachments = listed(id);
      if (attachments === undefined) {
        return undefined;
      }
      const cached = views.get(id);
      if (cached !== undefined) {
        return cached;
      }
      const view = attachments.map((attachment): ReceivedAttachment => ({
        ...attachment,
        state:
          downloads.get(attachmentKey(id, attachment.locator))?.state ??
          (attachment.size > attachmentLimit
            ? attachmentStates.oversized
            : attachmentStates.available),
      }));
      views.set(id, view);
      return view;
    },
    downloadAttachment: download,
    cancelAttachment: (id: string, locator: string) => {
      const { state, abort } = downloads.get(attachmentKey(id, locator)) ?? {};
      if (state?.kind === 'downloading') {
        setDownload(id, locator, undefined);
        abort?.abort();
      }
    },
    // Opens the system Attachment Preview or share sheet for a Downloaded Attachment. A file the
    // device no longer has, or one saved before the mailbox changed, is downloaded again.
    presentAttachment: (
      id: string,
      locator: string,
      action: 'open' | 'share',
    ) => {
      const saved = downloads.get(attachmentKey(id, locator));
      const opened = scope();
      const file = saved?.saved;
      if (file === undefined || opened === undefined || !readable(id)) {
        return Promise.resolve();
      }
      const stale = () =>
        Effect.sync(() => {
          if (downloads.get(attachmentKey(id, locator)) === saved) {
            setDownload(id, locator, undefined);
            discardSaved(file);
          }
        });
      if (
        file.scope.address !== opened.address ||
        file.scope.generation !== opened.generation
      ) {
        return runLogged(stale());
      }
      return runLogged(
        Effect.tryPromise({
          try: () => native.presentAttachment(opened, file.file, action),
          catch: (cause) => rejected(cause, 'failed'),
        }).pipe(
          Effect.asVoid,
          // Only a file the device no longer has, or one from another mailbox generation, is
          // downloaded again; a presenter that could not show the file keeps it.
          Effect.catchTag('SyncFailure', ({ kind, cause, diagnostic }) =>
            Effect.logError(
              'Attachment could not be presented:',
              diagnostic,
            ).pipe(
              Effect.andThen(
                kind === 'invalidated' ||
                  rejectionCode(cause) === 'attachment-missing'
                  ? stale()
                  : Effect.void,
              ),
            ),
          ),
        ),
      );
    },
    // A Downloaded Attachment saved for the open mailbox generation, which a Draft can copy; native
    // code reads it only while that generation is current.
    attachmentFile: (id: string, locator: string) => {
      const saved = downloads.get(attachmentKey(id, locator))?.saved;
      const attachment = descriptor(id, locator);
      const opened = scope();
      if (
        saved === undefined ||
        attachment === undefined ||
        opened === undefined ||
        !readable(id) ||
        saved.scope.address !== opened.address ||
        saved.scope.generation !== opened.generation
      ) {
        return undefined;
      }
      return {
        name: attachment.name,
        type: attachment.mimeType,
        address: opened.address,
        generation: opened.generation,
        file: saved.file,
      };
    },
    // Drops the downloads of one message, or of every message, deleting their saved files. With
    // a reason, their rows say why they cannot be downloaded again.
    discard: (id?: string, reason?: AttachmentFailure) => {
      for (const key of downloads.keys()) {
        if (id === undefined || key.startsWith(`${id}\n`)) {
          drop(key);
        }
      }
      if (id === undefined) {
        views.clear();
        return;
      }
      if (reason !== undefined) {
        const state = { kind: 'unavailable', reason } as const;
        for (const { locator } of listed(id) ?? []) {
          downloads.set(attachmentKey(id, locator), { state });
        }
      }
      views.delete(id);
    },
    // A refreshed body keeps a download only while its attachment's descriptor is unchanged; a
    // changed or removed attachment at the same position loses its saved file.
    discardChanged: (id: string, next: BodyDocument) => {
      const previous = listed(id) ?? [];
      const kept = new Set(
        (next.attachments ?? [])
          .filter((attachment) =>
            previous.some((before) => sameAttachment(before, attachment)),
          )
          .map(({ locator }) => locator),
      );
      for (const key of downloads.keys()) {
        if (key.startsWith(`${id}\n`) && !kept.has(key.slice(id.length + 1))) {
          drop(key);
        }
      }
      views.delete(id);
    },
  };
}
