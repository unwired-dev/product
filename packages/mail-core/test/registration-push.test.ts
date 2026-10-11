import { createSyntheticVault } from '../src/testing/registration-vault.ts';
import { createRegistrationFlow, launch } from './registration-flow-fixture.ts';

describe('registration push lifecycle', () => {
  it('routes push after each verification and stops watches before the backend forgets this device', async () => {
    /* oxlint-disable vitest/max-expects -- One journey proves routing, its failures and both removals. */
    expect.hasAssertions();
    const { flow, relaunch, device, google, apple, backend } = launch();
    await flow.signIn('google');
    expect(backend.push).toStrictEqual([]);
    await flow.addMailbox(false);
    expect(backend.push).toStrictEqual(['route']);
    await relaunch().restore();
    expect(backend.push).toStrictEqual(['route', 'route']);
    // Offline, the saved Inbox opens without routing.
    backend.offline = true;
    await expect(relaunch().restore()).resolves.toMatchObject({
      kind: 'cached',
    });
    expect(backend.push).toStrictEqual(['route', 'route']);
    backend.offline = false;

    // Routing never fails verification, but the end of this device's access purges it.
    const synthetic = { device, google, apple, backend };
    const routing = (code: string) =>
      createRegistrationFlow({
        ...createSyntheticVault(synthetic).vault,
        routeMailboxes: () =>
          Promise.reject(Object.assign(new Error('Synthetic'), { code })),
      });
    await expect(routing('unavailable').restore()).resolves.toMatchObject({
      kind: 'connected',
    });

    // Sign-out stops watches before the backend removes this device and its routes.
    const { vault } = createSyntheticVault(synthetic);
    const stopped: number[] = [];
    await expect(
      createRegistrationFlow({
        ...vault,
        stopMailboxWatches: async () => {
          stopped.push(backend.unregistered.length);
          return vault.stopMailboxWatches();
        },
      }).signOut(),
    ).resolves.toStrictEqual({ kind: 'signed-out' });
    expect(stopped).toStrictEqual([0]);
    expect(backend.unregistered).toHaveLength(1);

    await flow.signIn('google');
    await flow.addMailbox(false);
    await expect(routing('revoked').restore()).resolves.toStrictEqual({
      kind: 'signed-out',
      notice: 'revoked',
    });
    expect(device.record).toBeUndefined();

    // Deletion does too, before the account and every route are deleted.
    await flow.signIn('google');
    await flow.addMailbox(false);
    const deletion = createSyntheticVault(synthetic).vault;
    await expect(
      createRegistrationFlow({
        ...deletion,
        stopMailboxWatches: async () => {
          stopped.push(backend.deletions.length);
          return deletion.stopMailboxWatches();
        },
      }).deleteProductAccount(),
    ).resolves.toStrictEqual({ kind: 'signed-out', notice: 'deleted' });
    expect(stopped).toStrictEqual([0, 0]);
    expect(backend.deletions).toHaveLength(1);
  });
});
