import { ok } from 'node:assert/strict';

import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox } from '@private-email/mail-core/outbox';
import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync as createServer,
} from '@private-email/mail-core/testing/drafts';
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
import { useState } from 'react';

import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The Inbox's keyboard avoidance reads the inset; the host has none here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const alex = syntheticMailboxes['alex@example.invalid'];
const account = 'synthetic-product-account';
const snapshot: RegistrationSnapshot = {
  kind: 'connected',
  productAccountId: account,
  signInProvider: 'google',
  mailboxes: JSON.stringify([
    { id: alex, address: 'alex@example.invalid', state: 'connected' },
  ]),
};
const registration = {
  getSnapshot: () => ({ snapshot, busy: false, failed: false }),
  subscribe: () => () => undefined,
};

// This device's Draft storage, its Gmail mailbox and the Convex claims shared with other devices.
function device() {
  const server = createServer();
  const storage = createSyntheticDrafts(() => account, { server });
  const gmail = createSyntheticGmail({
    assets: (id, digest) => storage.bytesOf(account, id, digest),
  });
  const drafts = createDrafts(storage.native, registration);
  const mailboxes = createMailboxes(
    syntheticConnections({ [alex]: gmail }),
    registration,
  );
  const outbox = createOutbox({
    drafts,
    mailboxes,
    registration,
    claims: storage.delivery,
  });
  return { gmail, drafts, mailboxes, outbox, storage };
}

// `listed` is the account's Mailbox Connections, as after one is removed.
function App({
  sender,
  listed = mailboxesOf(snapshot),
}: {
  readonly sender: ReturnType<typeof device>;
  readonly listed?: ReturnType<typeof mailboxesOf>;
}) {
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: listed,
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
      }}>
      <InboxProvider
        drafts={sender.drafts}
        mailboxes={sender.mailboxes}
        outbox={sender.outbox}>
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

// The same composite-fiber boundary used by fireEvent, retained before disabled props commit.
const queuedPress = (label: string) => {
  let fiber = screen.getByLabelText(label).unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.onPress;
    if (typeof handler === 'function') {
      return () => {
        handler();
      };
    }
    fiber = fiber.return;
  }
  throw new Error('Expected a rendered input handler');
};

// A new message to Sam, with the recipient still being typed when Send is pressed.
const compose = async (subject: string) => {
  await press('New Message');
  await fireEvent.changeText(
    screen.getByLabelText('To'),
    'sam@example.invalid',
  );
  await fireEvent.changeText(screen.getByLabelText('Subject'), subject);
  await fireEvent.changeText(screen.getByLabelText('Message body'), 'See you');
};

// The controlled clock every journey runs on.
const clock = { now: 0 };
const later = async (
  sender: ReturnType<typeof device>,
  milliseconds: number,
) => {
  clock.now += milliseconds;
  jest.setSystemTime(clock.now);
  await act(async () => {
    await sender.outbox.process();
  });
};

describe('sending a Draft', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    // Only the clock is controlled; storage and Gmail answer as promises do.
    jest.useFakeTimers({
      doNotFake: [
        'setTimeout',
        'clearTimeout',
        'setInterval',
        'clearInterval',
        'setImmediate',
        'clearImmediate',
        'queueMicrotask',
        'nextTick',
      ],
    });
    clock.now = Date.UTC(2026, 9, 9, 12);
    jest.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    jest.useRealTimers();
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one delivery path end to end. */
  it('sends from the composer after the Undo Send Window, and Undo returns the Draft to edit', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lunch');

      await press('Send');

      // The composer closes; the message waits in the Outbox, and no Draft row remains.
      expect(screen.queryByLabelText('Subject')).toBeNull();
      expect(screen.getByRole('header', { name: 'Outbox' })).toBeOnTheScreen();
      expect(
        screen.getByLabelText('Lunch. To sam@example.invalid. Sending soon'),
      ).toBeOnTheScreen();
      expect(screen.queryByRole('header', { name: 'Drafts' })).toBeNull();
      sender.storage.hold();
      const undo = screen.getByRole('button', { name: 'Undo' });
      await act(async () => {
        await fireEvent.press(undo);
        await fireEvent.press(undo);
      });
      await act(async () => {
        sender.storage.release();
      });
      await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Lunch',
      );
      expect(sender.drafts.getSnapshot()).toMatchObject({
        kind: 'ready',
        drafts: [{ subject: 'Lunch' }],
      });
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
      await later(sender, 10_000);
      expect(sender.gmail.sends).toStrictEqual([]);

      await press('Send');
      await later(sender, 9999);
      expect(sender.gmail.sends).toStrictEqual([]);
      await later(sender, 1);

      expect(sender.gmail.sends).toHaveLength(1);
      expect(sender.gmail.sends[0]?.raw).toContain('Subject: Lunch');
      expect(sender.gmail.sends[0]?.raw).toContain('To: sam@example.invalid');
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
    } finally {
      sender.outbox.dispose();
    }
  });

  it('accepts no edits while Send is pending, then closes once the message is admitted', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lunch');
      await act(async () => {
        await sender.drafts.save();
      });
      // These callbacks were dispatched before native received the read-only props.
      const changeSubject = screen.getByLabelText('Subject').props.onChangeText;
      const changeBody =
        screen.getByLabelText('Message body').props.onChangeText;
      const changeTo = screen.getByLabelText('To').props.onChangeText;
      // Storage holds the admission, as a slow write would.
      sender.storage.hold();

      await act(async () => {
        const pressed = fireEvent.press(
          screen.getByRole('button', { name: 'Send' }),
        );
        changeSubject('Lost subject');
        changeBody('Lost body');
        changeTo('maya@example.invalid');
        await pressed;
      });

      expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Lunch');
      expect(screen.getByLabelText('Message body')).toHaveTextContent(
        'See you',
      );
      expect(
        screen.queryByRole('button', { name: 'To: maya@example.invalid' }),
      ).toBeNull();
      for (const field of ['To', 'Subject', 'Message body']) {
        expect(screen.getByLabelText(field)).toHaveProp('editable', false);
        expect(screen.getByLabelText(field)).toBeDisabled();
      }
      for (const name of [
        'Close',
        'Undo',
        'Redo',
        'Discard',
        'Send',
        'Bold',
        'Show Cc and Bcc',
      ]) {
        expect(screen.getByRole('button', { name })).toBeDisabled();
      }
      await act(async () => {
        sender.storage.release();
      });
      await waitFor(() => {
        expect(screen.queryByLabelText('Subject')).toBeNull();
      });
      expect(
        screen.getByLabelText('Lunch. To sam@example.invalid. Sending soon'),
      ).toBeOnTheScreen();
    } finally {
      sender.storage.release();
      sender.outbox.dispose();
    }
  });

  it.each([
    {
      purpose: 'rewrite',
      captureLabel: 'Rewrite the message body',
      applyLabel: 'Replace your text with this rewrite',
      region: 'Rewrite of your text',
      context: {},
    },
    {
      purpose: 'reply',
      captureLabel: 'Suggest a reply to the quoted message',
      applyLabel: 'Replace your reply with this suggestion',
      region: 'Suggested reply',
      context: {
        response: {
          kind: 'reply',
          message: 'source',
          thread: { connection: alex, id: 'thread' },
          references: [],
        },
        quoted: [{ kind: 'paragraph', spans: [{ text: 'Lunch tomorrow?' }] }],
      },
    },
  ] as const)(
    'retires $purpose assistance during Send, including queued actions, and restores it after refusal',
    async ({ captureLabel, applyLabel, region, context }) => {
      expect.hasAssertions();
      const sender = device();
      const native: NativeAssistance = {
        availability: () => Promise.resolve('available'),
        summarize: () => Promise.reject(new Error('unused')),
        rewrite: () => Promise.resolve('Reviewed text'),
        suggestReply: () => Promise.resolve('Reviewed text'),
        cancel: () => Promise.resolve(null),
      };
      try {
        await sender.drafts.load();
        await sender.mailboxes.load();
        const id = await sender.drafts.create({
          id: alex,
          address: 'alex@example.invalid',
        });
        ok(id);
        await sender.drafts.fill(
          id,
          (draft) => ({
            ...draft,
            subject: 'Lunch',
            to: [{ address: 'sam@example.invalid' }],
            body: [{ kind: 'paragraph', spans: [{ text: 'See you' }] }],
            ...context,
          }),
          [],
        );
        await render(
          <AssistanceContext value={native}>
            <App sender={sender} />
          </AssistanceContext>,
        );
        await press(
          'Draft. Lunch. To sam@example.invalid. From alex@example.invalid',
        );
        await press(captureLabel);
        await screen.findByText('Reviewed text');
        const capture = queuedPress(captureLabel);
        const apply = queuedPress(applyLabel);
        const close = queuedPress('Keep your text and close this suggestion');
        sender.storage.hold();
        sender.storage.failNextCommit('locked');
        await act(async () => {
          const pressed = fireEvent.press(
            screen.getByRole('button', { name: 'Send' }),
          );
          apply();
          close();
          capture();
          await pressed;
        });
        expect(screen.queryByLabelText(region)).toBeNull();
        expect(
          screen.getByRole('button', { name: captureLabel }),
        ).toBeDisabled();
        expect(screen.getByLabelText('Message body')).toHaveTextContent(
          'See you',
          { exact: true },
        );
        await act(async () => {
          sender.storage.release();
        });
        await screen.findByRole('alert', {
          name: 'This message could not be queued because Drafts are not saved. Try again.',
        });
        expect(
          screen.getByRole('button', { name: captureLabel }),
        ).not.toBeDisabled();
        await press(captureLabel);
        await screen.findByText('Reviewed text');
        await press(applyLabel);
        expect(screen.getByLabelText('Message body')).toHaveTextContent(
          'Reviewed text',
          { exact: true },
        );
        await press('Send');
        await waitFor(() => {
          expect(screen.queryByLabelText('Subject')).toBeNull();
        });
        expect(draftsOf(sender.drafts.getSnapshot())).toStrictEqual([]);
        await later(sender, 10_000);
        expect(sender.gmail.sends).toHaveLength(1);
        expect(sender.gmail.sends[0]?.raw).toContain('Subject: Lunch');
      } finally {
        sender.storage.release();
        sender.outbox.dispose();
      }
    },
  );

  it('restores editing after refused admission and saves the next edits', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lunch');
      await act(async () => {
        await sender.drafts.save();
      });
      await fireEvent(screen.getByLabelText('To'), 'submitEditing');
      await press('To: sam@example.invalid');
      await press('Send');
      await screen.findByRole('alert', {
        name: 'Add a recipient before sending.',
      });
      expect(screen.getByLabelText('Subject')).toHaveProp('editable', true);
      for (const field of ['To', 'Subject', 'Message body']) {
        expect(screen.getByLabelText(field)).not.toBeDisabled();
      }
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
      await fireEvent.changeText(
        screen.getByLabelText('To'),
        'sam@example.invalid',
      );
      await fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'After refusal',
      );
      await fireEvent.changeText(
        screen.getByLabelText('Message body'),
        'Kept edits',
      );
      await press('Close');
      await press(
        'Draft. After refusal. To sam@example.invalid. From alex@example.invalid',
      );
      expect(screen.getByLabelText('Subject')).toHaveProp(
        'value',
        'After refusal',
      );
      expect(screen.getByLabelText('Message body')).toHaveTextContent(
        'Kept edits',
      );
      expect(sender.storage.stored()?.document).toContain('After refusal');
    } finally {
      sender.storage.release();
      sender.outbox.dispose();
    }
  });

  it('keeps a long Outbox virtualized and hides it during received-mail search', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      const entries = Array.from({ length: 100 }, (_, index) => ({
        id: `queued${index}`,
        state: 'unknown',
        message: { segments: [{ text: 'Synthetic message' }], size: 17 },
        sendAt: clock.now,
        draft: {
          id: `queued${index}`,
          connection: alex,
          from: 'alex@example.invalid',
          to: [{ address: 'sam@example.invalid' }],
          cc: [],
          bcc: [],
          subject: `Queued ${index}`,
          body: [{ kind: 'paragraph', spans: [] }],
          updatedAt: clock.now,
        },
      }));
      await sender.storage.native.commitDrafts(account, 0, {
        document: JSON.stringify({ version: 1, drafts: [], outbox: entries }),
        keep: [],
      });
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      expect(sender.drafts.getOutbox()).toHaveLength(100);
      expect(screen.getByRole('header', { name: 'Outbox' })).toBeOnTheScreen();
      const mounted = screen.getAllByLabelText(/^Queued \d+\. To/u);
      expect(mounted.length).toBeLessThan(100);
      expect(screen.queryByLabelText(/^Queued 99\. To/u)).toBeNull();
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        'Queued',
      );
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
      expect(screen.queryAllByLabelText(/^Queued \d+\. To/u)).toStrictEqual([]);
      await fireEvent.changeText(
        screen.getByLabelText('Search senders and subjects'),
        '',
      );
      expect(screen.getByRole('header', { name: 'Outbox' })).toBeOnTheScreen();
    } finally {
      sender.outbox.dispose();
      await screen.unmount();
    }
  });

  it('explains a refused Send, a refusal by Gmail and an unknown outcome, and recovers each', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await press('New Message');

      await press('Send');

      expect(
        screen.getByRole('alert', { name: 'Add a recipient before sending.' }),
      ).toBeOnTheScreen();
      expect(screen.getByLabelText('Subject')).toBeOnTheScreen();
      await fireEvent.changeText(
        screen.getByLabelText('To'),
        'sam@example.invalid',
      );
      await fireEvent(screen.getByLabelText('To'), 'submitEditing');
      expect(
        screen.queryByRole('alert', {
          name: 'Add a recipient before sending.',
        }),
      ).toBeNull();
      await press('To: sam@example.invalid');
      await press('Send');
      expect(
        screen.getByRole('alert', { name: 'Add a recipient before sending.' }),
      ).toBeOnTheScreen();
      await press('Undo');
      expect(
        screen.getByRole('button', { name: 'To: sam@example.invalid' }),
      ).toBeOnTheScreen();
      expect(
        screen.queryByRole('alert', {
          name: 'Add a recipient before sending.',
        }),
      ).toBeNull();
      await press('Discard');
      await press('Discard Draft');
      // Gmail refuses the first, keeps the second without answering, and answers the third with
      // a server error without keeping it.
      sender.gmail.failSend(
        { status: 400, body: '{}' },
        { lost: true },
        { status: 503, body: '{}' },
      );
      await compose('Refused');
      await press('Send');
      await later(sender, 10_000);
      expect(
        screen.getByLabelText(
          'Refused. To sam@example.invalid. Not sent. Gmail refused this message.',
        ),
      ).toBeOnTheScreen();
      await press('Edit');
      expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Refused');
      await press('Discard');
      await press('Discard Draft');
      await compose('Lost');
      await press('Send');
      await compose('Unknown');
      await press('Send');
      await later(sender, 10_000);

      // Gmail's Sent mailbox confirms the lost answer, which leaves the Outbox.
      expect(screen.queryByLabelText(/^Lost\./u)).toBeNull();
      expect(
        screen.getByLabelText(
          'Unknown. To sam@example.invalid. Delivery unknown. Check Sent in Gmail before sending it again.',
        ),
      ).toBeOnTheScreen();
      await press('Check Again');
      await expect(
        screen.findByText(
          'Gmail did not confirm this message. Check Sent in Gmail.',
        ),
      ).resolves.toBeOnTheScreen();
      // A slow check must not dismiss the warning opened while it was pending.
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Holds the external Gmail read while the person opens Edit.
      const pending = new Promise<boolean>((resolve) => {
        release = () => {
          resolve(true);
        };
      });
      const request = sender.gmail.native.gmailRequest;
      sender.gmail.native.gmailRequest = async (...args) => {
        sender.gmail.native.gmailRequest = request;
        await pending;
        return request(...args);
      };
      await press('Check Again');
      // Editing the unknown message asks first, because Gmail may already have it.
      await press('Edit');
      const warning =
        'Gmail may already have sent this message. Edit it only if it is not in Sent in Gmail.';
      expect(screen.getByText(warning)).toBeOnTheScreen();
      await act(async () => {
        release();
      });
      expect(screen.getByText(warning)).toBeOnTheScreen();
      await press('Cancel');
      expect(screen.queryByText(warning)).toBeNull();
      await press('Edit');
      await press('Edit Anyway');
      expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Unknown');
      await later(sender, 60_000);
      expect(sender.gmail.sends).toHaveLength(1);
    } finally {
      sender.outbox.dispose();
    }
  });

  it('names no provider for an unknown message whose mailbox is no longer listed', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      const { rerender } = await render(<App sender={sender} />);
      sender.gmail.failSend({ status: 503, body: '{}' });
      await compose('Unknown');
      await press('Send');
      await later(sender, 10_000);
      // The mailbox is removed: nothing tells the person to look in Gmail.
      await rerender(
        <App
          listed={[]}
          sender={sender}
        />,
      );
      expect(
        screen.getByLabelText(
          'Unknown. To sam@example.invalid. Delivery unknown. Check the Sent folder of the mailbox it was sent from before sending it again.',
        ),
      ).toBeOnTheScreen();
      await press('Check Again');
      await expect(
        screen.findByText(
          'This message could not be confirmed. Check the Sent folder of the mailbox it was sent from.',
        ),
      ).resolves.toBeOnTheScreen();
      await press('Edit');
      expect(
        screen.getByText(
          'This message may already have been sent. Edit it only if it is not in the Sent folder of the mailbox it was sent from.',
        ),
      ).toBeOnTheScreen();
    } finally {
      sender.outbox.dispose();
    }
  });
});
