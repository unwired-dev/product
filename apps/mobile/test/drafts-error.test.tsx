import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
import {
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';

import { DraftList } from '../src/composer.tsx';
import { InboxProvider } from '../src/mailbox.tsx';

const snapshot: RegistrationSnapshot = {
  kind: 'connected',
  productAccountId: 'account-a',
  signInProvider: 'google',
  mailboxes: JSON.stringify([
    {
      id: 'connection-alex',
      address: 'alex@example.invalid',
      state: 'connected',
    },
  ]),
};

// Rendered host/store tests.
describe('Drafts that didn’t open', () => {
  it('says they didn’t open, and opens them on Try Again', async () => {
    expect.hasAssertions();
    const logged = jest.spyOn(console, 'error').mockReturnValue(undefined);
    const registration = {
      getSnapshot: () => ({ snapshot, busy: false, failed: false }),
      subscribe: () => () => undefined,
    };
    // Storage refuses the first read for a reason the app can't name.
    let owner: string | undefined = undefined;
    const drafts = createDrafts(
      createSyntheticDrafts(() => owner).native,
      registration,
    );
    const app = await render(
      <InboxProvider
        drafts={drafts}
        mailboxes={createMailboxes(syntheticConnections({}), registration)}>
        <DraftList />
      </InboxProvider>,
    );
    try {
      await expect(
        screen.findByRole('alert', {
          name: 'Your Drafts didn’t open. They have been kept. Choose Try Again to open them again.',
        }),
      ).resolves.toBeOnTheScreen();
      owner = 'account-a';
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await waitFor(() => {
        expect(drafts.getSnapshot().kind).toBe('ready');
      });
      expect(screen.queryByRole('alert')).not.toBeOnTheScreen();
    } finally {
      await app.unmount();
      logged.mockRestore();
    }
  });
});
