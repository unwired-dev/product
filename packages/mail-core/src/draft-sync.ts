import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { Draft, Synced, SyncedAsset } from './draft-model.ts';
import type { DraftStorageFailure } from './draft-native.ts';

import { rejectionCode, runLogged } from './diagnostics.ts';
import {
  DraftSchema,
  ImportedSchema,
  SyncedSchema,
  sameContent,
  syncedAssets,
} from './draft-model.ts';
import { malformed, native, ownerMismatch } from './draft-native.ts';

// The Product Account's Drafts in End-to-End Encrypted Product Sync, one record per Draft. Native
// code seals every record and asset chunk to the account, its opaque identifier and key epoch, so
// Convex holds only ciphertext; JavaScript never handles key material. Every call rejects with
// 'unavailable' while this device holds no keys or Product Sign-In session.
export interface NativeDraftSync {
  // Resolves `{ owner, records: [{ id, version, updatedAt, draft }], unreadable }`, `draft` being
  // the Draft's JSON. Only records that open on this device and are sealed under their own Draft's
  // identifier are listed. `unreadable` names the Drafts of `known` whose record exists but does
  // not, so it is never mistaken for a deletion; such a record is never shown or replaced.
  readonly pullDrafts: (
    owner: string,
    known: readonly string[],
  ) => Promise<unknown>;
  // Writes Draft `id`'s record, or a sealed tombstone when `draft` is null, only while it is still at
  // `expectedUpdatedAt` (absent: while there is none). Resolves `{ owner, committed, updatedAt? }`.
  readonly pushDraft: (
    owner: string,
    record: Readonly<{
      id: string;
      version: number;
      draft: string | null;
      expectedUpdatedAt?: number;
    }>,
  ) => Promise<unknown>;
  // Seals a complete asset's verified bytes in chunks under its identifier and digest. Resolves
  // `{ owner }`; repeating it uploads nothing new.
  readonly uploadDraftAsset: (
    owner: string,
    asset: SyncedAsset,
  ) => Promise<unknown>;
  // Opens all cloud chunks, checks them against size and digest, and stores the verified bytes.
  // Resolves `{ owner, size, digest }`;
  // rejects with 'attachment-missing' when a chunk is missing or does not open.
  readonly downloadDraftAsset: (
    owner: string,
    asset: SyncedAsset,
  ) => Promise<unknown>;
}
const PulledSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  records: Schema.Array(
    Schema.Struct({
      id: Schema.NonEmptyString,
      version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
      updatedAt: Schema.Finite,
      // Decoded one by one, so a record from a newer format stays read-only rather than failing all.
      draft: Schema.NullOr(Schema.String),
    }),
  ),
  unreadable: Schema.Array(Schema.NonEmptyString),
});
const PushedSchema = Schema.Union([
  Schema.Struct({
    owner: Schema.NonEmptyString,
    committed: Schema.Literal(false),
  }),
  Schema.Struct({
    owner: Schema.NonEmptyString,
    committed: Schema.Literal(true),
    updatedAt: Schema.Finite,
  }),
]);
const OwnedSchema = Schema.Struct({ owner: Schema.NonEmptyString });

const encodeDraft = (draft: Draft) =>
  Schema.encodeEffect(Schema.fromJsonString(DraftSchema))(draft).pipe(
    Effect.mapError(malformed),
  );
const decodeDraft = Schema.decodeUnknownOption(
  Schema.fromJsonString(DraftSchema),
);

export const notifyRemoval = (
  error: Readonly<Pick<DraftStorageFailure, 'cause'>>,
  removed: (() => void) | undefined,
) => {
  if (rejectionCode(error.cause) === 'mailbox-revoked') {
    removed?.();
  }
};

// Without keys or a session, Product Sync is expected to be unavailable; the next pass retries.
const quietly = (
  error: Readonly<Pick<DraftStorageFailure, 'cause' | 'diagnostic'>>,
) =>
  rejectionCode(error.cause) === 'unavailable'
    ? Effect.void
    : Effect.logError('Draft synchronization failed:', error.diagnostic);

export const equivalentSynced = Schema.toEquivalence(
  Schema.Array(SyncedSchema),
);
const sameRecord = Schema.toEquivalence(Schema.NullOr(DraftSchema));
const acceptsVersion = (draft: Draft | null, version: number, prior: Synced) =>
  version > prior.version ||
  (version === prior.version && sameRecord(prior.draft, draft));
const readRecord = (
  {
    id,
    version,
    updatedAt,
    draft: json,
  }: (typeof PulledSchema.Type)['records'][number],
  prior: Synced | undefined,
): Synced | undefined => {
  const draft = json === null ? null : Option.getOrUndefined(decodeDraft(json));
  // A version authenticates one immutable record; equal versions cannot change content.
  if (
    draft === undefined ||
    (draft !== null && draft.id !== id) ||
    (prior !== undefined && !acceptsVersion(draft, version, prior))
  ) {
    return undefined;
  }
  return { id, draft, version, updatedAt };
};
export const syncedDrafts = (entries: readonly Synced[]) =>
  entries.flatMap(({ draft }) => (draft === null ? [] : [draft]));

export type Pulled = typeof PulledSchema.Type;

export const readRecords = (
  synced: readonly Synced[],
  { records, unreadable }: Pulled,
) => {
  const read = new Map(synced.map((entry) => [entry.id, entry]));
  const skipped = new Set(unreadable);
  const present = new Set(records.map(({ id }) => id));
  // Deletion requires an authenticated tombstone; absence cannot erase a version floor.
  for (const { id } of synced) {
    if (!present.has(id)) {
      skipped.add(id);
    }
  }
  const latest: Synced[] = [];
  for (const record of records) {
    const entry = readRecord(record, read.get(record.id));
    if (entry === undefined) {
      skipped.add(record.id);
    } else {
      latest.push(entry);
    }
  }
  // A record this pass cannot read keeps this device's base for it.
  latest.push(...synced.filter(({ id }) => skipped.has(id)));
  return { latest, skipped };
};

const uploadAsset = Effect.fnUntraced(function* (
  account: string,
  remote: NativeDraftSync,
  asset: SyncedAsset,
) {
  const upload = yield* Effect.result(
    native(() => remote.uploadDraftAsset(account, asset), OwnedSchema),
  );
  if (Result.isSuccess(upload)) {
    if (upload.success.owner !== account) {
      return yield* ownerMismatch();
    }
    return;
  }
  if (rejectionCode(upload.failure.cause) === 'mailbox-revoked') {
    return yield* upload.failure;
  }
  // An offline copy may never have downloaded these retained cloud bytes.
  const fetched = yield* native(
    () => remote.downloadDraftAsset(account, asset),
    ImportedSchema,
  );
  if (
    fetched.owner !== account ||
    fetched.digest !== asset.digest ||
    fetched.size !== asset.size
  ) {
    return yield* ownerMismatch();
  }
});

const pushing = Effect.fnUntraced(function* (
  remote: NativeDraftSync,
  {
    current,
    account,
    drafts,
    synced,
    skipped,
  }: SyncContext & Readonly<{ skipped: ReadonlySet<string> }>,
  local: LocalDraftSync,
) {
  let conflicted = false;
  const read = new Map(synced.map((entry) => [entry.id, entry]));
  const uploaded = syncedAssets(syncedDrafts(synced));
  const upload = Effect.fnUntraced(function* (draft: Draft) {
    for (const [key, asset] of syncedAssets([draft])) {
      if (!uploaded.has(key)) {
        yield* uploadAsset(account, remote, asset);
        uploaded.set(key, asset);
      }
    }
  });
  const push = Effect.fnUntraced(function* (
    id: string,
    draft: Draft | null,
    prior: Synced | undefined,
  ) {
    const version = (prior?.version ?? 0) + 1;
    const json = draft === null ? null : yield* encodeDraft(draft);
    const pushed = yield* native(
      () =>
        remote.pushDraft(account, {
          id,
          version,
          draft: json,
          ...(prior === undefined
            ? {}
            : { expectedUpdatedAt: prior.updatedAt }),
        }),
      PushedSchema,
    );
    if (pushed.owner !== account) {
      return yield* ownerMismatch();
    }
    if (!pushed.committed) {
      conflicted = true;
      return true;
    }
    return yield* local.record(current, account, {
      id,
      draft,
      version,
      updatedAt: pushed.updatedAt,
    });
  });
  const changed = drafts
    .filter((draft) => {
      const prior = read.get(draft.id);
      return (
        !skipped.has(draft.id) &&
        (prior === undefined || !sameContent(prior.draft ?? undefined, draft))
      );
    })
    .map((draft) => ({ id: draft.id, draft, prior: read.get(draft.id) }));
  const kept = new Set(drafts.map(({ id }) => id));
  const removed = [...read.values()]
    .filter(
      ({ id, draft }) => draft !== null && !kept.has(id) && !skipped.has(id),
    )
    .map((prior) => ({ id: prior.id, draft: null, prior }));
  for (const { id, draft, prior } of [...changed, ...removed]) {
    if (!local.live(current)) {
      return conflicted;
    }
    if (draft !== null) {
      yield* upload(draft);
    }
    if (!local.live(current)) {
      return conflicted;
    }
    if (!(yield* push(id, draft, prior))) {
      return false;
    }
  }
  return conflicted;
});

export type DraftSyncOptions = Readonly<{
  native: NativeDraftSync;
  delay?: number;
  removed?: () => void;
}>;

type SyncContext = Readonly<{
  current: number;
  account: string;
  drafts: readonly Draft[];
  synced: readonly Synced[];
}>;

type LocalDraftSync = Readonly<{
  context: () => SyncContext | undefined;
  live: (current: number) => boolean;
  adopt: (
    current: number,
    account: string,
    pulled: Pulled,
  ) => Effect.Effect<ReadonlySet<string> | undefined>;
  record: (
    current: number,
    account: string,
    written: Synced,
  ) => Effect.Effect<boolean>;
}>;

// Owns network passes and edit debounce; the store owns atomic local merges and durable bases.
export function createDraftSynchronizer(
  options: DraftSyncOptions | undefined,
  local: LocalDraftSync,
) {
  const synchronizing = Effect.fnUntraced(function* (remote: NativeDraftSync) {
    const context = local.context();
    if (context === undefined) {
      return;
    }
    const { current, account } = context;
    const known = context.synced.map(({ id }) => id);
    const pulled = yield* native(
      () => remote.pullDrafts(account, known),
      PulledSchema,
    );
    if (pulled.owner !== account) {
      return yield* ownerMismatch();
    }
    const skipped = yield* local.adopt(current, account, pulled);
    const latest = local.context();
    if (
      skipped === undefined ||
      latest === undefined ||
      latest.current !== current
    ) {
      return;
    }
    return yield* pushing(remote, { ...latest, skipped }, local);
  });

  // Passes run one at a time; a request during one runs another after it.
  let passing: Promise<void> | undefined = undefined;
  let requested = false;
  const synchronize = async () => {
    const remote = options?.native;
    if (remote === undefined) {
      return;
    }
    requested = true;
    passing ??= (async () => {
      // A defect or interruption rejects the pass; the next request must still start a new one.
      try {
        while (requested) {
          requested = false;
          for (let attempt = 0; attempt < 3; attempt += 1) {
            const conflicted = await runLogged(
              synchronizing(remote).pipe(
                Effect.catchTag('DraftStorageFailure', (error) => {
                  notifyRemoval(error, options?.removed);
                  return quietly(error);
                }),
              ),
            );
            if (!conflicted) {
              break;
            }
          }
        }
      } finally {
        passing = undefined;
      }
    })();
    await passing;
  };
  let timer: ReturnType<typeof setTimeout> | undefined = undefined;
  // Edits synchronize once they pause, rather than once per keystroke.
  const schedule = () => {
    if (options !== undefined) {
      clearTimeout(timer);
      timer = setTimeout(() => {
        timer = undefined;
        void synchronize();
      }, options.delay ?? 2000);
    }
  };
  return { synchronize, schedule };
}
