import * as Fiber from 'effect/Fiber';

import { createDrafts } from '../src/drafts.ts';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '../src/testing/drafts.ts';
import { alex, connected, device, present } from './draft-sync-fixture.ts';

describe('draft key rotation', () => {
  // Replaces the native adoption half of ProductSyncTests.draftWritesAtAnOvertakenEpochAdoptBeforeRetrying.
  it('adopts the newer key epoch a refused write names before the next pass retries it', async () => {
    expect.hasAssertions();
    const server = createSyntheticProductSync();
    const storage = createSyntheticDrafts(() => 'account-a', { server });
    const native = present(storage.sync, 'Draft sync');
    const snapshot = connected('account-a');
    let adoptions = 0;
    const adoptKeyRotation = () => {
      expect(Fiber.getCurrent()).toBeUndefined();
      adoptions += 1;
      return Promise.resolve();
    };
    const drafts = createDrafts(
      storage.native,
      {
        getSnapshot: () => ({ snapshot, busy: false, failed: false }),
        subscribe: () => () => undefined,
      },
      { native, delay: 60_000, adoptKeyRotation },
    );
    await drafts.load();
    const id = present(await drafts.create(alex), 'a new Draft');
    // Another device's removal moved the account on; the write sealed at the old epoch is refused.
    vi.spyOn(native, 'pushDraft').mockRejectedValueOnce(
      Object.assign(new Error('Rotated'), { code: 'key-rotation-required' }),
    );
    await drafts.sync();
    expect(adoptions).toBe(1);
    await drafts.sync();
    const mac = await device(server);
    await mac.drafts.sync();
    expect(mac.draft(id)).toMatchObject({ id });
    expect(adoptions).toBe(1);
  });
});
