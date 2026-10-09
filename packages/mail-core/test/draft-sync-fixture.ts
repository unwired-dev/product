import type { Draft, DraftsState } from '../src/drafts.ts';
import type { RegistrationSnapshot } from '../src/registration.ts';
import type { SyntheticProductSync } from '../src/testing/drafts.ts';

import { assetsOf, createDrafts, draftOf } from '../src/drafts.ts';
import { createSyntheticDrafts } from '../src/testing/drafts.ts';

export const alex = { id: 'connection-alex', address: 'alex@example.invalid' };

export const connected = (productAccountId: string): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId,
  signInProvider: 'google',
  mailboxes: JSON.stringify([{ ...alex, state: 'connected' }]),
});

export const ready = (state: DraftsState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected ready Drafts, received ${state.kind}`);
  }
  return state;
};

export const present = <T>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`Expected ${what}`);
  }
  return value;
};

// One enrolled device of `productAccountId` with its own encrypted Draft storage. Automatic
// synchronization waits a minute, so each scenario decides when a device synchronizes.
export async function device(
  server: Readonly<SyntheticProductSync>,
  productAccountId = 'account-a',
) {
  let snapshot: RegistrationSnapshot = connected(productAccountId);
  const listeners = new Set<() => void>();
  const registration = {
    getSnapshot: () => ({ snapshot, busy: false, failed: false }),
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
  const storage = createSyntheticDrafts(() => productAccountId, {
    server,
  });
  const open = async () => {
    const store = createDrafts(storage.native, registration, {
      native: present(storage.sync, 'Draft sync'),
      delay: 60_000,
    });
    await store.load();
    return store;
  };
  let drafts = await open();
  return {
    storage,
    get drafts() {
      return drafts;
    },
    // A relaunch reopens the same storage in a new process.
    relaunch: async () => {
      storage.relaunch();
      drafts = await open();
    },
    reconnect: async () => {
      snapshot = { kind: 'signed-out' };
      for (const listener of listeners) {
        listener();
      }
      snapshot = connected(productAccountId);
      for (const listener of listeners) {
        listener();
      }
      await drafts.load();
      await drafts.sync();
    },
    list: () => ready(drafts.getSnapshot()).drafts,
    draft: (id: string) =>
      present(draftOf(drafts.getSnapshot(), id), `Draft ${id}`),
  };
}

// The complete asset `id` of a Draft, or a failed test.
export const complete = (draft: Draft, id: string | undefined) => {
  const asset = assetsOf(draft).find((each) => each.id === id);
  if (asset?.state !== 'complete') {
    throw new Error('Expected a complete asset');
  }
  return asset;
};
