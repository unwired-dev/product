import { ok } from 'node:assert/strict';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts, draftOf } from '@private-email/mail-core/drafts';
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

const alex = { id: 'connection-alex', address: 'alex@example.invalid' };
const snapshot: RegistrationSnapshot = {
  kind: 'connected',
  productAccountId: 'account-a',
  signInProvider: 'google',
  mailboxes: JSON.stringify([{ ...alex, state: 'connected' }]),
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
    let owner: string | undefined = 'account-a';
    const storage = createSyntheticDrafts(() => owner);
    const saved = createDrafts(storage.native, registration);
    await saved.load();
    const id = await saved.create(alex);
    ok(id, 'Expected a saved Draft');
    // Storage refuses the next read for a reason the app can't name.
    owner = undefined;
    const drafts = createDrafts(storage.native, registration);
    const app = await render(
      <InboxProvider
        drafts={drafts}
        mailboxes={createMailboxes(syntheticConnections({}), registration)}>
        <DraftList />
      </InboxProvider>,
    );
    const failed =
      'Your Drafts didn’t open. They have been kept. Choose Try Again to open them again.';
    try {
      await expect(
        screen.findByRole('alert', { name: failed }),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText(failed)).toBeOnTheScreen();
      owner = 'account-a';
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await waitFor(() => {
        expect(draftOf(drafts.getSnapshot(), id)).toBeDefined();
      });
      expect(screen.queryByRole('alert')).not.toBeOnTheScreen();
    } finally {
      await app.unmount();
      logged.mockRestore();
    }
  });
});
