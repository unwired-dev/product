import type { createHost } from '@private-email/mail-core/host';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

/* oxlint-disable vitest/max-expects -- One application journey verifies headless pause and activation delivery. */
import { draftOf } from '@private-email/mail-core/drafts';
import { undoSendWindow } from '@private-email/mail-core/outbox';
import { createRegistration } from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createSyntheticVault,
  syntheticMailboxes,
} from '@private-email/mail-core/testing/registration-vault';
import { AppState, TurboModuleRegistry } from 'react-native';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name.
jest.mock('@private-email/mail-core/registration-mode', () => ({
  previewInbox: true,
}));

const present = <T,>(value: T | undefined): T => {
  if (value === undefined) {
    throw new Error('Expected a value');
  }
  return value;
};
const ownerOf = (snapshot: RegistrationSnapshot) =>
  'productAccountId' in snapshot ? snapshot.productAccountId : undefined;

describe('application-owned Outbox execution', () => {
  it('pauses preview delivery through inactive and background opportunities, then sends on activation without a mounted Inbox', async () => {
    expect.hasAssertions();
    const { vault } = createSyntheticVault();
    const registered = createRegistration(vault);
    await registered.register('google');
    await registered.addMailbox();
    const { snapshot } = registered.getSnapshot();
    const storage = createSyntheticDrafts(() => ownerOf(snapshot), {
      server: createSyntheticProductSync(),
    });
    const gmail = createSyntheticGmail();
    const connection = syntheticMailboxes['alex@example.invalid'];
    const bridge = jest
      .spyOn(TurboModuleRegistry, 'getEnforcing')
      .mockReturnValue({
        getConstants: () => ({}),
        ...vault,
        ...storage.native,
        ...storage.sync,
        ...storage.delivery,
        ...syntheticConnections({ [connection]: gmail }),
      });
    const initial = AppState.currentState;
    AppState.currentState = 'background';
    jest.useFakeTimers();
    try {
      const host = jest.requireActual<ReturnType<typeof createHost>>(
        '../src/registration.ts',
      );
      try {
        const firstListener = jest.mocked(AppState.addEventListener).mock.calls
          .length;
        jest.requireActual('../src/delivery.ts');
        const change = (state: 'active' | 'inactive' | 'background') => {
          for (const [, listener] of jest
            .mocked(AppState.addEventListener)
            .mock.calls.slice(firstListener)) {
            listener(state);
          }
        };
        await host.registration.restoreOnce();
        await host.drafts.load();
        const id = present(
          await host.drafts.create({
            id: connection,
            address: 'alex@example.invalid',
          }),
        );
        const draft = present(draftOf(host.drafts.getSnapshot(), id));
        const addressed = {
          ...draft,
          to: [{ address: 'sam@example.invalid' }],
        };
        await host.drafts.update(addressed, draft);
        const current = present(draftOf(host.drafts.getSnapshot(), id));
        await expect(host.outbox.send(() => current)).resolves.toBeUndefined();
        await jest.advanceTimersByTimeAsync(undoSendWindow + 30_000);
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(0);
        change('inactive');
        await host.outbox.process();
        expect(host.drafts.getOutbox()).toMatchObject([
          { id, state: 'waiting' },
        ]);
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        change('background');
        change('active');
        await host.outbox.process();
        expect(gmail.sends).toHaveLength(1);
        expect(host.drafts.getOutbox()).toStrictEqual([]);
      } finally {
        host.outbox.dispose();
      }
    } finally {
      AppState.currentState = initial;
      jest.useRealTimers();
      bridge.mockRestore();
    }
  });
});
