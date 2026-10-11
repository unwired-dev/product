import { createRegistration } from '@private-email/mail-core/registration';
import { createRegistrationFlow } from '@private-email/mail-core/registration-flow';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import { createSyntheticVault } from '@private-email/mail-core/testing/registration-vault';
import { waitFor } from '@testing-library/react-native';
import { TurboModuleRegistry } from 'react-native';

import type { keepGmailFresh as KeepGmailFresh } from '../src/freshness.ts';
import type { gmailMailboxes as HostMailboxes } from '../src/registration.ts';

// A promise the test settles.
function deferred() {
  let settle: (value: unknown) => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Hold the host's wake until the test delivers it.
  const promise = new Promise<unknown>((resolve) => {
    settle = resolve;
  });
  return { promise, resolve: settle };
}

const subjects = (mailboxes: typeof HostMailboxes) => {
  const state = mailboxes.getSnapshot()[0]?.state;
  return state?.kind === 'ready'
    ? state.messages.map(({ subject }) => subject)
    : [];
};

describe('application-scoped Gmail freshness', () => {
  it('relies on push wakes while every mailbox is routed and polls again when one is not', async () => {
    expect.hasAssertions();
    const { vault } = createSyntheticVault();
    await createRegistration(createRegistrationFlow(vault)).register('google');
    const gmail = createSyntheticGmail();
    const id = syntheticMailboxes['alex@example.invalid'];
    // The host's APNs queue holds one wake, then reports that a reloaded context replaced it.
    const wake = deferred();
    let routes: { routes: Record<string, string>; complete: boolean } = {
      routes: { 'route-alex': id },
      complete: true,
    };
    const completeWake = jest.fn<undefined, [string, string]>();
    const native = {
      getConstants: () => ({}),
      ...vault,
      ...syntheticConnections({ [id]: gmail }),
      nextWake: jest
        .fn<Promise<unknown>, []>()
        .mockReturnValueOnce(wake.promise)
        .mockResolvedValue(null),
      mailboxRoutes: async () => routes,
      completeWake,
    };
    const bridge = jest
      .spyOn(TurboModuleRegistry, 'getEnforcing')
      .mockReturnValue(native);
    jest.useFakeTimers();
    try {
      const { keepGmailFresh } = jest.requireActual<{
        readonly keepGmailFresh: typeof KeepGmailFresh;
      }>('../src/freshness.ts');
      const { gmailMailboxes } = jest.requireActual<{
        readonly gmailMailboxes: typeof HostMailboxes;
      }>('../src/registration.ts');
      keepGmailFresh();

      // Every mailbox is routed, so the interval leaves new mail to its wake.
      gmail.deliver({ subject: 'Left to its wake' });
      await jest.advanceTimersByTimeAsync(5 * 60_000);
      expect(gmail.requests).toHaveLength(0);
      wake.resolve({
        id: 'wake-1',
        hint: { provider: 'gmail', routeId: 'route-alex' },
      });
      await waitFor(() => {
        expect(completeWake).toHaveBeenCalledWith('wake-1', 'synchronized');
      });
      expect(subjects(gmailMailboxes)).toStrictEqual(['Left to its wake']);

      // A mailbox without a current route brings the interval back.
      routes = { routes: {}, complete: false };
      gmail.deliver({ subject: 'Polled' });
      await jest.advanceTimersByTimeAsync(5 * 60_000);
      expect(subjects(gmailMailboxes)).toStrictEqual([
        'Polled',
        'Left to its wake',
      ]);
    } finally {
      jest.useRealTimers();
      bridge.mockRestore();
    }
  });
});
