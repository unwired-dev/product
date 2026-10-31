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
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { useState } from 'react';
import { AccessibilityInfo } from 'react-native';

import { CommandBar, CommandPaletteProvider } from '../src/command-palette.tsx';
import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { chooseSheetButton, sheetShown } from './native-alert.ts';
import { chooseMenuItem } from './native-menu.ts';

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
    <CommandPaletteProvider windowId="composer">
      <CommandBar />
      <AccountContext
        value={{
          mailboxes: listed,
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account: 'synthetic-product-account',
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
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
    </CommandPaletteProvider>
  );
}

const press = async (name: string) => {
  if (
    name === 'New Message' &&
    screen.queryByRole('button', { name }) === null
  ) {
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
  }
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

// The same composite-fiber boundary used by fireEvent, retained before disabled props commit.
const queuedPress = (label: string, event = 'onPress') => {
  let fiber = screen.getByLabelText(label).unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.[event];
    if (typeof handler === 'function') {
      return (input?: unknown) => {
        handler(input);
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
      // These callbacks were dispatched, and this menu opened, before native received the
      // read-only props.
      await press('Text style');
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
      await chooseMenuItem('Heading 1');

      expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Lunch');
      expect(
        screen.getByRole('button', { name: 'Text style' }),
      ).toHaveAccessibilityValue({ text: 'Body' });
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
        'Compose actions',
        'Send',
        'Bold',
        'Show Cc and Bcc',
        'Text style',
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

  it('shows Checking… on each file Send checks, keeps a damaged one to remove and sends only when asked again', async () => {
    expect.hasAssertions();
    const sender = device();
    const announce = jest.mocked(AccessibilityInfo.announceForAccessibility);
    announce.mockClear();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Contracts');
      sender.storage.addFile('file:///plan.pdf', 'plan');
      sender.storage.addFile('file:///scan.pdf', 'scan');
      sender.storage.pickNext('files', [
        { uri: 'file:///plan.pdf', name: 'plan.pdf', type: 'application/pdf' },
        { uri: 'file:///scan.pdf', name: 'scan.pdf', type: 'application/pdf' },
      ]);
      await press('Attach Files…');
      await screen.findByLabelText('plan.pdf, 4 bytes');
      await screen.findByLabelText('scan.pdf, 4 bytes');
      // A refused check can succeed on the next Send without a separate preview retry.
      const locked = jest
        .spyOn(sender.storage.native, 'readDraftAsset')
        .mockRejectedValueOnce(
          Object.assign(new Error('Storage locked'), { code: 'locked' }),
        );
      await press('Send');
      await screen.findByLabelText(
        'plan.pdf, 4 bytes · Not checked while private storage is locked',
      );
      locked.mockRestore();
      announce.mockClear();
      // Each file's check finishes only when the test lets it.
      const read = sender.storage.native.readDraftAsset;
      const reads: Array<Readonly<{ id: string; finish: () => void }>> = [];
      const held = jest
        .spyOn(sender.storage.native, 'readDraftAsset')
        .mockImplementation(async (...args) => {
          // oxlint-disable-next-line promise/avoid-new -- Hold each check until the test finishes it.
          await new Promise((resolve) => {
            reads.push({ id: args[1].id, finish: () => resolve(undefined) });
          });
          return read(...args);
        });
      const finishRead = async () => {
        const next = reads.shift();
        ok(next, 'Expected a file being checked');
        await act(async () => {
          next.finish();
          await Promise.resolve();
        });
      };

      await press('Send');

      await expect(
        screen.findByLabelText('plan.pdf, Checking…'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByLabelText('scan.pdf, Checking…')).toBeOnTheScreen();
      for (const name of ['Send', 'Remove plan.pdf', 'Remove scan.pdf']) {
        expect(screen.getByRole('button', { name })).toBeDisabled();
      }
      expect(screen.getByLabelText('Subject')).toBeDisabled();
      expect(announce).toHaveBeenCalledWith('Checking attachments');

      await finishRead();
      await expect(
        screen.findByLabelText('plan.pdf, 4 bytes'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByLabelText('scan.pdf, Checking…')).toBeOnTheScreen();
      expect(
        screen.getByRole('button', { name: 'Remove scan.pdf' }),
      ).toBeDisabled();

      const [scan] = reads;
      ok(scan, 'Expected scan.pdf being checked');
      sender.storage.damage(scan.id);
      await finishRead();
      await expect(
        screen.findByLabelText('scan.pdf, 4 bytes · Damaged on this device'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByLabelText('plan.pdf, 4 bytes')).toBeOnTheScreen();
      for (const name of ['Send', 'Remove plan.pdf', 'Remove scan.pdf']) {
        expect(screen.getByRole('button', { name })).toBeEnabled();
      }
      expect(
        announce.mock.calls.filter(
          ([words]) => words === 'Checking attachments',
        ),
      ).toHaveLength(1);
      await later(sender, 10_000);
      expect(sender.gmail.sends).toStrictEqual([]);
      expect(screen.queryByRole('header', { name: 'Outbox' })).toBeNull();

      held.mockRestore();
      await press('Remove scan.pdf');
      expect(screen.queryByLabelText(/^scan\.pdf/u)).toBeNull();
      await press('Send');
      await waitFor(() => {
        expect(screen.queryByLabelText('Subject')).toBeNull();
      });
      await later(sender, 10_000);
      expect(sender.gmail.sends).toHaveLength(1);
      expect(sender.gmail.sends[0]?.raw).toContain('plan.pdf');
      expect(sender.gmail.sends[0]?.raw).not.toContain('scan.pdf');
    } finally {
      sender.outbox.dispose();
    }
  });

  it.each([
    {
      purpose: 'rewrite',
      capture: 'Rewrite',
      applyLabel: 'Replace your text with this rewrite',
      region: 'Rewrite of your text',
      context: {},
    },
    {
      purpose: 'reply',
      capture: 'Suggest reply',
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
    async ({ purpose, capture, applyLabel, region, context }) => {
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
        await press('Writing tools');
        await chooseMenuItem(capture);
        await screen.findByText('Reviewed text');
        const writingTools = queuedPress('Writing tools', 'onSelect');
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
          writingTools({ nativeEvent: { id: purpose } });
          await pressed;
        });
        expect(screen.queryByLabelText(region)).toBeNull();
        expect(
          screen.getByRole('button', { name: 'Writing tools' }),
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
          screen.getByRole('button', { name: 'Writing tools' }),
        ).not.toBeDisabled();
        await press('Writing tools');
        await chooseMenuItem(capture);
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

  it('closes a Draft its refused Send stored without asking to save it', async () => {
    expect.hasAssertions();
    const sender = device();
    try {
      await act(async () => {
        await sender.mailboxes.load();
      });
      await render(<App sender={sender} />);
      await compose('Lunch');
      await fireEvent(screen.getByLabelText('To'), 'submitEditing');
      await press('To: sam@example.invalid');
      await press('Send');
      await screen.findByRole('alert', {
        name: 'Add a recipient before sending.',
      });
      await press('Close');
      expect(sheetShown()).toBeUndefined();
      expect(screen.queryByLabelText('Subject')).toBeNull();
      expect(sender.storage.stored()?.document).toContain('Lunch');
    } finally {
      sender.storage.release();
      sender.outbox.dispose();
    }
  });

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
      await act(async () => {
        chooseSheetButton('Save');
      });
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
      await press('Compose actions');
      await chooseMenuItem('Discard');
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
      await press('Compose actions');
      await chooseMenuItem('Discard');
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
      expect(screen.getByLabelText(warning)).toBeOnTheScreen();
      await act(async () => {
        release();
      });
      expect(screen.getByText(warning)).toBeOnTheScreen();
      await press('Cancel');
      expect(screen.queryByText(warning)).toBeNull();
      // A successful Send closes its composer, without leaving an unavailable Draft behind.
      expect(screen.queryByText('This Draft is not available.')).toBeNull();
      await press('Edit');
      const refused = 'Couldn’t return “Unknown” to Drafts.';
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
        'Add a recipient before sending.',
        'Add a recipient before sending.',
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
      const refused = 'Couldn’t return “Lisbon” to Drafts.';
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
        screen.getByText('Couldn’t return “Lisbon” to Drafts.'),
      ).toBeOnTheScreen();
      await later(sender, 10_000);
      // Returning it now needs the Edit Anyway warning, so the old Try Again does not come back.
      expect(
        screen.getByLabelText(
          'Lisbon. To sam@example.invalid. Delivery unknown. Check Sent in Gmail before sending it again.',
        ),
      ).toBeOnTheScreen();
      expect(
        screen.queryByText('Couldn’t return “Lisbon” to Drafts.'),
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

  it('announces each change of an Outbox message once, however many windows show it', async () => {
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
      const { rerender } = await render(<App sender={sender} />);
      sender.gmail.failSend({ status: 400, body: '{}' });
      await compose('Twice');
      await press('Send');
      // A second window opening on the same Outbox repeats nothing it already said.
      await rerender(
        <>
          <App sender={sender} />
          <App sender={sender} />
        </>,
      );
      await later(sender, 10_000);
      const refused =
        'Twice. To sam@example.invalid. Not sent. Gmail refused this message.';
      expect(screen.getAllByLabelText(refused)).toHaveLength(2);
      expect(queued.mock.calls.map(([words]) => words)).toStrictEqual([
        'Twice. To sam@example.invalid. Sending soon',
        'Twice. To sam@example.invalid. Sending…',
        refused,
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
