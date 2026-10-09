import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import type {
  AssetSource,
  NativeDrafts,
  NativeDraftSync,
  PickSource,
} from '../drafts.ts';

import { assetLimit } from '../drafts.ts';

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error(`Draft storage: ${code}`), { code }));

// A stand-in for SHA-256: 64 hexadecimal digits that change with the bytes.
const digestOf = (bytes: string) =>
  [1, 2, 3, 4]
    .map((seed) =>
      [...bytes]
        .reduce(
          (hash, ch, index) =>
            (hash * 31 + (ch.codePointAt(0) ?? 0) + index * seed) %
            Number.MAX_SAFE_INTEGER,
          seed,
        )
        .toString(16)
        .padStart(16, '0')
        .slice(-16),
    )
    .join('');

// A Draft record's sealed content: the Draft's identifier, the record's write count and its JSON.
const RecordSchema = Schema.fromJsonString(
  Schema.Struct({
    id: Schema.String,
    version: Schema.Finite,
    draft: Schema.NullOr(Schema.String),
  }),
);
const openRecord = Schema.decodeUnknownOption(RecordSchema);

// Waits while a test holds this kind of work, until it releases it.
const waitWhile = async (holding: () => Array<() => void> | undefined) => {
  const queue = holding();
  if (queue !== undefined) {
    // oxlint-disable-next-line promise/avoid-new -- Holds the work until the test releases it.
    await new Promise<void>((resolve) => {
      queue.push(resolve);
    });
  }
};

const key = (account: string, identifier: string) =>
  `${account}\n${identifier}`;
const chunkId = (id: string, digest: string, index: number) =>
  `draft-asset.${id}:${digest}.${index}`;

const SealedSchema = Schema.fromJsonString(
  Schema.Struct({
    account: Schema.String,
    identifier: Schema.String,
    plaintext: Schema.String,
  }),
);
const openSealed = Schema.decodeUnknownOption(SealedSchema);

// Product Sync's records as Convex holds them, shared by the synthetic devices of a test. Sealing
// is simulated: a record opens only for the Product Account and identifier it was sealed under,
// as native code's AES-GCM binding requires, so a test can move, replay or damage ciphertext.
export function createSyntheticProductSync() {
  let clock = 0;
  const records = new Map<
    string,
    { account: string; sealed: string; updatedAt: number }
  >();
  // While false, every request rejects as without a session or a connection.
  let reachable = true;
  // Stores the next write but rejects its reply, as when the response is lost.
  let losingReply = false;
  const reach = () =>
    reachable
      ? undefined
      : Object.assign(new Error('Product Sync: unavailable'), {
          code: 'unavailable',
        });
  return {
    reach,
    seal: (account: string, identifier: string, plaintext: string) =>
      JSON.stringify({ account, identifier, plaintext }),
    open: (sealed: string, account: string, identifier: string) => {
      const opened = Option.getOrUndefined(openSealed(sealed));
      return opened?.account === account && opened.identifier === identifier
        ? opened.plaintext
        : undefined;
    },
    list: (account: string, prefix: string) =>
      [...records.entries()]
        .filter(
          ([name, record]) =>
            record.account === account && name.startsWith(key(account, prefix)),
        )
        .map(([name, record]) => ({
          identifier: name.slice(account.length + 1),
          ...record,
        })),
    get: (account: string, identifier: string) =>
      records.get(key(account, identifier)),
    // Compare-and-set: the stored record when another write won, as Convex replies.
    put: (
      account: string,
      identifier: string,
      {
        sealed,
        expected,
      }: Readonly<{
        sealed?: string | undefined;
        expected?: number | undefined;
      }>,
    ) => {
      const name = key(account, identifier);
      const existing = records.get(name);
      if (existing?.updatedAt !== expected) {
        return { committed: false, updatedAt: existing?.updatedAt };
      }
      clock += 1;
      if (sealed === undefined) {
        records.delete(name);
      } else {
        records.set(name, { account, sealed, updatedAt: clock });
      }
      if (losingReply) {
        losingReply = false;
        throw Object.assign(new Error('Product Sync: unavailable'), {
          code: 'unavailable',
        });
      }
      return { committed: true, updatedAt: clock };
    },
    remove: (account: string, identifier: string) => {
      records.delete(key(account, identifier));
    },
    // Identifiers of the records stored for `account`.
    identifiers: (account: string) =>
      [...records.keys()]
        .filter((name) => records.get(name)?.account === account)
        .map((name) => name.slice(account.length + 1)),
    // Replaces a stored record's ciphertext, keeping its revision.
    replace: (account: string, identifier: string, sealed: string) => {
      const existing = records.get(key(account, identifier));
      if (existing !== undefined) {
        existing.sealed = sealed;
      }
    },
    setReachable: (next: boolean) => {
      reachable = next;
    },
    loseNextReply: () => {
      losingReply = true;
    },
  };
}
export type SyntheticProductSync = ReturnType<
  typeof createSyntheticProductSync
>;

// Draft storage with native code's rules: one document bound to the Product Account that wrote
// it, which another account opens as empty, replaced only from the revision read. Asset bytes are
// bound to their account and identifier, stored before any Draft names them, and removed once a
// stored document no longer keeps them, unless their import has not been committed yet. It holds
// no encryption; the hosted native suite covers ciphertext and keys.
// With `server`, `sync` is this device's view of it: Draft records and asset chunks sealed for
// the signed-in account.
export function createSyntheticDrafts(
  account: () => string | undefined,
  {
    outgoingLimit = 100 * 1024 * 1024,
    server,
  }: Readonly<{
    outgoingLimit?: number;
    server?: Readonly<SyntheticProductSync>;
  }> = {},
) {
  let stored:
    | Readonly<{ owner: string; revision: number; document: string }>
    | undefined = undefined;
  // The rejection code for the next commit, as when the device locks or storage fails.
  let failing: string | undefined = undefined;
  let held: Array<() => void> | undefined = undefined;
  let importsHeld: Array<() => void> | undefined = undefined;
  let uploadsHeld: Array<() => void> | undefined = undefined;
  let failingImport: string | undefined = undefined;
  // Rejects the next import only after storing its bytes, as when the device locks meanwhile.
  let failingAfterWrite: string | undefined = undefined;
  // While true, saves and reads are refused as on a locked device.
  let locked = false;
  // Picked copies the store gave back, by URI.
  const discardedPicks: string[] = [];
  const assets = new Map<
    string,
    { owner: string; bytes: string; digest: string; damaged?: true }
  >();
  // Imported in this process and not yet kept by a stored document.
  const pending = new Set<string>();
  // Files the person can pick or drop, and Downloaded Attachments, by URI or file name.
  const files = new Map<string, string>();
  const picks: Array<
    Readonly<{
      source: PickSource;
      files: ReadonlyArray<
        | Readonly<{ uri: string; name: string; type: string }>
        | Readonly<{ name: string; type: string; oversized: 'true' }>
      >;
    }>
  > = [];
  const used = () =>
    (stored?.document.length ?? 0) +
    [...assets.values()].reduce((total, { bytes }) => total + bytes.length, 0);
  const bytesOf = (source: AssetSource) => {
    if (source.kind === 'data') {
      const [, data] =
        /^data:[^,]*;base64,(?<data>.*)$/u.exec(source.uri) ?? [];
      return data === undefined ? undefined : atob(data);
    }
    if (source.kind === 'oversized' || source.kind === 'unavailable') {
      return undefined;
    }
    return files.get(source.kind === 'received' ? source.file : source.uri);
  };
  // Once a document is stored, bytes it does not keep go, except uncommitted imports.
  const collect = (keep: readonly string[]) => {
    const kept = new Set(keep);
    for (const id of assets.keys()) {
      if (kept.has(id)) {
        pending.delete(id);
      } else if (!pending.has(id)) {
        assets.delete(id);
      }
    }
  };
  const native: NativeDrafts = {
    openDrafts: () => {
      const owner = account();
      if (owner === undefined) {
        return rejection('unavailable');
      }
      return Promise.resolve({
        owner,
        revision: stored?.revision ?? 0,
        document: stored?.owner === owner ? stored.document : null,
      });
    },
    commitDrafts: async (owner, expectedRevision, { document, keep }) => {
      await waitWhile(() => held);
      if (failing !== undefined) {
        const code = failing;
        failing = undefined;
        return rejection(code);
      }
      if (locked) {
        return rejection('locked');
      }
      if (owner !== account()) {
        return rejection('mailbox-invalidated');
      }
      if ((stored?.revision ?? 0) !== expectedRevision) {
        return rejection('conflict');
      }
      stored = { owner, revision: expectedRevision + 1, document };
      collect(keep);
      return { owner, revision: expectedRevision + 1 };
    },
    importDraftAsset: async (owner, id, source) => {
      await waitWhile(() => importsHeld);
      if (failingImport !== undefined) {
        const code = failingImport;
        failingImport = undefined;
        return rejection(code);
      }
      if (owner !== account()) {
        return rejection('mailbox-invalidated');
      }
      const bytes = bytesOf(source);
      if (bytes === undefined) {
        return rejection('unavailable');
      }
      if (bytes.length > assetLimit || used() + bytes.length > outgoingLimit) {
        return rejection('too-large');
      }
      const digest = digestOf(bytes);
      assets.set(id, { owner, bytes, digest });
      pending.add(id);
      if (failingAfterWrite !== undefined) {
        const code = failingAfterWrite;
        failingAfterWrite = undefined;
        return rejection(code);
      }
      return { owner, size: bytes.length, digest };
    },
    readDraftAsset: (owner, { id, digest, type, preview }) => {
      if (locked) {
        return rejection('locked');
      }
      const asset = assets.get(id);
      if (asset === undefined) {
        return rejection('attachment-missing');
      }
      if (
        asset.owner !== owner ||
        asset.damaged === true ||
        asset.digest !== digest
      ) {
        return rejection('unavailable');
      }
      return Promise.resolve(
        preview ? { uri: `data:${type};base64,${btoa(asset.bytes)}` } : {},
      );
    },
    discardDraftAsset: (_owner, id) => {
      assets.delete(id);
      pending.delete(id);
      return Promise.resolve({});
    },
    pickDraftFiles: (source) => {
      const index = picks.findIndex((pick) => pick.source === source);
      const [pick] = index === -1 ? [] : picks.splice(index, 1);
      return Promise.resolve(pick?.files ?? []);
    },
    discardPickedDraftFiles: (uris) => {
      discardedPicks.push(...uris);
      return Promise.resolve({});
    },
  };
  // Few characters per chunk, so every asset spans several, as large files do natively.
  const chunk = 4;
  const chunks = (size: number) => Math.max(1, Math.ceil(size / chunk));
  const signedIn = (owner: string) => {
    const refused = server?.reach();
    if (refused !== undefined) {
      return Promise.reject(refused);
    }
    return owner === account() ? undefined : rejection('mailbox-invalidated');
  };
  const sync: NativeDraftSync | undefined =
    server === undefined
      ? undefined
      : {
          pullDrafts: (owner, known) => {
            const opened = server
              .list(owner, 'draft.')
              .map(({ identifier, sealed, updatedAt }) => {
                const record = Option.getOrUndefined(
                  openRecord(server.open(sealed, owner, identifier) ?? ''),
                );
                return record === undefined ||
                  identifier !== `draft.${record.id}`
                  ? { identifier }
                  : { identifier, record: { ...record, updatedAt } };
              });
            return (
              signedIn(owner) ??
              Promise.resolve({
                owner,
                records: opened.flatMap(({ record }) =>
                  record === undefined ? [] : [record],
                ),
                unreadable: known.filter((id) =>
                  opened.some(
                    ({ identifier, record }) =>
                      identifier === `draft.${id}` && record === undefined,
                  ),
                ),
              })
            );
          },
          pushDraft: async (
            owner,
            { id, version, draft, expectedUpdatedAt },
          ) => {
            const identifier = `draft.${id}`;
            await signedIn(owner);
            return {
              owner,
              ...server.put(owner, identifier, {
                sealed: server.seal(
                  owner,
                  identifier,
                  JSON.stringify({ id, version, draft }),
                ),
                expected: expectedUpdatedAt,
              }),
            };
          },
          uploadDraftAsset: (owner, { id, digest, size }) => {
            const refused = signedIn(owner);
            if (refused !== undefined) {
              return refused;
            }
            const asset = assets.get(id);
            if (
              asset?.owner !== owner ||
              asset.damaged === true ||
              asset.digest !== digest
            ) {
              return rejection('unavailable');
            }
            for (let index = 0; index < chunks(size); index += 1) {
              const identifier = chunkId(id, digest, index);
              if (server.get(owner, identifier) === undefined) {
                server.put(owner, identifier, {
                  sealed: server.seal(
                    owner,
                    identifier,
                    asset.bytes.slice(index * chunk, (index + 1) * chunk),
                  ),
                });
              }
            }
            // Held until `releaseUploads`, so a test can change the Draft while its files upload.
            return waitWhile(() => uploadsHeld).then(() => ({ owner }));
          },
          downloadDraftAsset: (owner, { id, digest, size }) => {
            const refused = signedIn(owner);
            if (refused !== undefined) {
              return refused;
            }
            let bytes = '';
            for (let index = 0; index < chunks(size); index += 1) {
              const identifier = chunkId(id, digest, index);
              const record = server.get(owner, identifier);
              const opened =
                record === undefined
                  ? undefined
                  : server.open(record.sealed, owner, identifier);
              if (opened === undefined) {
                return rejection('attachment-missing');
              }
              bytes += opened;
            }
            if (bytes.length !== size || digestOf(bytes) !== digest) {
              return rejection('attachment-missing');
            }
            if (used() + bytes.length > outgoingLimit) {
              return rejection('too-large');
            }
            // Held with imports, so a test can change the Draft while the bytes arrive.
            return waitWhile(() => importsHeld).then(() => {
              assets.set(id, { owner, bytes, digest });
              return { owner, size, digest };
            });
          },
        };
  return {
    native,
    sync,
    stored: () => stored,
    // The identifiers of asset bytes on this device.
    assets: () => [...assets.keys()],
    // A file at `uri` (or a Downloaded Attachment named `uri`) with these bytes.
    addFile: (uri: string, bytes: string) => {
      files.set(uri, bytes);
    },
    // What the next picker of this kind returns.
    pickNext: (
      source: PickSource,
      chosen: ReadonlyArray<
        | Readonly<{ uri: string; name: string; type: string }>
        | Readonly<{ name: string; type: string; oversized: 'true' }>
      >,
    ) => {
      picks.push({ source, files: chosen });
    },
    // Changes stored bytes, as damaged ciphertext would read.
    damage: (id: string) => {
      const asset = assets.get(id);
      if (asset !== undefined) {
        asset.damaged = true;
      }
    },
    // Forgets imports in progress, as a relaunch does.
    relaunch: () => {
      pending.clear();
    },
    failNextCommit: (code: string) => {
      failing = code;
    },
    failNextImport: (code: string) => {
      failingImport = code;
    },
    // Locks or unlocks storage for every later save and read.
    setLocked: (next: boolean) => {
      locked = next;
    },
    failNextImportAfterWrite: (code: string) => {
      failingAfterWrite = code;
    },
    // Picked copies the store discarded rather than adding.
    discardedPicks: () => [...discardedPicks],
    // Holds commits until `release`, so edits can arrive while a save is in flight.
    hold: () => {
      held = [];
    },
    release: () => {
      const waiting = held ?? [];
      held = undefined;
      for (const resolve of waiting) {
        resolve();
      }
    },
    // Holds Product Sync uploads after their chunks are stored, until `releaseUploads`.
    holdUploads: () => {
      uploadsHeld = [];
    },
    releaseUploads: () => {
      const waiting = uploadsHeld ?? [];
      uploadsHeld = undefined;
      for (const resolve of waiting) {
        resolve();
      }
    },
    // Holds imports until `releaseImports`, so one can be cancelled or interrupted while copying.
    holdImports: () => {
      importsHeld = [];
    },
    releaseImports: () => {
      const waiting = importsHeld ?? [];
      importsHeld = undefined;
      for (const resolve of waiting) {
        resolve();
      }
    },
  };
}
