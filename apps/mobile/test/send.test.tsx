import { ok } from 'node:assert/strict';

import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox } from '@private-email/mail-core/outbox';
import {
  defaultProfile,
  mailboxesOf,
} from '@private-email/mail-core/registration';
import { createSendReminders } from '@private-email/mail-core/send-reminders';
import {
  createSyntheticDrafts,
  createSyntheticProductSync as createServer,
} from '@private-email/mail-core/testing/drafts';
import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { Profiler, useState } from 'react';
import { AccessibilityInfo, Alert, AppState } from 'react-native';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { remindFromSendMenu, sendMenuItem } from './send-menu.tsx';
import { choose } from './system-menu.tsx';
import {
  addFilesChoice,
  chooseWritingTool,
  writingToolChoice,
} from './writing-tools.ts';

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
  resume: () => Promise.resolve(),
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
  // Send Reminder storage on this device, which always accepts a write.
  const saved = { revision: 0, document: null as string | null };
  const reminders = createSendReminders(
    {
      openSendReminders: () => Promise.resolve({ owner: account, ...saved }),
      commitSendReminders: (owner, revision, document) => {
        Object.assign(saved, { revision: revision + 1, document });
        return Promise.resolve({ owner, revision: saved.revision });
      },
    },
    registration,
  );
  return { gmail, drafts, mailboxes, outbox, storage, reminders };
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
    <CommandPaletteProvider>
      <AccountContext
        value={{
          mailboxes: listed,
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxProvider
          drafts={sender.drafts}
          mailboxes={sender.mailboxes}
          sendReminders={sender.reminders}
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
    </CommandPaletteProvider>
  );
}

const press = async (name: string) => {
  if (
    name === 'New Message' &&
    screen.queryByRole('button', { name }) === null
  ) {
    await fireEvent(
      screen.getByRole('header', { name: 'Inbox' }),
      'accessibilityAction',
      { nativeEvent: { actionName: 'openCommandPalette' } },
    );
  }
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

  // Sets the Draft's reminder for Tomorrow Morning from Send's menu.
  const remindTomorrow = async () => {
    await remindFromSendMenu();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: /^Tomorrow Morning, /u }),
      );
    });
    await screen.findByText(/^Reminder for tomorrow/u);
  };

  it('removes the reminder of a Draft it sends', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Keys');
      await remindTomorrow();
      await expect(
        sender.reminders.reminders(defaultProfile),
      ).resolves.toHaveLength(1);

      await press('Send');
      await waitFor(async () => {
        await expect(
          sender.reminders.reminders(defaultProfile),
        ).resolves.toStrictEqual([]);
      });
    } finally {
      sender.outbox.dispose();
    }
  });

  it('removes the recovery record once Remind Me to Send stores the version shown', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      const listeners = jest.mocked(AppState.addEventListener).mock.calls
        .length;
      await render(<App sender={sender} />);
      await compose('Keys');
      await act(async () => {
        for (const [, listener] of jest
          .mocked(AppState.addEventListener)
          .mock.calls.slice(listeners)) {
          listener('active');
        }
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(sender.storage.recoveryRecords().size).toBe(1);
      });

      await remindTomorrow();
      await waitFor(() => {
        expect(sender.storage.recoveryRecords().size).toBe(0);
      });
      expect(screen.getByLabelText('Subject')).toBeOnTheScreen();
    } finally {
      sender.outbox.dispose();
    }
  });

  it('keeps the reminder of a Draft another editor saved when it sends its own conflicting copy', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Keys');
      await remindTomorrow();
      const reminded = await sender.reminders.reminders(defaultProfile);
      expect(reminded).toHaveLength(1);
      const [original] = draftsOf(sender.drafts.getSnapshot());
      ok(original);

      // Another editor saves the Draft, then this stale composer edits and sends its copy.
      await act(async () => {
        await sender.drafts.update(
          { ...original, subject: 'Keys from the other editor' },
          original,
        );
      });
      await fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'Keys, sent',
      );
      await press('Send');
      await waitFor(() => {
        expect(screen.queryByLabelText('Message body')).toBeNull();
      });
      expect(draftsOf(sender.drafts.getSnapshot())).toMatchObject([
        { id: original.id, subject: 'Keys from the other editor' },
      ]);
      await expect(
        sender.reminders.reminders(defaultProfile),
      ).resolves.toStrictEqual(reminded);
    } finally {
      sender.outbox.dispose();
    }
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one delivery path end to end. */
  it('sends from the composer after the Undo Send Window, and Undo returns the Draft to edit', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      const listeners = jest.mocked(AppState.addEventListener).mock.calls
        .length;
      await render(<App sender={sender} />);
      await compose('Lunch');
      // Returning to the foreground journals the unsent edits at once.
      await act(async () => {
        for (const [, listener] of jest
          .mocked(AppState.addEventListener)
          .mock.calls.slice(listeners)) {
          listener('active');
        }
        await Promise.resolve();
      });
      await waitFor(() => {
        expect(sender.storage.recoveryRecords().size).toBe(1);
      });

      await press('Send');

      // The composer closes and its recovery record goes; the message waits in the Outbox, and no
      // Draft row remains.
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await waitFor(() => {
        expect(sender.storage.recoveryRecords().size).toBe(0);
      });
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

  it('sends at once with Send Now, which waits for a file still being added', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lunch');

      // While a file is still being added, Send Now names it and can't be chosen.
      sender.storage.holdImports();
      sender.storage.addFile('file:///terms.pdf', 'terms');
      sender.storage.pickNext('files', [
        {
          uri: 'file:///terms.pdf',
          name: 'terms.pdf',
          type: 'application/pdf',
        },
      ]);
      const attach = addFilesChoice('Attach File');
      ok(attach !== undefined);
      await act(async () => {
        attach();
      });
      expect(sendMenuItem('Send Now')).toMatchObject({
        subtitle: 'Waiting for terms.pdf to finish',
        disabled: true,
      });
      await act(async () => {
        sender.storage.releaseImports();
        await sender.drafts.save();
      });
      await screen.findByLabelText('terms.pdf, 5 bytes');

      // Once it is added, Send Now hands the message over without the Undo Send Window.
      const sendNow = sendMenuItem('Send Now');
      expect(sendNow).toMatchObject({ subtitle: 'No Undo', disabled: false });
      await sendNow.choose();
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await later(sender, 0);
      expect(sender.gmail.sends).toHaveLength(1);
      expect(sender.gmail.sends[0]?.raw).toContain('Subject: Lunch');
      expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
    } finally {
      sender.outbox.dispose();
    }
  });

  it('asks to send without files that were not added, then sends the rest', async () => {
    expect.hasAssertions();
    const sender = device();
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lease');
      const attach = async (
        file:
          | Readonly<{ uri: string; name: string; type: string }>
          | Readonly<{ name: string; type: string; oversized: 'true' }>,
      ) => {
        sender.storage.pickNext('files', [file]);
        const choice = addFilesChoice('Attach File');
        ok(choice !== undefined);
        await act(async () => {
          choice();
        });
      };
      sender.storage.addFile('file:///lease.pdf', 'lease');
      await attach({
        uri: 'file:///lease.pdf',
        name: 'lease.pdf',
        type: 'application/pdf',
      });
      await screen.findByLabelText('lease.pdf, 5 bytes');
      await attach({
        name: 'tour.mov',
        type: 'video/quicktime',
        oversized: 'true',
      });
      await screen.findByLabelText(
        'tour.mov, Not added: too large for Drafts on this device',
      );

      // A file still being added keeps Send unavailable.
      sender.storage.holdImports();
      sender.storage.addFile('file:///keys.pkpass', 'keys');
      await attach({
        uri: 'file:///keys.pkpass',
        name: 'keys.pkpass',
        type: 'application/vnd.apple.pkpass',
      });
      expect(screen.getByRole('button', { name: 'Send' })).toBeDisabled();
      await press('Cancel adding keys.pkpass');
      await act(async () => {
        sender.storage.releaseImports();
        await sender.drafts.save();
      });
      await screen.findByLabelText('keys.pkpass, Not added: cancelled');

      // Once only files that were not added are left, Send asks first; Keep Editing changes nothing.
      expect(screen.getByRole('button', { name: 'Send' })).toBeEnabled();
      await press('Send');
      expect(alert.mock.calls).toStrictEqual([
        [
          'Send without 2 attachments?',
          'tour.mov is too large and keys.pkpass wasn’t added. The other file will be sent.',
          [
            expect.objectContaining({ text: 'Send Without Them' }),
            expect.objectContaining({ text: 'Keep Editing', style: 'cancel' }),
          ],
          expect.anything(),
        ],
      ]);
      const answer = (choice: number) =>
        act(async () => {
          alert.mock.lastCall?.[2]?.[choice]?.onPress?.();
        });
      await answer(1);
      expect(
        screen.getByLabelText(
          'tour.mov, Not added: too large for Drafts on this device',
        ),
      ).toBeOnTheScreen();
      expect(
        screen.getByLabelText('keys.pkpass, Not added: cancelled'),
      ).toBeOnTheScreen();
      await later(sender, 10_000);
      expect(sender.gmail.sends).toStrictEqual([]);

      // Send Now asks the same; Send Without Them removes both and sends the rest at once.
      await sendMenuItem('Send Now').choose();
      expect(alert).toHaveBeenCalledTimes(2);
      await answer(0);
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await later(sender, 0);
      expect(sender.gmail.sends).toHaveLength(1);
      const raw = sender.gmail.sends[0]?.raw;
      expect(raw).toContain('Subject: Lease');
      expect(raw).toContain('lease.pdf');
      expect(raw).not.toContain('tour.mov');
      expect(raw).not.toContain('keys.pkpass');
    } finally {
      alert.mockRestore();
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
      await press('Format');
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
        'Close Format',
        'Undo',
        'Redo',
        'Compose actions',
        'Send',
        'Bold',
        'Show Cc and Bcc',
        'Body',
        'Title',
      ]) {
        expect(screen.getByRole('button', { name })).toBeDisabled();
      }
      for (const choice of screen.getAllByRole('button', {
        name: 'Send from alex@example.invalid',
      })) {
        expect(choice).toBeDisabled();
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
        await chooseWritingTool(captureLabel);
        await screen.findByText('Reviewed text');
        const capture = writingToolChoice(captureLabel);
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
        expect(screen.getByLabelText('Writing tools')).toBeDisabled();
        expect(screen.getByLabelText('Message body')).toHaveTextContent(
          'See you',
          { exact: true },
        );
        await act(async () => {
          sender.storage.release();
        });
        await screen.findByRole('alert', {
          name: 'This message wasn’t sent. It stays open. Choose Send to try again.',
        });
        expect(screen.getByLabelText('Writing tools')).not.toBeDisabled();
        await chooseWritingTool(captureLabel);
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

  it('never shows a Draft as unavailable while Send, Discard or Close closes its composer', async () => {
    expect.hasAssertions();
    const sender = device();
    // Whether each commit after the first render shows the fallback for an unavailable Draft.
    const unavailable: boolean[] = [];
    let record = () => 0;
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(
        <Profiler
          id="composer"
          onRender={() => record()}>
          <App sender={sender} />
        </Profiler>,
      );
      // The screen can be queried once render returns.
      record = () =>
        unavailable.push(
          screen.queryByText('This Draft is not available.') !== null,
        );
      await compose('Lunch');
      await press('Send');
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await compose('Dinner');
      await act(async () => {
        await sender.drafts.save();
      });
      await choose('Compose actions', 'Discard');
      await press('Discard Draft');
      expect(screen.queryByLabelText('Subject')).toBeNull();
      await press('New Message');
      await press('Close');

      expect(screen.queryByLabelText('Subject')).toBeNull();
      expect(unavailable).toContain(false);
      expect(unavailable).not.toContain(true);
    } finally {
      sender.outbox.dispose();
    }
  });

  it('restores editing after refused admission and stores the next edits on Save Draft', async () => {
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
      // Storage refuses the admission.
      jest.spyOn(sender.outbox, 'send').mockResolvedValueOnce('storage');
      await press('Send');
      await screen.findByRole('alert', {
        name: 'This message wasn’t sent. It stays open. Choose Send to try again.',
      });
      expect(screen.getByLabelText('Subject')).toHaveProp('editable', true);
      for (const field of ['To', 'Subject', 'Message body']) {
        expect(screen.getByLabelText(field)).not.toBeDisabled();
      }
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
      await fireEvent.changeText(
        screen.getByLabelText('Subject'),
        'After refusal',
      );
      await fireEvent.changeText(
        screen.getByLabelText('Message body'),
        'Kept edits',
      );
      await press('Close');
      await press('Save Draft');
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
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    const queued = jest.mocked(
      AccessibilityInfo.announceForAccessibilityWithOptions,
    );
    announce.mockClear();
    queued.mockClear();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await press('New Message');

      // Send waits for a recipient, and To says so before anything is pressed; VoiceOver reads
      // the reason with Send.
      const required = 'Add a recipient to send.';
      const send = () => screen.getByRole('button', { name: 'Send' });
      expect(send()).toBeDisabled();
      expect(send()).toHaveProp('accessibilityHint', required);
      expect(screen.getByText(required)).toBeOnTheScreen();
      await fireEvent.changeText(screen.getByLabelText('To'), 'sam@example');
      await fireEvent(screen.getByLabelText('To'), 'blur');
      const incomplete =
        '“sam@example” is not a complete address. Correct it to send.';
      expect(screen.getByText(incomplete)).toBeOnTheScreen();
      expect(screen.getByLabelText('To')).toHaveProp(
        'accessibilityHint',
        incomplete,
      );
      expect(screen.queryByText(required)).toBeNull();
      expect(send()).toBeDisabled();
      expect(send()).toHaveProp('accessibilityHint', incomplete);
      await fireEvent.changeText(
        screen.getByLabelText('To'),
        'sam@example.invalid',
      );
      await fireEvent(screen.getByLabelText('To'), 'submitEditing');
      expect(screen.queryByText(incomplete)).toBeNull();
      expect(send()).not.toBeDisabled();
      expect(send().props.accessibilityHint).toBeUndefined();
      await press('To: sam@example.invalid');
      expect(screen.getByText(required)).toBeOnTheScreen();
      expect(send()).toBeDisabled();
      // On iPhone, Undo is in the Format panel.
      await press('Format');
      await press('Undo');
      await press('Close Format');
      expect(
        screen.getByRole('button', { name: 'To: sam@example.invalid' }),
      ).toBeOnTheScreen();
      expect(screen.queryByText(required)).toBeNull();
      expect(send()).not.toBeDisabled();
      await choose('Compose actions', 'Discard');
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
      await choose('Compose actions', 'Discard');
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
      // A successful Send closes its composer, without leaving an unavailable Draft behind.
      expect(screen.queryByText('This Draft is not available.')).toBeNull();
      await press('Edit');
      const refused =
        'The message wasn’t returned to Drafts. It’s still in the Outbox. Choose Try Again to return it.';
      const undo = jest.spyOn(sender.outbox, 'undo');
      sender.storage.hold();
      sender.storage.failNextCommit('locked');
      await press('Edit Anyway');
      // Cancel supersedes the pending Edit, even when storage refuses it afterward.
      await press('Cancel');
      await act(async () => {
        sender.storage.release();
        await Promise.all(undo.mock.results.map(({ value }) => value));
      });
      undo.mockRestore();
      expect(screen.queryByText('Try Again')).toBeNull();
      expect(announce.mock.calls.map(([words]) => words)).not.toContain(
        refused,
      );
      await press('Edit');
      sender.storage.failNextCommit('locked');
      await press('Edit Anyway');
      expect(screen.getByText(refused)).toBeOnTheScreen();
      // Cancelling the warning is the next Outbox action, so the older refusal leaves.
      await press('Cancel');
      await waitFor(() => {
        expect(screen.queryByText(refused)).toBeNull();
      });
      await press('Edit');
      await press('Edit Anyway');
      expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Unknown');
      await later(sender, 60_000);
      expect(sender.gmail.sends).toHaveLength(1);
      // VoiceOver hears each refusal, each change of where a message stands and each answer to
      // Check Again once, in order; a message confirmed in Sent leaves the Outbox silently.
      const row = (subject: string, status: string) =>
        `${subject}. To sam@example.invalid. ${status}`;
      const unknown =
        'Delivery unknown. Check Sent in Gmail before sending it again.';
      const unconfirmed =
        'Gmail did not confirm this message. Check Sent in Gmail.';
      expect(queued.mock.calls).toStrictEqual([
        [row('Refused', 'Sending soon'), { queue: true }],
        [row('Refused', 'Sending…'), { queue: true }],
        [
          row('Refused', 'Not sent. Gmail refused this message.'),
          { queue: true },
        ],
        [row('Lost', 'Sending soon'), { queue: true }],
        [row('Unknown', 'Sending soon'), { queue: true }],
        [row('Lost', 'Sending…'), { queue: true }],
        [row('Lost', unknown), { queue: true }],
        [row('Unknown', 'Sending…'), { queue: true }],
        [row('Unknown', unknown), { queue: true }],
        [unconfirmed, { queue: true }],
        [unconfirmed, { queue: true }],
      ]);
      expect(announce.mock.calls.map(([words]) => words)).toStrictEqual([
        // Leaving To with an incomplete address says why once.
        '“sam@example” is not a complete address. Correct it to send.',
        'Discard this Draft? It is deleted from this device.',
        'Discard this Draft? It is deleted from this device.',
        warning,
        warning,
        warning,
        refused,
        warning,
      ]);
    } finally {
      sender.storage.release();
      sender.outbox.dispose();
    }
  });

  it('keeps a message storage refused to return, and Try Again returns it', async () => {
    expect.hasAssertions();
    const sender = device();
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    announce.mockClear();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lisbon');
      await press('Send');
      // The admitted Draft leaves the store before Send settles, and the composer still closes.
      expect(screen.queryByText('This Draft is not available.')).toBeNull();
      sender.storage.failNextCommit('locked');
      await press('Undo');
      // The row stays as it was, and the refusal is heard at once.
      // iPhone's narrower toast leaves the subject to the row.
      const refused =
        'The message wasn’t returned to Drafts. It’s still in the Outbox. Choose Try Again to return it.';
      expect(screen.getByText(refused)).toBeOnTheScreen();
      expect(
        screen.getByLabelText('Lisbon. To sam@example.invalid. Sending soon'),
      ).toBeOnTheScreen();
      expect(screen.queryByLabelText('Subject')).toBeNull();
      expect(announce.mock.calls).toStrictEqual([[refused]]);
      await press('Try Again');
      await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
        'value',
        'Lisbon',
      );
      expect(screen.queryByText(refused)).toBeNull();
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();
      expect(announce.mock.calls).toStrictEqual([[refused]]);
      await later(sender, 10_000);
      expect(sender.gmail.sends).toStrictEqual([]);
    } finally {
      sender.outbox.dispose();
    }
  });

  it('retires a refusal once the message starts sending', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      // Gmail keeps the message without answering, and Sent cannot be read.
      sender.gmail.failSend({ lost: true });
      sender.gmail.native.gmailRequest = () =>
        Promise.reject(
          Object.assign(new Error('Synthetic failure'), {
            code: 'unavailable',
          }),
        );
      await compose('Lisbon');
      await press('Send');
      // The admitted Draft leaves the store before Send settles, and the composer still closes.
      expect(screen.queryByText('This Draft is not available.')).toBeNull();
      sender.storage.failNextCommit('locked');
      await press('Undo');
      expect(
        screen.getByText(
          'The message wasn’t returned to Drafts. It’s still in the Outbox. Choose Try Again to return it.',
        ),
      ).toBeOnTheScreen();
      await later(sender, 10_000);
      // Returning it now needs the Edit Anyway warning, so the old Try Again does not come back.
      expect(
        screen.getByLabelText(
          'Lisbon. To sam@example.invalid. Delivery unknown. Check Sent in Gmail before sending it again.',
        ),
      ).toBeOnTheScreen();
      expect(
        screen.queryByText(
          'The message wasn’t returned to Drafts. It’s still in the Outbox. Choose Try Again to return it.',
        ),
      ).toBeNull();
    } finally {
      sender.outbox.dispose();
    }
  });

  it('says a message is in Sent only when Check Again finds it there', async () => {
    expect.hasAssertions();
    const sender = device();
    const queued = jest.mocked(
      AccessibilityInfo.announceForAccessibilityWithOptions,
    );
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      // Gmail keeps the message without answering, and Sent cannot be read until Check Again.
      sender.gmail.failSend({ lost: true });
      const request = sender.gmail.native.gmailRequest;
      sender.gmail.native.gmailRequest = () =>
        Promise.reject(
          Object.assign(new Error('Synthetic failure'), {
            code: 'unavailable',
          }),
        );
      await compose('Lisbon');
      await press('Send');
      await later(sender, 10_000);
      expect(
        screen.getByLabelText(
          'Lisbon. To sam@example.invalid. Delivery unknown. Check Sent in Gmail before sending it again.',
        ),
      ).toBeOnTheScreen();
      queued.mockClear();
      sender.gmail.native.gmailRequest = request;
      await press('Check Again');
      await waitFor(() => {
        expect(screen.queryByLabelText(/^Lisbon\./u)).toBeNull();
      });
      expect(queued.mock.calls).toStrictEqual([
        ['Lisbon is in Sent.', { queue: true }],
      ]);
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
    } finally {
      sender.outbox.dispose();
    }
  });
});
