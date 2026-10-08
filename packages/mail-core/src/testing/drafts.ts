import type { AssetSource, NativeDrafts, PickSource } from '../drafts.ts';

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

// Draft storage with native code's rules: one document bound to the Product Account that wrote
// it, which another account opens as empty, replaced only from the revision read. Asset bytes are
// bound to their account and identifier, stored before any Draft names them, and removed once a
// stored document no longer keeps them, unless their import has not been committed yet. It holds
// no encryption; the hosted native suite covers ciphertext and keys.
export function createSyntheticDrafts(
  account: () => string | undefined,
  {
    outgoingLimit = 100 * 1024 * 1024,
  }: Readonly<{ outgoingLimit?: number }> = {},
) {
  let stored:
    | Readonly<{ owner: string; revision: number; document: string }>
    | undefined = undefined;
  // The rejection code for the next commit, as when the device locks or storage fails.
  let failing: string | undefined = undefined;
  let held: Array<() => void> | undefined = undefined;
  let importsHeld: Array<() => void> | undefined = undefined;
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
        Readonly<{ uri: string; name: string; type: string }>
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
  return {
    native,
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
        Readonly<{ uri: string; name: string; type: string }>
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
