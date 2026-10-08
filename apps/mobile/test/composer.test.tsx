import { ok } from 'node:assert/strict';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useMemo, useState, useSyncExternalStore } from 'react';

import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

const alex = syntheticMailboxes['alex@example.invalid'];
const other = syntheticMailboxes['other@example.invalid'];

const connected = (
  addresses: ReadonlyArray<keyof typeof syntheticMailboxes>,
): RegistrationSnapshot => ({
  kind: 'connected',
  productAccountId: 'synthetic-product-account',
  signInProvider: 'google',
  mailboxes: JSON.stringify(
    addresses.map((address) => ({
      id: syntheticMailboxes[address],
      address,
      state: 'connected',
    })),
  ),
});

// Registration with an account whose mailboxes the journey changes.
function account(initial: RegistrationSnapshot) {
  let snapshot = { snapshot: initial, busy: false, failed: false };
  const listeners = new Set<() => void>();
  return {
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    change: (next: RegistrationSnapshot) => {
      snapshot = { snapshot: next, busy: false, failed: false };
      for (const listener of listeners) {
        listener();
      }
    },
  };
}

const ignore = () => undefined;

// The app's composition: the Inbox column and the detail column, which shows the composer.
function App({
  registration,
  drafts,
  openAccount = ignore,
}: {
  readonly registration: ReturnType<typeof account>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly openAccount?: () => void;
}) {
  const { snapshot } = useSyncExternalStore(
    registration.subscribe,
    registration.getSnapshot,
  );
  const mailboxes = useMemo(
    () =>
      createMailboxes(
        syntheticConnections({
          [alex]: createSyntheticGmail({ messages: 1 }),
          [other]: createSyntheticGmail({
            address: 'other@example.invalid',
            messages: 1,
          }),
        }),
        registration,
      ),
    [registration],
  );
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: mailboxesOf(snapshot),
        openAccount,
        authorizeGmail: () => Promise.resolve(),
        refreshInbox: (load) => load(),
      }}>
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <Inbox
          composing={composing}
          onCompose={setComposing}
          onSelect={() => undefined}
          selected={undefined}
        />
        {composing === undefined ? null : (
          <Composer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
          />
        )}
      </InboxProvider>
    </AccountContext>
  );
}

const press = async (name: string) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

describe('composing Drafts', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one composer path end to end. */
  it('closes an untouched composer without deleting content saved by another editor', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const current = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={current}
        registration={registration}
      />,
    );
    await press('New Message');
    const [initial] = draftsOf(current.getSnapshot());
    ok(initial, 'Expected a Draft');
    const completed = { ...initial, subject: 'Completed in another editor' };
    await act(async () => {
      await current.update(completed, initial);
    });
    expect(screen.getByLabelText('Subject')).toHaveProp('value', '');
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())[0]?.subject).toBe(
      'Completed in another editor',
    );
  });

  it('composes a rich-text Draft that autosaves and reopens after relaunch without sending', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const first = await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        registration={registration}
      />,
    );
    await press('New Message');
    await expect(
      screen.findByRole('button', {
        name: 'Send from alex@example.invalid',
      }),
    ).resolves.toHaveProp('accessibilityState', { selected: true });

    // Recipients become tokens; invalid text stays for correction and duplicates are refused.
    const to = screen.getByLabelText('To');
    await fireEvent.changeText(to, '"Maya Chen" <maya@example.com>, ');
    expect(
      screen.getByRole('button', { name: 'To: Maya Chen <maya@example.com>' }),
    ).toBeOnTheScreen();
    await fireEvent.changeText(to, 'not an address');
    await fireEvent(to, 'blur');
    expect(screen.getByText('Enter a valid email address.')).toBeOnTheScreen();
    expect(to).toHaveProp('value', 'not an address');
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Subject edit',
    );
    await fireEvent.changeText(screen.getByLabelText('Message body'), 'a');
    await press('Undo');
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Subject edit',
    );
    expect(screen.getByLabelText('Message body')).not.toHaveTextContent('a');
    await press('Show Cc and Bcc');
    const cc = screen.getByLabelText('Cc');
    await fireEvent.changeText(cc, 'MAYA@example.com,');
    expect(screen.getByText('Already added')).toBeOnTheScreen();

    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Studio review',
    );
    // A Markdown marker becomes a bulleted item; one Undo restores the literal marker.
    const body = screen.getByLabelText('Message body');
    await fireEvent.changeText(body, '-');
    await fireEvent.changeText(body, '- ');
    expect(body).toHaveTextContent('• ');
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('- ');
    await press('Redo');
    await fireEvent.changeText(
      screen.getByLabelText('Message body'),
      '• Notes',
    );
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    // Closing finishes an address still being typed, but not invalid text.
    await press('Close');
    expect(
      screen.getByText(
        'Correct or remove the invalid address to close this Draft.',
      ),
    ).toBeOnTheScreen();
    await fireEvent.changeText(
      screen.getByLabelText('To'),
      'oliver@example.com',
    );
    await press('Close');
    expect(
      screen.getByRole('button', {
        name: 'Draft. Studio review. To Maya Chen, oliver@example.com. From alex@example.invalid',
      }),
    ).toBeOnTheScreen();
    await first.unmount();

    // After relaunch the Draft is listed apart from received mail and opens for editing.
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        registration={registration}
      />,
    );
    await press(
      'Draft. Studio review. To Maya Chen, oliver@example.com. From alex@example.invalid',
    );
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Studio review',
    );
    expect(screen.getByLabelText('Message body')).toHaveTextContent('• Notes');

    // Removing its sending mailbox keeps the Draft and asks for another sender.
    await act(async () => {
      registration.change(connected(['other@example.invalid']));
      await Promise.resolve();
    });
    expect(
      screen.getByText(
        'This mailbox was removed from this account. Choose another mailbox to send from.',
      ),
    ).toBeOnTheScreen();
    await press('Send from other@example.invalid');
    expect(
      screen.getByRole('button', { name: 'Send from other@example.invalid' }),
    ).toHaveProp('accessibilityState', { selected: true });
  });

  it('keeps a Draft open while it cannot be saved', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const openAccount = jest.fn<undefined, []>();
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        openAccount={openAccount}
        registration={registration}
      />,
    );
    await press('New Message');
    storage.failNextCommit('unavailable');
    await fireEvent.changeText(
      await screen.findByLabelText('Subject'),
      'Unsaved',
    );
    await waitFor(() => {
      expect(screen.getByText(/Not saved/u)).toBeOnTheScreen();
    });
    storage.failNextCommit('locked');
    await press('Close');
    expect(
      screen.getByText(
        'This Draft could not be saved, so it stays open. Try again, or discard it.',
      ),
    ).toBeOnTheScreen();
    storage.failNextCommit('locked');
    await press('New Message');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Unsaved');
    storage.failNextCommit('locked');
    await press('Account');
    expect(openAccount).not.toHaveBeenCalled();
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Unsaved');
    await press('Try again');
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    await press('New Message');
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Discard me');
    await press('Discard');
    storage.failNextCommit('locked');
    await press('Discard Draft');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Discard me');
    expect(
      screen.getByText(
        'This Draft could not be discarded, so it stays open. Try again.',
      ),
    ).toBeOnTheScreen();
    await press('Try again');
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
  });

  it('opens the account page only after leaving an open composer', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const openAccount = jest.fn<undefined, []>();
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        openAccount={openAccount}
        registration={registration}
      />,
    );
    await press('New Message');
    await fireEvent.changeText(await screen.findByLabelText('To'), 'not valid');
    await press('Account');
    expect(openAccount).not.toHaveBeenCalled();
    expect(
      screen.getByText(
        'Correct or remove the invalid address to close this Draft.',
      ),
    ).toBeOnTheScreen();
    await fireEvent.changeText(screen.getByLabelText('To'), 'maya@example.com');
    await press('Account');
    expect(openAccount).toHaveBeenCalledWith();
    // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
    expect(openAccount).toHaveBeenCalledTimes(1);
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    expect(storage.stored()?.document).toContain('maya@example.com');
  });

  it('renders a long Draft list a window at a time', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    for (let index = 0; index < 60; index += 1) {
      await drafts.create({ id: alex, address: 'alex@example.invalid' });
    }
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    const rows = await screen.findAllByRole('button', { name: /^Draft\./u });
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.length).toBeLessThan(60);
  });
  /* oxlint-enable vitest/max-expects */
});
