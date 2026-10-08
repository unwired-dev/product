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
  within,
} from '@testing-library/react-native';
import { StrictMode, useMemo, useState, useSyncExternalStore } from 'react';
import { View } from 'react-native';

import type { Selection } from '../src/inbox.tsx';

import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

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

// A save that throws once, as when storage fails unexpectedly, then saves normally.
const failingOnce = (save: () => Promise<boolean>) => {
  let failed = false;
  return async () => {
    if (!failed) {
      failed = true;
      throw new Error('storage failed');
    }
    return save();
  };
};

// Exercise refused and unexpectedly rejected deletion with the real store underneath.
const discardOutcome =
  (discard: ReturnType<typeof createDrafts>['discard'], failure: string) =>
  async (...args: Parameters<typeof discard>) => {
    const removed = await discard(...args);
    if (!removed && failure === 'rejected') {
      throw new Error('unexpected discard failure');
    }
    return removed;
  };

// The app's composition: the Inbox column and the detail column, which shows the composer.
function App({
  registration,
  drafts,
  openAccount = ignore,
  initialDraft,
}: {
  readonly registration: ReturnType<typeof account>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly openAccount?: () => void;
  readonly initialDraft?: string;
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
  const [composing, setComposing] = useState<string | undefined>(initialDraft);
  const [selected, setSelected] = useState<Selection>();
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
          onSelect={setSelected}
          selected={selected}
        />
        {composing === undefined ? null : (
          <Composer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={setComposing}
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
  it('keeps forward and backward deletion attached to their marked characters', async () => {
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
    const body = () => screen.getByLabelText('Message body');
    await fireEvent.changeText(body(), 'aa');
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 1 } },
    });
    await press('Bold');
    await fireEvent(body(), 'keyDown', {
      nativeEvent: { key: 'b', metaKey: false },
    });
    expect(draftsOf(current.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'a', marks: ['bold'] },
      { text: 'a' },
    ]);
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 1, end: 1 } },
    });
    // keyDownEvents consumes matching native keys; it does not limit onKeyDown dispatch.
    expect(body().props.keyDownEvents).not.toContainEqual(
      expect.objectContaining({ key: 'Delete' }),
    );
    await fireEvent(body(), 'keyDown', {
      nativeEvent: { key: 'Delete', metaKey: false },
    });
    expect(draftsOf(current.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'a', marks: ['bold'] },
      { text: 'a' },
    ]);
    await fireEvent.changeText(body(), 'a');
    expect(draftsOf(current.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'a', marks: ['bold'] },
    ]);
    await press('Undo');
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 1, end: 1 } },
    });
    await fireEvent(body(), 'keyDown', {
      nativeEvent: { key: 'Backspace', metaKey: false },
    });
    await fireEvent.changeText(body(), 'a');
    expect(draftsOf(current.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'a' },
    ]);
  });

  it('preserves native deletion, block normalization and separate Undo steps', async () => {
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
    const body = () => screen.getByLabelText('Message body');
    const cases = [
      { text: 'e\u0301x', start: 0, end: 0, after: 'x' },
      { text: '👍🏽x', start: 0, end: 0, after: 'x' },
      { text: '👨‍👩‍👧‍👦x', start: 0, end: 0, after: 'x' },
      { text: '🙂x', start: 0, end: 0, after: 'x' },
      { text: 'abcd', start: 1, end: 3, after: 'ad' },
      { text: 'a\nb', start: 1, end: 1, after: 'ab' },
    ];
    for (const { text, start, end, after } of cases) {
      await fireEvent.changeText(body(), text);
      await fireEvent(body(), 'selectionChange', {
        nativeEvent: { selection: { start, end } },
      });
      const before = draftsOf(current.getSnapshot())[0]?.body;
      await fireEvent(body(), 'keyDown', {
        nativeEvent: { key: 'Delete', metaKey: false },
      });
      // Native owns deletion and its collapsed caret. keyDown only records direction.
      expect(draftsOf(current.getSnapshot())[0]?.body).toStrictEqual(before);
      await fireEvent.changeText(body(), after);
      await fireEvent(body(), 'selectionChange', {
        nativeEvent: { selection: { start, end: start } },
      });
      expect(body()).toHaveTextContent(after);
      await press('Undo');
      expect(draftsOf(current.getSnapshot())[0]?.body).toStrictEqual(before);
      await press('Redo');
      expect(body()).toHaveTextContent(after);
    }

    await fireEvent.changeText(body(), 'aa');
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 0 } },
    });
    await press('Bulleted list');
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 1, end: 1 } },
    });
    await fireEvent(body(), 'keyDown', {
      nativeEvent: { key: 'Delete', metaKey: false },
    });
    await fireEvent.changeText(body(), '•aa');
    expect(draftsOf(current.getSnapshot())[0]?.body).toStrictEqual([
      { kind: 'paragraph', spans: [{ text: 'aa' }] },
    ]);
    expect(body()).toHaveProp('selection', { start: 0, end: 0 });
    await press('Undo');
    expect(body()).toHaveTextContent('• aa');
    await press('Redo');
    expect(body()).toHaveTextContent('aa');

    for (const modifiers of [
      { altKey: true },
      { ctrlKey: true },
      { shiftKey: true },
      { metaKey: true },
    ]) {
      const before = draftsOf(current.getSnapshot())[0]?.body;
      await fireEvent(body(), 'keyDown', {
        nativeEvent: { key: 'Delete', metaKey: false, ...modifiers },
      });
      expect(draftsOf(current.getSnapshot())[0]?.body).toStrictEqual(before);
    }

    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 2, end: 2 } },
    });
    const atEnd = draftsOf(current.getSnapshot())[0]?.body;
    await fireEvent(body(), 'keyDown', {
      nativeEvent: { key: 'Delete', metaKey: false },
    });
    expect(draftsOf(current.getSnapshot())[0]?.body).toStrictEqual(atEnd);
    await press('Undo');
    expect(body()).toHaveTextContent('• aa');
  });

  it('closes an empty composer without deleting content saved by another window', async () => {
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
    // Close finishes whitespace-only entry, which may rebind before empty disposal.
    await fireEvent.changeText(screen.getByLabelText('To'), ' ');
    const [initial] = draftsOf(current.getSnapshot());
    ok(initial, 'Expected a Draft');
    const completed = { ...initial, subject: 'Completed in another window' };
    await act(async () => {
      await current.update(completed, initial);
    });
    expect(screen.getByLabelText('Subject')).toHaveProp('value', '');
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toHaveLength(1);
    expect(draftsOf(reopened.getSnapshot())[0]?.subject).toBe(
      'Completed in another window',
    );
  });

  it('composes a rich-text Draft that autosaves and reopens after relaunch without sending', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const current = createDrafts(storage.native, registration);
    const first = await render(
      <App
        drafts={current}
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
    // Command-B formats the selected word, and Command-Z undoes it.
    const drafts = () => draftsOf(current.getSnapshot());
    await fireEvent(screen.getByLabelText('Message body'), 'selectionChange', {
      nativeEvent: { selection: { start: 2, end: 7 } },
    });
    await fireEvent(screen.getByLabelText('Message body'), 'keyDown', {
      nativeEvent: { key: 'b', metaKey: true },
    });
    expect(drafts()[0]?.body[0]?.spans).toStrictEqual([
      { text: 'Notes', marks: ['bold'] },
    ]);
    await fireEvent(screen.getByLabelText('Message body'), 'keyDown', {
      nativeEvent: { key: 'z', metaKey: true },
    });
    expect(drafts()[0]?.body[0]?.spans).toStrictEqual([{ text: 'Notes' }]);
    // Shift-Command-Z redoes it; AppKit reports the key as an uppercase Z.
    expect(
      screen.getByLabelText('Message body').props.keyDownEvents,
    ).toContainEqual({ key: 'Z', metaKey: true, shiftKey: true });
    await fireEvent(screen.getByLabelText('Message body'), 'keyDown', {
      nativeEvent: { key: 'Z', metaKey: true, shiftKey: true },
    });
    expect(drafts()[0]?.body[0]?.spans).toStrictEqual([
      { text: 'Notes', marks: ['bold'] },
    ]);
    await fireEvent(screen.getByLabelText('Message body'), 'keyDown', {
      nativeEvent: { key: 'z', metaKey: true },
    });
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

  it('shows saved Drafts while the Inbox loads without claiming received mail is empty', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    await drafts.create({ id: alex, address: 'alex@example.invalid' });
    const connections = syntheticConnections({
      [alex]: createSyntheticGmail(),
    });
    let release = ignore;
    // oxlint-disable-next-line promise/avoid-new -- Hold the native cache open until the loading assertions finish.
    const loading = new Promise<undefined>((resolve) => {
      release = () => {
        resolve(undefined);
      };
    });
    const mailboxes = createMailboxes(
      {
        ...connections,
        openMailbox: async (...args) => {
          await loading;
          return connections.openMailbox(...args);
        },
      },
      registration,
    );
    await render(
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <Inbox
          onCompose={ignore}
          onSelect={ignore}
          selected={undefined}
        />
      </InboxProvider>,
    );
    const name = 'Draft. No subject. No recipients. From alex@example.invalid';
    await expect(
      screen.findByRole('button', { name }),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByLabelText('Loading Inbox')).toBeOnTheScreen();
    expect(screen.queryByText('Your inbox is clear.')).not.toBeOnTheScreen();
    expect(
      screen.queryByLabelText('Search senders and subjects'),
    ).not.toBeOnTheScreen();
    await act(async () => {
      release();
    });
    await expect(
      screen.findByText('Your inbox is clear.'),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByRole('button', { name })).toBeOnTheScreen();
  });

  it('hides Drafts during local and online search and saves before selecting a Gmail result', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    await fireEvent.changeText(
      await screen.findByLabelText('Subject'),
      'Synthetic message 0',
    );
    const draftName = /^Draft\. Synthetic message 0\./u;
    await expect(
      screen.findByRole('button', { name: draftName }),
    ).resolves.toHaveProp('accessibilityState', { selected: true });
    const search = async (query: string) => {
      await act(async () => {
        await fireEvent.changeText(
          await screen.findByLabelText('Search senders and subjects'),
          query,
        );
      });
    };
    await search('no matching mail');
    await expect(
      screen.findByText(
        'No mail saved on this device matches “no matching mail”.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(
      screen.queryByRole('button', { name: draftName }),
    ).not.toBeOnTheScreen();
    expect(screen.queryByText('Your inbox is clear.')).not.toBeOnTheScreen();
    await search('Synthetic message 0');
    const resultName =
      'Unread. Maya Chen. Synthetic message 0. Downloads from Gmail when opened';
    await expect(
      screen.findByRole('button', { name: resultName }),
    ).resolves.toHaveProp('accessibilityState', { selected: false });
    expect(
      screen.queryByRole('button', { name: draftName }),
    ).not.toBeOnTheScreen();
    await press('Search Gmail for “Synthetic message 0”');
    await expect(
      screen.findByRole('header', { name: 'From Gmail' }),
    ).resolves.toBeOnTheScreen();
    const onlineName = 'Unread. Maya Chen. Synthetic message 0';
    await expect(
      screen.findByRole('button', { name: onlineName }),
    ).resolves.toHaveProp('accessibilityState', { selected: false });
    expect(screen.getByRole('button', { name: resultName })).toBeOnTheScreen();
    expect(
      screen.queryByRole('header', { name: 'Drafts' }),
    ).not.toBeOnTheScreen();
    expect(
      screen.getByRole('button', { name: 'New Message' }),
    ).toBeOnTheScreen();
    await fireEvent.changeText(screen.getByLabelText('To'), 'not valid');
    await press(onlineName);
    expect(
      screen.getByText(
        'Correct or remove the invalid address to close this Draft.',
      ),
    ).toBeOnTheScreen();
    expect(screen.getByRole('button', { name: onlineName })).toHaveProp(
      'accessibilityState',
      { selected: false },
    );
    await fireEvent.changeText(
      screen.getByLabelText('To'),
      'maya@example.com,',
    );
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    storage.failNextCommit('unavailable');
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Authored while searching',
    );
    await waitFor(() => {
      expect(screen.getByText(/Not saved/u)).toBeOnTheScreen();
    });
    storage.failNextCommit('locked');
    await press(onlineName);
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Authored while searching',
    );
    expect(
      screen.getByText(
        'This Draft could not be saved, so it stays open. Try again, or discard it.',
      ),
    ).toBeOnTheScreen();
    expect(screen.getByRole('button', { name: onlineName })).toHaveProp(
      'accessibilityState',
      { selected: false },
    );
    await press(onlineName);
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    expect(screen.getByRole('button', { name: onlineName })).toHaveProp(
      'accessibilityState',
      { selected: true },
    );
    await search('');
    expect(
      screen.queryByRole('header', { name: 'From Gmail' }),
    ).not.toBeOnTheScreen();
    await expect(
      screen.findByRole('button', {
        name: /^Draft\. Authored while searching\./u,
      }),
    ).resolves.toHaveProp('accessibilityState', { selected: false });
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())[0]).toMatchObject({
      subject: 'Authored while searching',
      to: [{ address: 'maya@example.com' }],
    });
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

  it('keeps a recipient still being typed through an interruption', async () => {
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
    await fireEvent.changeText(await screen.findByLabelText('To'), 'maya@exa');
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    // The app ends without leaving the field or closing the composer.
    await first.unmount();
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        registration={registration}
      />,
    );
    await press('Draft. No subject. No recipients. From alex@example.invalid');
    expect(screen.getByLabelText('To')).toHaveProp('value', 'maya@exa');
  });

  it('undoes recipient corrections without erasing earlier typing', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        registration={registration}
      />,
    );
    await press('New Message');
    const to = screen.getByLabelText('To');
    for (const text of [
      'm',
      'ma',
      'may',
      'maya',
      'maya@',
      'maya@e',
      'maya@ex',
      'maya@exa',
    ]) {
      await fireEvent.changeText(to, text);
      await fireEvent(to, 'selectionChange', {
        nativeEvent: { selection: { start: text.length, end: text.length } },
      });
    }
    // Moving the caret starts a new typing step, even within the same word.
    await fireEvent(to, 'selectionChange', {
      nativeEvent: { selection: { start: 1, end: 1 } },
    });
    await fireEvent.changeText(to, 'mXaya@exa');
    await fireEvent(to, 'selectionChange', {
      nativeEvent: { selection: { start: 2, end: 2 } },
    });
    await press('Undo');
    expect(to).toHaveProp('value', 'maya@exa');
    await press('Redo');
    expect(to).toHaveProp('value', 'mXaya@exa');
    // A deletion is a separate correction too.
    await fireEvent.changeText(to, 'mXaya@ex');
    await press('Undo');
    expect(to).toHaveProp('value', 'mXaya@exa');
    await press('Redo');
    expect(to).toHaveProp('value', 'mXaya@ex');
    await press('Close');
    expect(screen.getByLabelText('To')).toBeOnTheScreen();
    await fireEvent.changeText(to, '');
    await press('Close');
    expect(screen.queryByLabelText('To')).toBeNull();
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toStrictEqual([]);
  });

  it('keeps a stale editor on its own conflicting copy', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    const created = await drafts.create({
      id: alex,
      address: 'alex@example.invalid',
    });
    ok(created);
    const id: string = created;
    const editor = (name: string) => (
      <View testID={name}>
        <App
          drafts={drafts}
          registration={registration}
          initialDraft={id}
        />
      </View>
    );
    await render(
      <>
        {editor('first')}
        {editor('second')}
      </>,
    );
    const first = within(screen.getByTestId('first'));
    const second = within(screen.getByTestId('second'));
    await fireEvent.changeText(first.getByLabelText('Subject'), 'First window');
    const staleSubject = second.getByLabelText('Subject');
    // Native text events can arrive before React has committed the synchronous rebind.
    await act(() => {
      staleSubject.props.onChangeText('Second');
      staleSubject.props.onChangeText('Second window');
    });
    const copy = second.getByRole('button', {
      name: /^Conflicting Draft\. Second window\./u,
    });
    expect(copy).toHaveProp('accessibilityState', { selected: true });
    expect(
      first.getByRole('button', { name: /^Draft\. First window\./u }),
    ).toHaveProp('accessibilityState', { selected: true });
    // Following the copy retains the mounted editor's history, not just its saved payload.
    await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    expect(second.getByLabelText('Subject')).toHaveProp('value', 'Second');
    await fireEvent.press(second.getByRole('button', { name: 'Undo' }));
    expect(second.getByLabelText('Subject')).toHaveProp('value', '');
    await fireEvent.press(second.getByRole('button', { name: 'Redo' }));
    expect(second.getByLabelText('Subject')).toHaveProp('value', 'Second');
    await fireEvent.press(second.getByRole('button', { name: 'Redo' }));
    expect(second.getByLabelText('Subject')).toHaveProp(
      'value',
      'Second window',
    );
    await fireEvent.changeText(
      second.getByLabelText('Subject'),
      'Second window continued',
    );
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(2);
    expect(
      draftsOf(drafts.getSnapshot()).find(({ id: each }) => each !== id)
        ?.subject,
    ).toBe('Second window continued');
    // Discarding in the stale window deletes only its own version.
    await act(async () => {
      await fireEvent.press(second.getByRole('button', { name: 'Discard' }));
    });
    await act(async () => {
      await fireEvent.press(
        second.getByRole('button', { name: 'Discard Draft' }),
      );
    });
    expect(
      draftsOf(drafts.getSnapshot()).map(({ id: each, subject }) => [
        each,
        subject,
      ]),
    ).toStrictEqual([[id, 'First window']]);
  });

  it('undoes subject typing a word at a time wherever the caret is', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        registration={registration}
      />,
    );
    await press('New Message');
    const subject = await screen.findByLabelText('Subject');
    await fireEvent.changeText(subject, 'Hi ');
    await fireEvent(subject, 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 0 } },
    });
    await fireEvent.changeText(subject, 'XHi ');
    await fireEvent(subject, 'selectionChange', {
      nativeEvent: { selection: { start: 1, end: 1 } },
    });
    await fireEvent.changeText(subject, 'XYHi ');
    await press('Undo');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Hi ');
    // A replacement with a net one-character gain is not a continued typing step.
    await fireEvent(subject, 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 3 } },
    });
    await fireEvent.changeText(subject, 'Text');
    await fireEvent(subject, 'selectionChange', {
      nativeEvent: { selection: { start: 4, end: 4 } },
    });
    await fireEvent.changeText(subject, 'Textx');
    await press('Undo');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Text');
  });

  it('preserves edits across fields before React renders', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    const subject = await screen.findByLabelText('Subject');
    const body = screen.getByLabelText('Message body');
    const to = screen.getByLabelText('To');
    // Different-field callbacks before a render must build on the latest authored payload.
    await act(() => {
      subject.props.onChangeText('Completed subject');
      body.props.onChangeText('Completed body');
      to.props.onChangeText('maya@exa');
    });
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Completed subject',
    );
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Completed body',
    );
    expect(screen.getByLabelText('To')).toHaveProp('value', 'maya@exa');
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Completed body',
    );
    await press('Undo');
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Completed subject',
    );
    await press('Redo');
    await press('Redo');
    await act(() => {
      to.props.onChangeText('maya@example.invalid');
      to.props.onSubmitEditing();
    });
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toMatchObject([
      {
        subject: 'Completed subject',
        to: [{ address: 'maya@example.invalid' }],
      },
    ]);
  });

  it.each(['refused', 'rejected'])(
    'keeps edits accepted while a discard is %s through Close and reopen',
    async (failure) => {
      expect.hasAssertions();
      const registration = account(connected(['alex@example.invalid']));
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const base = createDrafts(storage.native, registration);
      const drafts = {
        ...base,
        discard: discardOutcome(base.discard, failure),
      };
      await render(
        <App
          drafts={drafts}
          registration={registration}
        />,
      );
      await press('New Message');
      await fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'Before discard',
      );
      await waitFor(() => {
        expect(
          screen.getByText('Draft · Saved on this device'),
        ).toBeOnTheScreen();
      });
      await press('Discard');
      await press('Keep Editing');
      await fireEvent.changeText(
        screen.getByLabelText('Message body'),
        'After cancelling discard',
      );
      await waitFor(() => {
        expect(
          screen.getByText('Draft · Saved on this device'),
        ).toBeOnTheScreen();
      });
      await press('Discard');
      storage.hold();
      storage.failNextCommit('locked');
      await press('Discard Draft');
      await fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'During discard',
      );
      await press('New Message');
      expect(screen.getByLabelText('Subject')).toHaveProp(
        'value',
        'During discard',
      );
      await act(async () => {
        storage.release();
      });
      await waitFor(() => {
        expect(
          screen.getByText(
            'This Draft could not be discarded, so it stays open. Try again.',
          ),
        ).toBeOnTheScreen();
      });
      await press('Close');
      await press(
        'Draft. During discard. No recipients. From alex@example.invalid',
      );
      expect(screen.getByLabelText('Subject')).toHaveProp(
        'value',
        'During discard',
      );
      expect(screen.getByLabelText('Message body')).toHaveTextContent(
        'After cancelling discard',
      );
      // A callback already queued by this editor cannot recreate its completed discard.
      const queuedSubject = screen.getByLabelText('Subject');
      await press('Discard');
      await press('Discard Draft');
      await act(async () => {
        queuedSubject.props.onChangeText('After completed discard');
        await drafts.save();
      });
      const reopened = createDrafts(storage.native, registration);
      await reopened.load();
      expect(draftsOf(reopened.getSnapshot())).toStrictEqual([]);
    },
  );

  it('lets a composer be left again after finishing it failed', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const base = createDrafts(storage.native, registration);
    const drafts = { ...base, save: failingOnce(base.save) };
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    await fireEvent.changeText(await screen.findByLabelText('Subject'), 'Kept');
    // Finishing the open composer fails once: it stays open.
    await press('New Message');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Kept');
    // The next attempt is not blocked by the failed one.
    await press('New Message');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', '');
  });

  it('steps back once for each Undo, even before the editor renders again', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    await render(
      <StrictMode>
        <App
          drafts={createDrafts(storage.native, registration)}
          registration={registration}
        />
      </StrictMode>,
    );
    await press('New Message');
    const subject = await screen.findByLabelText('Subject');
    await fireEvent.changeText(subject, 'One ');
    await fireEvent.changeText(subject, 'One Two ');
    await fireEvent.changeText(subject, 'One Two Three');
    const undoButton = screen.getByRole('button', { name: 'Undo' });
    // Accessibility activations reach Pressability without nested async act scopes.
    await act(() => {
      undoButton.props.onClick();
      undoButton.props.onClick();
    });
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'One ');
    const redoButton = screen.getByRole('button', { name: 'Redo' });
    await act(() => {
      redoButton.props.onClick();
      redoButton.props.onClick();
    });
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'One Two Three',
    );
    await press('Close');
    await press(
      'Draft. One Two Three. No recipients. From alex@example.invalid',
    );
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'One Two Three',
    );
  });

  it("applies an edit at the caret moved just before it, with that character's marks", async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    const body = await screen.findByLabelText('Message body');
    await fireEvent.changeText(body, 'aa');
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 1 } },
    });
    await press('Bold');
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 2, end: 2 } },
    });
    // A mark toggled at the old caret must end when the caret moves, even before rendering.
    await press('Italic');
    // The caret moves to the start and a character is typed before React renders again.
    await act(async () => {
      await Promise.all([
        fireEvent(body, 'selectionChange', {
          nativeEvent: { selection: { start: 0, end: 0 } },
        }),
        fireEvent.changeText(body, 'aaa'),
      ]);
    });
    expect(draftsOf(drafts.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'aa', marks: ['bold'] },
      { text: 'a' },
    ]);
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 3, end: 3 } },
    });
    // A formatting command and its next typed character can also share one render.
    await act(async () => {
      await Promise.all([
        fireEvent.press(screen.getByRole('button', { name: 'Italic' })),
        fireEvent.changeText(body, 'aaab'),
      ]);
    });
    expect(draftsOf(drafts.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'aa', marks: ['bold'] },
      { text: 'a' },
      { text: 'b', marks: ['italic'] },
    ]);
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 4, end: 4 } },
    });
    // Undo clears the override before a following text event, too.
    await act(async () => {
      await Promise.all([
        fireEvent.press(screen.getByRole('button', { name: 'Undo' })),
        fireEvent.changeText(body, 'aaac'),
      ]);
    });
    expect(draftsOf(drafts.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'aa', marks: ['bold'] },
      { text: 'ac' },
    ]);
  });

  it('hides the Drafts heading while a search lists received mail alone', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    const id = await drafts.create({
      id: alex,
      address: 'alex@example.invalid',
    });
    const created = draftsOf(drafts.getSnapshot()).find(
      (each) => each.id === id,
    );
    ok(created);
    await drafts.update({ ...created, subject: 'Kept Draft' }, created);
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await expect(screen.findByText('Drafts')).resolves.toBeOnTheScreen();
    await fireEvent.changeText(
      await screen.findByLabelText('Search senders and subjects'),
      'nothing matches this',
    );
    expect(screen.queryByText('Drafts')).not.toBeOnTheScreen();
  });

  it('creates one Draft when New Message is pressed again while it is pending', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    const newMessage = await screen.findByRole('button', {
      name: 'New Message',
    });
    // Storage is slow, so the first Draft is still being created at the second press.
    storage.hold();
    await fireEvent.press(newMessage);
    // The first press has left the Inbox and is waiting for its Draft to be saved.
    await fireEvent.press(newMessage);
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
  });

  it.each([
    [
      'unavailable',
      'Draft changes are not saved yet. Keep the app open and try saving again.',
    ],
    [
      'locked',
      'Draft changes are not saved while private storage is locked. Unlock your device.',
    ],
  ])(
    'saves unfinished Draft changes from the Inbox after its composer unmounts (%s)',
    async (failure, unsaved) => {
      expect.hasAssertions();
      const registration = account(connected(['alex@example.invalid']));
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      const first = await render(
        <App
          drafts={drafts}
          registration={registration}
        />,
      );
      await press('New Message');
      await fireEvent.changeText(
        await screen.findByLabelText('Subject'),
        'Kept',
      );
      storage.failNextCommit(failure);
      await fireEvent.changeText(
        await screen.findByLabelText('To'),
        'unfinished',
      );
      await expect(screen.findByText(unsaved)).resolves.toBeOnTheScreen();
      await first.unmount();
      const inbox = await render(
        <App
          drafts={drafts}
          registration={registration}
        />,
      );
      expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
      await expect(screen.findByText(unsaved)).resolves.toBeOnTheScreen();
      await press('Save Drafts');
      expect(screen.queryByText(unsaved)).not.toBeOnTheScreen();
      await inbox.unmount();
      await render(
        <App
          drafts={createDrafts(storage.native, registration)}
          registration={registration}
        />,
      );
      await press('Draft. Kept. No recipients. From alex@example.invalid');
      expect(screen.getByLabelText('Subject')).toHaveDisplayValue('Kept');
      expect(screen.getByLabelText('To')).toHaveDisplayValue('unfinished');
    },
  );
  /* oxlint-enable vitest/max-expects */
});
