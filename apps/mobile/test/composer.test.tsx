import { ok } from 'node:assert/strict';

import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { NativeTranslation } from '@private-email/mail-core/translation';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { mailboxesOf } from '@private-email/mail-core/registration';
import { imagesOf } from '@private-email/mail-core/semantic-document';
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
import { AppState, View } from 'react-native';

import type { Selection } from '../src/inbox.tsx';

import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { TranslationContext } from '../src/translation.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

const alex = syntheticMailboxes['alex@example.invalid'];
const other = syntheticMailboxes['other@example.invalid'];

const connected = (
  addresses: ReadonlyArray<keyof typeof syntheticMailboxes>,
): Extract<RegistrationSnapshot, { kind: 'connected' }> => ({
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

// A promise the test settles.
function deferred() {
  let settle: (value: unknown) => void = () => undefined;
  let fail: (reason: unknown) => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Hold the native answer until the test settles it.
  const promise = new Promise<unknown>((resolve, reject) => {
    settle = resolve;
    fail = reject;
  });
  return { promise, resolve: settle, reject: fail };
}

// A native model whose answers the test settles, recording each operation and its input.
function scriptedDraftAssistance() {
  const asked: Array<{
    operation: 'rewrite' | 'reply';
    request: string;
    input: string;
    answer: ReturnType<typeof deferred>;
  }> = [];
  const cancelled: string[] = [];
  const respond =
    (operation: 'rewrite' | 'reply') => (request: string, input: string) => {
      const answer = deferred();
      asked.push({ operation, request, input, answer });
      return answer.promise;
    };
  const native: NativeAssistance = {
    availability: () => Promise.resolve('available'),
    summarize: () => Promise.reject(new Error('unused')),
    rewrite: respond('rewrite'),
    suggestReply: respond('reply'),
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  return { native, asked, cancelled };
}

// Capture queued native input at the same composite-fiber boundary used by fireEvent.
const queuedPress = (label: string, event = 'onPress') => {
  let fiber = screen.getByLabelText(label).unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.[event];
    if (typeof handler === 'function') {
      return (text?: string) => {
        handler(text);
      };
    }
    fiber = fiber.return;
  }
  throw new Error('Expected a rendered input handler');
};

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
  onRebind = ignore,
  onCompose = ignore,
  initialDraft,
}: {
  readonly registration: ReturnType<typeof account>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly openAccount?: () => void;
  readonly onRebind?: (id: string) => void;
  readonly onCompose?: (id: string) => void;
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
          onCompose={(id) => {
            setComposing(id);
            onCompose(id);
          }}
          onSelect={setSelected}
          selected={selected}
        />
        {composing === undefined ? null : (
          <Composer
            id={composing}
            onClose={() => {
              setComposing(undefined);
            }}
            onRebind={(id) => {
              setComposing(id);
              onRebind(id);
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

// Delegate replacements emit a synthetic key; delegate-bypassing edits do not.
const deletionKey = async (
  body: Parameters<typeof fireEvent>[0],
  reported: boolean,
) => {
  if (reported) {
    await fireEvent(body, 'keyPress', { nativeEvent: { key: 'Backspace' } });
  }
};

describe('composing Drafts', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one composer path end to end. */
  it('closes an empty composer without deleting content saved by another editor', async () => {
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
    const completed = { ...initial, subject: 'Completed in another editor' };
    await act(async () => {
      await current.update(completed, initial);
    });
    expect(screen.getByLabelText('Subject')).toHaveProp('value', '');
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toHaveLength(1);
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

  it('discards its own version when a late keystroke arrives behind an autosave', async () => {
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
    storage.hold();
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Before discard',
    );
    await press('Discard');
    await press('Discard Draft');
    // This accepted native event changes the editor while its autosave is suppressed.
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'During discard',
    );
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toStrictEqual([]);
  });

  it('keeps a late edit as one conflict copy when its Discard behind a rebinding autosave fails', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    let refusing = false;
    // Storage refuses the deletion that would remove this editor's conflict copy.
    const drafts = createDrafts(
      {
        ...storage.native,
        commitDrafts: async (owner, revision, commit) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Storage refuses only the armed deletion.
          if (refusing && !commit.document.includes('Discard me')) {
            refusing = false;
            throw Object.assign(new Error('locked'), { code: 'locked' });
          }
          return storage.native.commitDrafts(owner, revision, commit);
        },
      },
      registration,
    );
    await render(
      <StrictMode>
        <App
          drafts={drafts}
          registration={registration}
        />
      </StrictMode>,
    );
    await press('New Message');
    const [before] = draftsOf(drafts.getSnapshot());
    ok(before !== undefined);
    const otherWriter = createDrafts(storage.native, registration);
    await otherWriter.load();
    await otherWriter.update({ ...before, subject: 'Other writer' }, before);
    storage.hold();
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Discard me');
    await press('Discard');
    await press('Discard Draft');
    refusing = true;
    // A native text event accepted while Discard waits.
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Late edit');
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(
      screen.getByText(
        'This Draft could not be discarded, so it stays open. Try again.',
      ),
    ).toBeOnTheScreen();
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const subjects = draftsOf(reopened.getSnapshot()).map(
      ({ subject }) => subject,
    );
    expect(subjects).toHaveLength(2);
    expect(subjects).toStrictEqual(
      expect.arrayContaining(['Late edit', 'Other writer']),
    );
  });

  it('finishes discarding its conflict copy after the composer unmounts', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const moved: string[] = [];
    const window = await render(
      <StrictMode>
        <App
          drafts={drafts}
          registration={registration}
          onRebind={(id) => {
            moved.push(id);
          }}
        />
      </StrictMode>,
    );
    await press('New Message');
    const [before] = draftsOf(drafts.getSnapshot());
    ok(before !== undefined);
    const otherWriter = createDrafts(storage.native, registration);
    await otherWriter.load();
    await otherWriter.update({ ...before, subject: 'Other writer' }, before);
    storage.hold();
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Discard me');
    await press('Discard');
    await press('Discard Draft');
    // A native window close destroys the composer independently of its pending Discard.
    await window.unmount();
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(moved).toStrictEqual([]);
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toMatchObject([
      { id: before.id, subject: 'Other writer' },
    ]);
  });

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
    // At a bold block start the control announces inherited typing marks, and disables them.
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 0 } },
    });
    expect(screen.getByRole('button', { name: 'Bold' })).toHaveProp(
      'accessibilityState',
      { selected: true },
    );
    await press('Bold');
    expect(screen.getByRole('button', { name: 'Bold' })).toHaveProp(
      'accessibilityState',
      { selected: false },
    );
    await fireEvent.changeText(body, 'Xaaac');
    expect(draftsOf(drafts.getSnapshot())[0]?.body[0]?.spans).toStrictEqual([
      { text: 'X' },
      { text: 'aa', marks: ['bold'] },
      { text: 'ac' },
    ]);
    // Moving back into marked text clears the explicit plain-typing override.
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 2, end: 2 } },
    });
    expect(screen.getByRole('button', { name: 'Bold' })).toHaveProp(
      'accessibilityState',
      { selected: true },
    );
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

  it.each([true, false])(
    'keeps the formatting of the character deletion leaves (key event: %s)',
    async (keyEvent) => {
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
      const spans = () => draftsOf(drafts.getSnapshot())[0]?.body[0]?.spans;
      await fireEvent.changeText(body, 'aa');
      await fireEvent(body, 'selectionChange', {
        nativeEvent: { selection: { start: 0, end: 1 } },
      });
      await press('Bold');
      await fireEvent(body, 'selectionChange', {
        nativeEvent: { selection: { start: 1, end: 1 } },
      });
      // RN can synthesize Backspace for any empty delegate replacement, including forward deletion.
      await deletionKey(body, keyEvent);
      // Fabric supplies the post-edit caret in onChange; its wrapper then calls onChangeText.
      await fireEvent(body, 'change', {
        nativeEvent: { text: 'a', selection: { start: 1, end: 1 } },
      });
      await fireEvent.changeText(body, 'a');
      expect(spans()).toStrictEqual([{ text: 'a', marks: ['bold'] }]);
      await press('Undo');
      await fireEvent(body, 'selectionChange', {
        nativeEvent: { selection: { start: 1, end: 1 } },
      });
      // Backward deletion moves the caret, including edits that bypass the key-emitting delegate.
      await deletionKey(body, keyEvent);
      await fireEvent(body, 'change', {
        nativeEvent: { text: 'a', selection: { start: 0, end: 0 } },
      });
      await fireEvent.changeText(body, 'a');
      expect(spans()).toStrictEqual([{ text: 'a' }]);
    },
  );

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
      const moved: string[] = [];
      const first = await render(
        <App
          drafts={drafts}
          registration={registration}
          onRebind={(id) => {
            moved.push(id);
          }}
        />,
      );
      await press('New Message');
      await fireEvent.changeText(
        await screen.findByLabelText('Subject'),
        'Kept',
      );
      const [saved] = draftsOf(drafts.getSnapshot());
      ok(saved !== undefined);
      const otherWriter = createDrafts(storage.native, registration);
      await otherWriter.load();
      storage.failNextCommit(failure);
      await fireEvent.changeText(
        await screen.findByLabelText('To'),
        'unfinished',
      );
      await expect(screen.findByText(unsaved)).resolves.toBeOnTheScreen();
      await first.unmount();
      await otherWriter.update({ ...saved, subject: 'Other writer' }, saved);
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
      expect(moved).toStrictEqual([]);
      await inbox.unmount();
      await render(
        <App
          drafts={createDrafts(storage.native, registration)}
          registration={registration}
        />,
      );
      await press(
        'Conflicting Draft. Kept. No recipients. From alex@example.invalid',
      );
      expect(screen.getByLabelText('Subject')).toHaveDisplayValue('Kept');
      expect(screen.getByLabelText('To')).toHaveDisplayValue('unfinished');
    },
  );

  it('reveals the selected Draft again without leaving unsaved invalid recipient text', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const shown: string[] = [];
    await render(
      <App
        drafts={drafts}
        registration={registration}
        onCompose={(id) => {
          shown.push(id);
        }}
      />,
    );
    await press('New Message');
    const [id] = shown;
    expect(id).toBeDefined();
    await fireEvent.changeText(await screen.findByLabelText('Subject'), 'Kept');
    storage.failNextCommit('unavailable');
    await fireEvent.changeText(
      await screen.findByLabelText('To'),
      'unfinished',
    );
    await expect(
      screen.findByText(
        'Draft changes are not saved yet. Keep the app open and try saving again.',
      ),
    ).resolves.toBeOnTheScreen();
    await press('Draft. Kept. No recipients. From alex@example.invalid');
    expect(shown).toStrictEqual([id, id]);
    expect(screen.getByLabelText('To')).toHaveDisplayValue('unfinished');
    expect(
      screen.queryByText(
        'Correct or remove the invalid address to close this Draft.',
      ),
    ).not.toBeOnTheScreen();
    expect(drafts.getSnapshot()).toMatchObject({
      kind: 'ready',
      save: 'failed',
    });
  });

  it('keeps a composer open when saving it on Close fails unexpectedly', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const base = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={{ ...base, save: failingOnce(base.save) }}
        registration={registration}
      />,
    );
    await press('New Message');
    await fireEvent.changeText(await screen.findByLabelText('Subject'), 'Kept');
    await press('Close');
    expect(
      screen.getByText(
        'This Draft could not be saved, so it stays open. Try again, or discard it.',
      ),
    ).toBeOnTheScreen();
    await press('Close');
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
  });

  it('bounds row and composer metadata previews while preserving the full Draft', async () => {
    expect.hasAssertions();
    const from = `${'f'.repeat(4096)}@example.invalid`;
    const subject = `${'S'.repeat(299)}😀subject tail`;
    const recipient = `${'R'.repeat(296)}😀recipient tail`;
    const snapshot = connected(['alex@example.invalid']);
    ok(snapshot.kind === 'connected');
    const registration = account({
      ...snapshot,
      mailboxes: JSON.stringify([
        { id: alex, address: from, state: 'connected' },
      ]),
    });
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    await drafts.load();
    const id = await drafts.create({ id: alex, address: from });
    const created = draftsOf(drafts.getSnapshot()).find(
      (each) => each.id === id,
    );
    ok(created);
    await drafts.update(
      {
        ...created,
        subject,
        to: [{ name: recipient, address: 'recipient@example.invalid' }],
        cc: [{ address: 'copy@example.invalid' }],
        conflict: true,
      },
      created,
    );
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    const rowName = `Conflicting Draft. ${'S'.repeat(299)}. To ${'R'.repeat(296)}. From ${'f'.repeat(300)}. Preview shortened.`;
    await expect(
      screen.findByRole('button', { name: rowName }),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByText(`From ${'f'.repeat(300)}`)).toBeOnTheScreen();
    expect(screen.getByText(`To ${'R'.repeat(296)}`)).toBeOnTheScreen();
    await press(rowName);
    expect(
      screen.getByRole('header', {
        name: `${'S'.repeat(299)}, subject shortened`,
      }),
    ).toBeOnTheScreen();
    expect(
      screen.getByRole('button', {
        name: `Send from ${'f'.repeat(300)}, address shortened`,
      }),
    ).toBeOnTheScreen();
    expect(screen.getByLabelText('Subject')).toHaveProp('value', subject);
    // A removed connection retains the same bounded From preview, with refusal feedback.
    await act(async () => {
      registration.change(connected([]));
    });
    expect(
      screen.getByLabelText(
        `${'f'.repeat(300)}, address shortened, cannot send`,
      ),
    ).toHaveProp('accessible', true);
    await press('Close');
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const restored = draftsOf(reopened.getSnapshot()).find(
      (each) => each.id === id,
    );
    expect(restored).toMatchObject({
      subject,
      from,
      to: [{ name: recipient, address: 'recipient@example.invalid' }],
      cc: [{ address: 'copy@example.invalid' }],
      conflict: true,
    });
  });

  it('shows and announces recipient roles in Bcc-only and mixed Drafts', async () => {
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
    await drafts.update(
      {
        ...created,
        subject: 'Quiet',
        body: [{ kind: 'paragraph', spans: [{ text: 'Only for you' }] }],
        bcc: [{ name: 'Maya Chen', address: 'maya@example.com' }],
      },
      created,
    );
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await expect(
      screen.findByRole('button', {
        name: 'Draft. Quiet. Bcc Maya Chen. From alex@example.invalid',
      }),
    ).resolves.toBeOnTheScreen();
    // A Draft with body text still shows the mailbox it sends from.
    expect(screen.getByText('From alex@example.invalid')).toBeOnTheScreen();
    expect(screen.getByText('Only for you')).toBeOnTheScreen();
    expect(screen.getByText('Bcc Maya Chen')).toBeOnTheScreen();
    const saved = draftsOf(drafts.getSnapshot()).find((each) => each.id === id);
    ok(saved);
    await act(async () => {
      await drafts.update(
        {
          ...saved,
          to: [
            { name: 'Oliver', address: 'oliver@example.com' },
            { address: 'sam@example.invalid' },
          ],
          cc: [{ address: 'copy@example.invalid' }],
        },
        saved,
      );
    });
    const summary =
      'To Oliver, sam@example.invalid · Cc copy@example.invalid · Bcc Maya Chen';
    expect(screen.getByText(summary)).toBeOnTheScreen();
    expect(
      screen.getByRole('button', {
        name: `Draft. Quiet. ${summary}. From alex@example.invalid`,
      }),
    ).toBeOnTheScreen();
  });

  it('keeps the new Draft selected from its row while creation is pending', async () => {
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
    await screen.findByRole('button', { name: 'New Message' });
    storage.hold();
    await press('New Message');
    await press('Draft. No subject. No recipients. From alex@example.invalid');
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(screen.getByLabelText('Subject')).toHaveProp('value', '');
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
  });

  it('lets a destination chosen during a slow New Message win', async () => {
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
    storage.hold();
    await fireEvent.press(newMessage);
    // The Account page is chosen while the Draft is still being created.
    await press('Account');
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);
  });

  it('removes an abandoned New Message after locked storage recovers from Save Drafts', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    let commit = storage.native.commitDrafts;
    const drafts = createDrafts(
      {
        ...storage.native,
        commitDrafts: (...args) => commit(...args),
      },
      registration,
    );
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    const newMessage = await screen.findByRole('button', {
      name: 'New Message',
    });
    storage.hold();
    await fireEvent.press(newMessage);
    await press('Account');
    // Refuse both the held creation and every cleanup save until the person retries.
    storage.failNextCommit('locked');
    commit = async () => {
      throw Object.assign(new Error('Storage locked'), { code: 'locked' });
    };
    await act(async () => {
      storage.release();
    });
    await waitFor(() => {
      expect(
        screen.getByRole('button', { name: 'New Message' }),
      ).not.toBeDisabled();
    });
    expect(screen.queryByLabelText('Subject')).not.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);
    await screen.findByRole('button', { name: 'Save Drafts' });
    commit = storage.native.commitDrafts;
    await press('Save Drafts');
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: 'Save Drafts' }),
      ).not.toBeOnTheScreen();
    });
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toStrictEqual([]);
  });

  it('translates selected Draft text and applies it only after review as one undoable edit', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const asked: Array<{
      request: string;
      input: string;
      answer: ReturnType<typeof deferred>;
    }> = [];
    const cancelled: string[] = [];
    const translation: NativeTranslation = {
      translationLanguages: () =>
        Promise.resolve([
          { code: 'en', name: 'English' },
          { code: 'de', name: 'German' },
        ]),
      translate: (request, input) => {
        const answer = deferred();
        asked.push({ request, input, answer });
        return answer.promise;
      },
      cancel: (request) => {
        cancelled.push(request);
        return Promise.resolve(null);
      },
    };
    await render(
      <TranslationContext value={translation}>
        <App
          drafts={createDrafts(storage.native, registration)}
          registration={registration}
        />
      </TranslationContext>,
    );
    await press('New Message');
    await fireEvent.changeText(
      screen.getByLabelText('To'),
      'maya@example.com, ',
    );
    const recipient = screen.getByRole('button', {
      name: 'To: maya@example.com',
    });
    const body = screen.getByLabelText('Message body');
    await fireEvent.changeText(body, 'Hola. Nos vemos el viernes.');
    // Only selected text can be translated.
    expect(
      screen.getByRole('button', { name: 'Translate the selected text' }),
    ).toBeDisabled();
    const select = async (start: number, end: number) => {
      await fireEvent(
        screen.getByLabelText('Message body'),
        'selectionChange',
        {
          nativeEvent: { selection: { start, end } },
        },
      );
    };
    const translateSelection = async () => {
      await press('Translate the selected text');
      await fireEvent.press(
        await screen.findByRole('radio', { name: 'Translate into English' }),
      );
    };
    await select(6, 27);
    await translateSelection();
    expect(asked[0]?.input).toBe('Nos vemos el viernes.');
    asked[0]?.answer.resolve({ source: 'es', text: 'See you on Friday.' });
    await screen.findByText('See you on Friday.');
    // The Draft is unchanged until the translation is applied.
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. Nos vemos el viernes.',
      { exact: true },
    );
    await press('Replace the selected text with this translation');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. See you on Friday.',
      { exact: true },
    );
    expect(
      screen.queryByLabelText('Translation of the selected text'),
    ).toBeNull();
    expect(recipient).toBeOnTheScreen();
    // One Undo restores the original selection text.
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. Nos vemos el viernes.',
      { exact: true },
    );

    // Keeping the original changes nothing.
    await select(0, 5);
    await translateSelection();
    asked[1]?.answer.resolve({ source: 'es', text: 'Hello.' });
    await screen.findByText('Hello.');
    // Capture the actual handler as native input queued before React removes the control.
    const dismissedReplace = queuedPress(
      'Replace the selected text with this translation',
    );
    const keepOriginal = queuedPress(
      'Keep the original text and close the translation',
    );
    await act(() => {
      keepOriginal();
      dismissedReplace();
    });
    expect(screen.queryByText('Hello.')).toBeNull();
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. Nos vemos el viernes.',
      { exact: true },
    );

    // Changing the target invalidates the ready result before React removes its Replace button.
    await translateSelection();
    asked[2]?.answer.resolve({ source: 'es', text: 'Hello.' });
    await screen.findByText('Hello.');
    const supersededReplace = queuedPress(
      'Replace the selected text with this translation',
    );
    const chooseGerman = queuedPress('Translate into German');
    await act(() => {
      chooseGerman();
      supersededReplace();
    });
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. Nos vemos el viernes.',
      { exact: true },
    );
    asked[3]?.answer.resolve({ source: 'es', text: 'Hallo.' });
    await screen.findByText('Hallo.');
    const editedReplace = queuedPress(
      'Replace the selected text with this translation',
    );
    const undoEdit = queuedPress('Undo');
    const editBody = queuedPress('Message body', 'onChangeText');
    await act(() => {
      editBody('Hola! Nos vemos el viernes.');
      undoEdit();
      editedReplace();
    });
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola. Nos vemos el viernes.',
      { exact: true },
    );
    expect(
      screen.queryByLabelText('Translation of the selected text'),
    ).toBeNull();

    // Editing the Draft while a translation is pending makes it stale: it is cancelled and its
    // late result is never offered.
    await translateSelection();
    await screen.findByLabelText('Cancel translation');
    await fireEvent.changeText(
      screen.getByLabelText('Message body'),
      'Hola! Nos vemos el viernes.',
    );
    expect(
      screen.queryByLabelText('Translation of the selected text'),
    ).toBeNull();
    expect(cancelled).toStrictEqual([asked[4]?.request]);
    asked[4]?.answer.resolve({ source: 'es', text: 'Hello!' });
    await expect(
      screen.findByLabelText('Translate the selected text'),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByText('Hello!')).toBeNull();
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hola! Nos vemos el viernes.',
      { exact: true },
    );

    // The selection's boundary whitespace survives, though the preview trims the translation.
    await select(0, 6);
    await translateSelection();
    expect(asked[5]?.input).toBe('Hola! ');
    asked[5]?.answer.resolve({ source: 'es', text: 'Hello! ' });
    await screen.findByText('Hello!');
    await press('Replace the selected text with this translation');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hello! Nos vemos el viernes.',
      { exact: true },
    );
  });

  it('rewrites the body or a selection and applies it only after review as one undoable edit', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const { native, asked, cancelled } = scriptedDraftAssistance();
    await render(
      <AssistanceContext value={native}>
        <App
          drafts={createDrafts(storage.native, registration)}
          registration={registration}
        />
      </AssistanceContext>,
    );
    await press('New Message');
    await fireEvent.changeText(
      screen.getByLabelText('To'),
      'maya@example.com, ',
    );
    const recipient = screen.getByRole('button', {
      name: 'To: maya@example.com',
    });
    // Nothing to rewrite in an empty body.
    expect(
      screen.getByRole('button', { name: 'Rewrite the message body' }),
    ).toBeDisabled();
    const original = 'lets meet friday. thanks';
    await fireEvent.changeText(screen.getByLabelText('Message body'), original);
    const body = () => screen.getByLabelText('Message body');

    // With nothing selected, the whole authored body is rewritten.
    await press('Rewrite the message body');
    expect(asked[0]).toMatchObject({ operation: 'rewrite', input: original });
    await screen.findByLabelText('Cancel writing help');
    asked[0]?.answer.resolve('Let us meet on Friday. Thanks!');
    await screen.findByText('Let us meet on Friday. Thanks!');
    // The Draft is unchanged until the result is applied.
    expect(body()).toHaveTextContent(original, { exact: true });
    await press('Replace your text with this rewrite');
    expect(body()).toHaveTextContent('Let us meet on Friday. Thanks!', {
      exact: true,
    });
    expect(screen.queryByLabelText('Rewrite of your text')).toBeNull();
    expect(recipient).toBeOnTheScreen();
    // One Undo restores the original text.
    await press('Undo');
    expect(body()).toHaveTextContent(original, { exact: true });

    // A selection is rewritten alone; keeping the original changes nothing.
    await fireEvent(body(), 'selectionChange', {
      nativeEvent: { selection: { start: 0, end: 17 } },
    });
    await press('Rewrite the selected text');
    expect(asked[1]?.input).toBe('lets meet friday.');
    asked[1]?.answer.resolve('Shall we meet on Friday?');
    await screen.findByText('Shall we meet on Friday?');
    const replace = queuedPress('Replace your text with this rewrite');
    const keep = queuedPress('Keep your text and close this suggestion');
    await act(() => {
      keep();
      replace();
    });
    expect(screen.queryByText('Shall we meet on Friday?')).toBeNull();
    expect(body()).toHaveTextContent(original, { exact: true });

    // A refusal leaves the text unchanged and offers no retry.
    await press('Rewrite the selected text');
    await act(async () => {
      asked[2]?.answer.reject(
        Object.assign(new Error('refused'), { code: 'refused' }),
      );
      await asked[2]?.answer.promise.catch(() => undefined);
    });
    await screen.findByText(
      'This request cannot be answered. Your text is unchanged.',
    );
    expect(screen.queryByLabelText('Try writing help again')).toBeNull();
    await press('Keep your text and close this suggestion');

    // Cancelling stops the native request; Try again asks once more.
    await press('Rewrite the selected text');
    await press('Cancel writing help');
    expect(cancelled).toStrictEqual([asked[3]?.request]);
    await screen.findByText('Cancelled. Your text is unchanged.');
    await press('Try writing help again');
    expect(asked).toHaveLength(5);

    // Editing the Draft while a rewrite is pending makes it stale: it is cancelled and its late
    // result is never offered.
    await fireEvent.changeText(body(), 'lets meet saturday. thanks');
    expect(screen.queryByLabelText('Rewrite of your text')).toBeNull();
    expect(cancelled).toStrictEqual([asked[3]?.request, asked[4]?.request]);
    asked[4]?.answer.resolve('Too late.');
    await expect(
      screen.findByRole('button', { name: 'Rewrite the selected text' }),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByText('Too late.')).toBeNull();
    expect(body()).toHaveTextContent('lets meet saturday. thanks', {
      exact: true,
    });

    // Account replacement retires the composer and its pending assistance, even with the same mailbox.
    await press('Rewrite the selected text');
    const oldRewrite = queuedPress('Rewrite the selected text');
    await act(() => {
      registration.change({
        ...connected(['alex@example.invalid']),
        productAccountId: 'replacement-product-account',
      });
    });
    await act(() => {
      oldRewrite();
    });
    asked[5]?.answer.resolve('Late for the old account.');
    await act(async () => {
      await asked[5]?.answer.promise;
    });
    expect(screen.queryByLabelText('Message body')).toBeNull();
    expect(screen.queryByText('Late for the old account.')).toBeNull();
    expect(asked).toHaveLength(6);
    expect(cancelled).toStrictEqual([
      asked[3]?.request,
      asked[4]?.request,
      asked[5]?.request,
    ]);
  });
  /* oxlint-enable vitest/max-expects */
});

// The reader and composer of one window, with a Downloaded Attachment to attach.
function ReaderApp({
  registration,
  drafts,
  gmail,
  message,
  senders,
}: {
  readonly registration: ReturnType<typeof account>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly gmail: ReturnType<typeof createSyntheticGmail>;
  readonly message: string;
  readonly senders?: ReturnType<typeof mailboxesOf>;
}) {
  const { snapshot } = useSyncExternalStore(
    registration.subscribe,
    registration.getSnapshot,
  );
  const mailboxes = useMemo(
    () =>
      createMailboxes(syntheticConnections({ [alex]: gmail }), registration),
    [gmail, registration],
  );
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: senders ?? mailboxesOf(snapshot),
        openAccount: ignore,
        authorizeGmail: () => Promise.resolve(),
        refreshInbox: (load) => load(),
      }}>
      <InboxProvider
        drafts={drafts}
        mailboxes={mailboxes}>
        <Inbox
          composing={composing}
          onCompose={setComposing}
          onSelect={ignore}
          selected={undefined}
        />
        {composing === undefined ? (
          <View testID="message-reader">
            <MessageDetail
              id={message}
              mailbox={alex}
              onCompose={setComposing}
            />
          </View>
        ) : (
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

describe('adding files and images to a Draft', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one asset path end to end. */
  it('refuses image-containing translations and preserves assets when translating surrounding text', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const inputs: string[] = [];
    const answers = new Map([
      ['Hola', 'Hello'],
      ['mundo', 'world'],
    ]);
    const translation: NativeTranslation = {
      translationLanguages: () =>
        Promise.resolve([{ code: 'en', name: 'English' }]),
      translate: (_request, input) => {
        inputs.push(input);
        return Promise.resolve({
          source: 'es',
          text: answers.get(input),
        });
      },
      cancel: () => Promise.resolve(null),
    };
    const app = await render(
      <TranslationContext value={translation}>
        <App
          drafts={drafts}
          registration={registration}
        />
      </TranslationContext>,
    );
    await press('New Message');
    await fireEvent.changeText(
      screen.getByLabelText('Message body'),
      'Hola mundo',
    );
    const select = async (start: number, end: number) => {
      await fireEvent(
        screen.getByLabelText('Message body'),
        'selectionChange',
        {
          nativeEvent: { selection: { start, end } },
        },
      );
    };
    await select(5, 5);
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image');
    await screen.findByLabelText('Inline image chart.png');
    await waitFor(() => {
      const [current] = draftsOf(drafts.getSnapshot());
      ok(current, 'Expected the current Draft');
      expect(imagesOf(current.body)[0]?.state).toBe('complete');
      expect(drafts.getSnapshot()).toMatchObject({
        kind: 'ready',
        save: 'saved',
      });
    });
    const [before] = draftsOf(drafts.getSnapshot());
    ok(before, 'Expected a Draft with an image');
    const originalImages = imagesOf(before.body);
    const guidance =
      'Select text without inline images to translate. Your images are unchanged.';
    // Neither a mixed selection nor an image alone starts a native request or changes the Draft.
    for (const [start, end] of [
      [0, 11],
      [5, 6],
    ] as const) {
      await select(start, end);
      await press('Translate the selected text');
      await screen.findByText(guidance);
      expect(
        screen.queryByRole('radio', { name: 'Translate into English' }),
      ).toBeNull();
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual(
        before.body,
      );
      await press('Keep the original text and close the translation');
    }
    expect(inputs).toStrictEqual([]);
    // Text entirely before and after the image still translates and keeps its reference.
    for (const [start, end] of [
      [0, 4],
      [7, 12],
    ] as const) {
      await select(start, end);
      await press('Translate the selected text');
      await fireEvent.press(
        await screen.findByRole('radio', { name: 'Translate into English' }),
      );
      await screen.findByLabelText(
        'Replace the selected text with this translation',
      );
      await press('Replace the selected text with this translation');
    }
    expect(inputs).toStrictEqual(['Hola', 'mundo']);
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hello \uFFFCworld',
      { exact: true },
    );
    const [translated] = draftsOf(drafts.getSnapshot());
    ok(translated, 'Expected the translated Draft');
    expect(imagesOf(translated.body)).toStrictEqual(originalImages);
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Hello \uFFFCmundo',
      { exact: true },
    );
    await press('Redo');
    await press('Close');
    await app.unmount();
    storage.relaunch();
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const [saved] = draftsOf(reopened.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    expect(imagesOf(saved.body)).toStrictEqual(originalImages);
    const [image] = imagesOf(saved.body);
    ok(image?.state === 'complete', 'Expected the complete saved inline image');
    await expect(reopened.readAsset(image)).resolves.toMatchObject({
      kind: 'ready',
    });
  });

  it('attaches files, places an inline image, and keeps them through relaunch', async () => {
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
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Files');
    const body = screen.getByLabelText('Message body');
    await fireEvent.changeText(body, 'See chart');
    await fireEvent(body, 'selectionChange', {
      nativeEvent: { selection: { start: 4, end: 4 } },
    });

    // A file from the Files picker is attached; a photo inserted inline goes at the caret.
    storage.addFile('file:///plan.pdf', 'plan');
    storage.pickNext('files', [
      { uri: 'file:///plan.pdf', name: 'plan.pdf', type: 'application/pdf' },
    ]);
    await press('Attach File');
    await expect(
      screen.findByLabelText('plan.pdf, 4 bytes'),
    ).resolves.toBeOnTheScreen();
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image');
    await expect(
      screen.findByLabelText('Inline image chart.png'),
    ).resolves.toHaveProp('source', {
      uri: `data:image/png;base64,${btoa('chart')}`,
    });
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'See ￼chart',
    );
    // Dismissing a picker adds nothing.
    await press('Attach Photo');
    expect(screen.queryByText('Not added', { exact: false })).toBeNull();

    // An import in progress can be cancelled; a cancelled file is never sent and its bytes go.
    storage.holdImports();
    storage.addFile('file:///large.mov', 'movie');
    storage.pickNext('files', [
      { uri: 'file:///large.mov', name: 'large.mov', type: 'video/quicktime' },
    ]);
    await press('Attach File');
    await press('Cancel adding large.mov');
    await act(async () => {
      storage.releaseImports();
      await drafts.save();
    });
    expect(
      screen.getByLabelText('large.mov, Not added: cancelled'),
    ).toBeOnTheScreen();
    expect(
      screen.getByText(
        'Files that were not added are not sent with this Draft. Remove them and add them again.',
      ),
    ).toBeOnTheScreen();
    expect(storage.assets()).toHaveLength(2);
    await press('Remove large.mov');
    expect(
      screen.queryByText('Files that were not added', { exact: false }),
    ).toBeNull();

    // Editing while an import completes neither loses the edit nor creates a conflicting copy.
    storage.holdImports();
    storage.addFile('file:///notes.txt', 'notes');
    storage.pickNext('files', [
      { uri: 'file:///notes.txt', name: 'notes.txt', type: 'text/plain' },
    ]);
    await press('Attach File');
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Files and notes',
    );
    await act(async () => {
      storage.releaseImports();
      await drafts.save();
    });
    await expect(
      screen.findByLabelText('notes.txt, 5 bytes'),
    ).resolves.toBeOnTheScreen();
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Files, notes',
    );
    await waitFor(() => {
      expect(
        screen.getByText('Draft · Saved on this device'),
      ).toBeOnTheScreen();
    });
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    expect(screen.queryByText('DRAFT · CONFLICT')).toBeNull();

    // An import the app quits during is shown as interrupted after relaunch.
    storage.holdImports();
    storage.addFile('file:///late.txt', 'late');
    storage.pickNext('files', [
      { uri: 'file:///late.txt', name: 'late.txt', type: 'text/plain' },
    ]);
    await press('Attach File');
    await press('Close');
    await first.unmount();
    storage.relaunch();
    const [saved] = draftsOf(drafts.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        initialDraft={saved.id}
        registration={registration}
      />,
    );
    await expect(
      screen.findByLabelText('late.txt, Not added: adding was interrupted'),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByLabelText('plan.pdf, 4 bytes')).toBeOnTheScreen();
    expect(screen.getByLabelText('notes.txt, 5 bytes')).toBeOnTheScreen();
    await expect(
      screen.findByLabelText('Inline image chart.png'),
    ).resolves.toBeOnTheScreen();
    expect(
      screen.queryByRole('button', { name: 'Cancel adding late.txt' }),
    ).toBeNull();
  });

  it('keeps verified inline bytes without a thumbnail available after reopening', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const read = jest
      .spyOn(storage.native, 'readDraftAsset')
      .mockResolvedValue({ uri: null });
    const drafts = createDrafts(storage.native, registration);
    const first = await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image');
    await screen.findByLabelText('chart.png, 5 bytes');
    await press('Close');
    await first.unmount();
    const [saved] = draftsOf(drafts.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        initialDraft={saved.id}
        registration={registration}
      />,
    );
    await expect(
      screen.findByLabelText('chart.png, 5 bytes'),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByLabelText('Inline image chart.png')).toBeNull();
    expect(imagesOf(saved.body)[0]?.state).toBe('complete');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('￼');
    read.mockRestore();
  });

  it('shows damaged image bytes as unavailable and removes an inline image', async () => {
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
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('paste', [
      { uri: 'file:///chart.png', name: 'Pasted image.png', type: 'image/png' },
    ]);
    await press('Paste Image');
    await screen.findByLabelText('Inline image Pasted image.png');
    storage.addFile('file:///brief.txt', 'brief');
    storage.pickNext('files', [
      { uri: 'file:///brief.txt', name: 'brief.txt', type: 'text/plain' },
    ]);
    await press('Attach File');
    await screen.findByLabelText('brief.txt, 5 bytes');
    await press('Close');
    await first.unmount();
    const [saved] = draftsOf(drafts.getSnapshot());
    ok(saved, 'Expected the saved Draft');
    const [image] = imagesOf(saved.body);
    ok(image, 'Expected an inline image');
    storage.damage(image.id);
    // An ordinary attachment is verified too, without its bytes being shown.
    ok(saved.attachments, 'Expected attachments');
    const [attachment] = saved.attachments;
    ok(attachment, 'Expected an attachment');
    storage.damage(attachment.id);
    // Checks refused while storage is locked say so, and run again when asked.
    storage.setLocked(true);
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    await render(
      <App
        drafts={createDrafts(storage.native, registration)}
        initialDraft={saved.id}
        registration={registration}
      />,
    );
    await expect(
      screen.findByLabelText(
        'brief.txt, 5 bytes · Not checked while private storage is locked',
      ),
    ).resolves.toBeOnTheScreen();
    await screen.findByLabelText(
      'Pasted image.png, 5 bytes · Not checked while private storage is locked',
    );
    storage.setLocked(false);
    await press('Check brief.txt again');
    await expect(
      screen.findByLabelText('brief.txt, 5 bytes · Damaged on this device'),
    ).resolves.toBeOnTheScreen();
    // A foreground activation retries the image without pressing its retry control.
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByLabelText(
        'Pasted image.png, 5 bytes · Damaged on this device',
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByLabelText('Inline image Pasted image.png')).toBeNull();
    await expect(
      screen.findByLabelText('brief.txt, 5 bytes · Damaged on this device'),
    ).resolves.toBeOnTheScreen();
    await press('Remove Pasted image.png');
    expect(screen.getByLabelText('Message body')).not.toHaveTextContent('￼');
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('￼');
  });

  it('offers attaching a downloaded file only while a sending mailbox is available', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      content: {
        text: 'Invoice attached.',
        attachments: [
          {
            filename: 'invoice.pdf',
            mimeType: 'application/pdf',
            bytes: [...Buffer.from('%PDF invoice')],
          },
        ],
      },
    });
    const drafts = createDrafts(storage.native, registration);
    const shown = (senders: ReturnType<typeof mailboxesOf>) => (
      <ReaderApp
        drafts={drafts}
        gmail={gmail}
        message={message}
        registration={registration}
        senders={senders}
      />
    );
    // Keep the downloaded reader alive while changing the host's sending eligibility.
    const senders = mailboxesOf(registration.getSnapshot().snapshot);
    await render(shown(senders));
    await press('Download invoice.pdf');
    await expect(
      screen.findByRole('button', {
        name: 'Attach invoice.pdf to a new message',
      }),
    ).resolves.toBeOnTheScreen();
    await screen.rerender(
      shown(senders.map((mailbox) => ({ ...mailbox, state: 'authorization' }))),
    );
    expect(
      screen.queryByRole('button', {
        name: 'Attach invoice.pdf to a new message',
      }),
    ).not.toBeOnTheScreen();
    expect(
      screen.getByRole('button', { name: 'Open invoice.pdf' }),
    ).toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(0);
    await screen.rerender(shown(senders));
    await expect(
      screen.findByRole('button', {
        name: 'Attach invoice.pdf to a new message',
      }),
    ).resolves.toBeOnTheScreen();
  });

  it.each(['locked', 'failed'])(
    'keeps unavailable %s Draft storage retryable in the reader',
    async (failure) => {
      expect.hasAssertions();
      const registration = account(connected(['alex@example.invalid']));
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const gmail = createSyntheticGmail({ messages: 0 });
      const message = gmail.deliver({
        content: {
          text: 'Invoice attached.',
          attachments: [
            {
              filename: 'invoice.pdf',
              mimeType: 'application/pdf',
              bytes: [...Buffer.from('%PDF invoice')],
            },
          ],
        },
      });
      let open: typeof storage.native.openDrafts = () =>
        Promise.reject(
          Object.assign(new Error('synthetic storage refusal'), {
            code: failure,
          }),
        );
      const drafts = createDrafts(
        {
          ...storage.native,
          openDrafts: () => open(),
          importDraftAsset: async (owner, id, source) => {
            // oxlint-disable-next-line vitest/no-conditional-in-test -- Only received sources read a download.
            if (source.kind === 'received') {
              const downloaded = gmail.savedFiles.get(source.file);
              ok(downloaded, 'Expected the Downloaded Attachment');
              storage.addFile(
                source.file,
                Buffer.from(downloaded.bytes).toString('latin1'),
              );
            }
            return storage.native.importDraftAsset(owner, id, source);
          },
        },
        registration,
      );
      await render(
        <ReaderApp
          drafts={drafts}
          gmail={gmail}
          message={message}
          registration={registration}
        />,
      );
      await press('Download invoice.pdf');
      const reader = within(screen.getByTestId('message-reader'));
      await expect(reader.findByRole('alert')).resolves.toBeOnTheScreen();
      expect(drafts.getSnapshot()).toMatchObject({ kind: failure });
      expect(
        reader.queryByRole('button', {
          name: 'Attach invoice.pdf to a new message',
        }),
      ).not.toBeOnTheScreen();
      expect(
        reader.getByRole('button', { name: 'Open invoice.pdf' }),
      ).toBeOnTheScreen();
      open = storage.native.openDrafts;
      await act(async () => {
        await fireEvent.press(
          reader.getByRole('button', { name: 'Try again' }),
        );
      });
      await press('Attach invoice.pdf to a new message');
      await expect(
        screen.findByLabelText('invoice.pdf, 12 bytes'),
      ).resolves.toBeOnTheScreen();
      expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
      expect(drafts.getSnapshot()).toMatchObject({
        kind: 'ready',
        save: 'saved',
      });
      expect(storage.stored()?.document).toContain('invoice.pdf');
    },
  );

  it('says so when attaching a received attachment fails unexpectedly', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      content: {
        text: 'Invoice attached.',
        attachments: [
          {
            filename: 'invoice.pdf',
            mimeType: 'application/pdf',
            bytes: [...Buffer.from('%PDF invoice')],
          },
        ],
      },
    });
    const drafts = createDrafts(storage.native, registration);
    // Fault injection for the defensive catch; native storage refusal is covered separately.
    const failing = {
      ...drafts,
      create: () => Promise.reject(new Error('host failure')),
    };
    await render(
      <ReaderApp
        drafts={failing}
        gmail={gmail}
        message={message}
        registration={registration}
      />,
    );
    await press('Download invoice.pdf');
    await press('Attach invoice.pdf to a new message');
    await expect(
      screen.findByRole('alert', {
        name: 'This attachment could not be added to a new message. Try again.',
      }),
    ).resolves.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(0);
  });

  it('attaches a received attachment to a new message without keeping its mailbox', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      content: {
        text: 'Invoice attached.',
        attachments: [
          {
            filename: 'invoice.pdf',
            mimeType: 'application/pdf',
            bytes: [...Buffer.from('%PDF invoice')],
          },
        ],
      },
    });
    const copied: string[] = [];
    const drafts = createDrafts(
      {
        ...storage.native,
        // The Downloaded Attachment's file, as native code reads it for the current generation.
        importDraftAsset: async (owner, id, source) => {
          // oxlint-disable-next-line vitest/no-conditional-in-test -- Only received sources read a download.
          if (source.kind === 'received') {
            const downloaded = gmail.savedFiles.get(source.file);
            ok(downloaded, 'Expected the Downloaded Attachment');
            copied.push(source.file);
            storage.addFile(
              source.file,
              Buffer.from(downloaded.bytes).toString('latin1'),
            );
          }
          return storage.native.importDraftAsset(owner, id, source);
        },
      },
      registration,
    );
    await render(
      <ReaderApp
        drafts={drafts}
        gmail={gmail}
        message={message}
        registration={registration}
      />,
    );
    await press('Download invoice.pdf');
    // Storage refusing the save still opens the one Draft that holds the attachment.
    storage.setLocked(true);
    await press('Attach invoice.pdf to a new message');
    await expect(
      screen.findByLabelText(
        'invoice.pdf, 12 bytes · Not checked while private storage is locked',
      ),
    ).resolves.toBeOnTheScreen();
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    expect(drafts.getSnapshot()).toMatchObject({ save: 'locked' });
    storage.setLocked(false);
    await act(async () => {
      await drafts.save();
    });
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    const document = storage.stored()?.document;
    ok(document, 'Expected a stored Draft document');
    expect(document).toContain('invoice.pdf');
    // Neither the downloaded file nor the mailbox it was read through is kept.
    expect(copied).toHaveLength(1);
    expect(document).not.toContain(copied[0]);
    expect(document).not.toMatch(/"(?:generation|mailbox|file)"/u);
    // Leaving the reader deleted its download; the Draft keeps its own copy of the bytes.
    expect(gmail.savedFiles.size).toBe(0);
    expect(storage.assets()).toHaveLength(1);
  });

  it('keeps an attachment-only Draft after Close and relaunch', async () => {
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
    storage.addFile('file:///plan.pdf', 'plan');
    storage.pickNext('files', [
      { uri: 'file:///plan.pdf', name: 'plan.pdf', type: 'application/pdf' },
    ]);
    await press('Attach File');
    await screen.findByLabelText('plan.pdf, 4 bytes');
    await press('Close');
    await first.unmount();
    const [saved] = draftsOf(drafts.getSnapshot());
    ok(saved, 'Expected the attachment-only Draft');
    const reopened = createDrafts(storage.native, registration);
    await render(
      <App
        drafts={reopened}
        initialDraft={saved.id}
        registration={registration}
      />,
    );
    await screen.findByLabelText('plan.pdf, 4 bytes');
    expect(storage.assets()).toHaveLength(1);
  });

  it('restores verified image bytes with Undo after deleting an importing image', async () => {
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
    storage.holdImports();
    storage.addFile('file:///chart.png', 'chart');
    storage.pickNext('photos', [
      { uri: 'file:///chart.png', name: 'chart.png', type: 'image/png' },
    ]);
    await press('Insert Image');
    await screen.findByLabelText('chart.png, Adding…');
    await fireEvent.changeText(screen.getByLabelText('Message body'), '');
    await act(async () => {
      storage.releaseImports();
    });
    await waitFor(() => {
      expect(drafts.getImports().size).toBe(0);
    });
    await press('Undo');
    await expect(
      screen.findByLabelText('Inline image chart.png'),
    ).resolves.toHaveProp('source', {
      uri: `data:image/png;base64,${btoa('chart')}`,
    });
    expect(storage.assets()).toHaveLength(1);
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
  });

  it('discards a picker result when its composer closed while choosing', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const { promise: picked, resolve: finish } =
      Promise.withResolvers<
        ReadonlyArray<{ uri: string; name: string; type: string }>
      >();
    const drafts = createDrafts(
      { ...storage.native, pickDraftFiles: () => picked },
      registration,
    );
    await render(
      <App
        drafts={drafts}
        registration={registration}
      />,
    );
    await press('New Message');
    await press('Attach File');
    await press('Close');
    storage.addFile('file:///late.pdf', 'late');
    await act(async () => {
      finish([
        { uri: 'file:///late.pdf', name: 'late.pdf', type: 'application/pdf' },
      ]);
      await picked;
    });
    await act(async () => {
      await drafts.save();
    });
    expect(draftsOf(drafts.getSnapshot())).toStrictEqual([]);
    expect(storage.assets()).toStrictEqual([]);
    expect(screen.queryByLabelText('Subject')).toBeNull();
  });
  /* oxlint-enable vitest/max-expects */
});

describe('replying to and forwarding from the reader', () => {
  /* oxlint-disable vitest/max-expects -- One journey from the reader through the composer. */
  it('opens Reply All in the composer with quoted text kept apart, and edits it without sending', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      subject: 'Plans',
      content: { text: 'Shall we meet on Friday?' },
      headers: {
        To: 'alex@example.invalid, Bob <bob@example.invalid>',
        Cc: 'carol@example.invalid',
        'Message-ID': '<plans@example.invalid>',
      },
    });
    const drafts = createDrafts(storage.native, registration);
    await render(
      <ReaderApp
        drafts={drafts}
        gmail={gmail}
        message={message}
        registration={registration}
      />,
    );
    await press('Reply All');
    await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
      'value',
      'Re: Plans',
    );
    const [draft] = draftsOf(drafts.getSnapshot());
    expect(draft).toMatchObject({
      connection: alex,
      from: 'alex@example.invalid',
      to: [
        { name: 'Maya Chen', address: 'maya@example.invalid' },
        { name: 'Bob', address: 'bob@example.invalid' },
      ],
      cc: [{ address: 'carol@example.invalid' }],
      response: { kind: 'replyAll', inReplyTo: '<plans@example.invalid>' },
    });
    // Reply All reveals its populated Cc; the quoted text stays out of the editable body.
    expect(screen.getByLabelText('Cc')).toBeOnTheScreen();
    expect(screen.getByLabelText('Message body')).toHaveTextContent('');
    expect(screen.queryByText(/Shall we meet/u)).not.toBeOnTheScreen();
    await press('Show quoted text');
    expect(screen.getByText(/Shall we meet on Friday\?/u)).toBeOnTheScreen();

    await fireEvent.changeText(screen.getByLabelText('Message body'), 'Yes!');
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('');
    await press('Redo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('Yes!');
    await press('Hide quoted text');
    expect(screen.queryByText(/Shall we meet/u)).not.toBeOnTheScreen();
    await press('Close');
    // Closing keeps the reply as a Draft; nothing was sent.
    await waitFor(() => {
      expect(storage.stored()?.document).toContain('Yes!');
    });
    expect(draftsOf(drafts.getSnapshot())[0]?.quoted).toStrictEqual(
      draft?.quoted,
    );
  });

  it('suggests a reply from local context and applies it only to the authored body', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      subject: 'Plans',
      content: { text: 'Shall we meet on Friday?' },
      headers: {
        To: 'alex@example.invalid, Bob <bob@example.invalid>',
        Cc: 'carol@example.invalid',
        'Message-ID': '<plans@example.invalid>',
      },
    });
    const drafts = createDrafts(storage.native, registration);
    const { native, asked, cancelled } = scriptedDraftAssistance();
    await render(
      <AssistanceContext value={native}>
        <ReaderApp
          drafts={drafts}
          gmail={gmail}
          message={message}
          registration={registration}
        />
      </AssistanceContext>,
    );
    await press('Reply All');
    await screen.findByLabelText('Subject');
    const [draft] = draftsOf(drafts.getSnapshot());
    const requests = gmail.requests.length;
    await fireEvent.changeText(screen.getByLabelText('Message body'), 'Yes');
    await press('Suggest a reply to the quoted message');
    // Only display names, the authored text and the quoted message already in the Draft are read.
    expect(asked[0]?.operation).toBe('reply');
    expect(asked[0]?.input).toContain(
      'Recipients: Maya Chen, Bob\n\nReply so far:\nYes\n\nMessage being answered:\n',
    );
    expect(asked[0]?.input).toContain('Shall we meet on Friday?');
    // Recipient addresses are never admitted; the quoted attribution line is message text.
    expect(asked[0]?.input).not.toMatch(/bob@|carol@/u);
    expect(gmail.requests).toHaveLength(requests);
    asked[0]?.answer.resolve('Yes, Friday works. See you then.');
    await screen.findByText('Yes, Friday works. See you then.');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('Yes', {
      exact: true,
    });
    await press('Replace your reply with this suggestion');
    expect(screen.getByLabelText('Message body')).toHaveTextContent(
      'Yes, Friday works. See you then.',
      { exact: true },
    );
    await waitFor(() => {
      expect(storage.stored()?.document).toContain('See you then.');
    });
    // Recipients, sender, quoted text and threading are unchanged, and nothing was sent.
    const [applied] = draftsOf(drafts.getSnapshot());
    expect(applied).toMatchObject({
      from: draft?.from,
      to: draft?.to,
      cc: draft?.cc,
      bcc: draft?.bcc,
      quoted: draft?.quoted,
      response: draft?.response,
    });
    expect(gmail.requests).toHaveLength(requests);
    await press('Undo');
    expect(screen.getByLabelText('Message body')).toHaveTextContent('Yes', {
      exact: true,
    });

    // Recipient edits retire the captured reply input even when Undo restores it before commit.
    await press('Suggest a reply to the quoted message');
    asked[1]?.answer.resolve('Ready for the old recipients.');
    await screen.findByText('Ready for the old recipients.');
    const apply = queuedPress('Replace your reply with this suggestion');
    const removeBob = queuedPress('To: Bob <bob@example.invalid>');
    const undo = queuedPress('Undo');
    await act(() => {
      removeBob();
      undo();
      apply();
    });
    expect(screen.queryByText('Ready for the old recipients.')).toBeNull();
    expect(screen.getByLabelText('Message body')).toHaveTextContent('Yes', {
      exact: true,
    });

    // A pending request is also cancelled on recipient editing; its late result stays hidden.
    await press('Suggest a reply to the quoted message');
    await press('To: Bob <bob@example.invalid>');
    asked[2]?.answer.resolve('Late for the old recipients.');
    await act(async () => {
      await asked[2]?.answer.promise;
    });
    expect(screen.queryByLabelText('Suggested reply')).toBeNull();
    expect(screen.queryByText('Late for the old recipients.')).toBeNull();
    expect(cancelled).toStrictEqual([asked[2]?.request]);
    await press('Undo');

    // Closing the Draft while a suggestion is pending cancels it.
    await press('Suggest a reply to the quoted message');
    await screen.findByLabelText('Cancel writing help');
    await press('Close');
    await waitFor(() => {
      expect(cancelled).toStrictEqual([asked[2]?.request, asked[3]?.request]);
    });
  });

  it('starts only the first queued response and ignores its old reader callback', async () => {
    expect.hasAssertions();
    const registration = account(connected(['alex@example.invalid']));
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const gmail = createSyntheticGmail({ messages: 0 });
    const message = gmail.deliver({
      subject: 'Plans',
      content: { text: 'Forward me.' },
    });
    const drafts = createDrafts(storage.native, registration);
    await render(
      <ReaderApp
        drafts={drafts}
        gmail={gmail}
        message={message}
        registration={registration}
      />,
    );
    await screen.findByRole('button', { name: 'Forward' });
    const forward = queuedPress('Forward');
    const reply = queuedPress('Reply');
    await act(() => {
      forward();
      reply();
      forward();
    });
    await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
      'value',
      'Fwd: Plans',
    );
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    await act(() => {
      reply();
    });
    await drafts.save();
    expect(draftsOf(drafts.getSnapshot())).toHaveLength(1);
    expect(draftsOf(drafts.getSnapshot())[0]?.response?.kind).toBe('forward');
  });
  /* oxlint-enable vitest/max-expects */
});
