import type { NativeDrafts } from '../drafts.ts';

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error(`Draft storage: ${code}`), { code }));

// Draft storage with native code's rules: one document bound to the Product Account that wrote
// it, which another account opens as empty, replaced only from the revision read. It holds no
// encryption; the hosted native suite covers ciphertext and keys.
export function createSyntheticDrafts(account: () => string | undefined) {
  let stored:
    | Readonly<{ owner: string; revision: number; document: string }>
    | undefined = undefined;
  // The rejection code for the next commit, as when the device locks or storage fails.
  let failing: string | undefined = undefined;
  let held: Array<() => void> | undefined = undefined;
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
    commitDrafts: async (owner, expectedRevision, document) => {
      if (held !== undefined) {
        const waiting = held;
        // oxlint-disable-next-line promise/avoid-new -- Holds the commit until the test releases it.
        await new Promise<void>((resolve) => {
          waiting.push(resolve);
        });
      }
      if (failing !== undefined) {
        const code = failing;
        failing = undefined;
        return rejection(code);
      }
      if (owner !== account()) {
        return rejection('mailbox-invalidated');
      }
      if ((stored?.revision ?? 0) !== expectedRevision) {
        return rejection('conflict');
      }
      stored = { owner, revision: expectedRevision + 1, document };
      return { owner, revision: expectedRevision + 1 };
    },
  };
  return {
    native,
    stored: () => stored,
    failNextCommit: (code: string) => {
      failing = code;
    },
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
  };
}
