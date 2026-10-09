import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts } from '@private-email/mail-core/drafts';
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
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';

import { Composer } from '../src/composer.tsx';
import { Inbox } from '../src/inbox.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
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
  return { gmail, drafts, mailboxes, outbox };
}

function App({ sender }: { readonly sender: ReturnType<typeof device> }) {
  const [composing, setComposing] = useState<string>();
  return (
    <AccountContext
      value={{
        mailboxes: mailboxesOf(snapshot),
        openAccount: () => undefined,
        authorizeGmail: () => Promise.resolve(),
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
    await press('Undo');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Lunch');
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
    sender.outbox.dispose();
  });

  it('explains a refused Send, a refusal by Gmail and an unknown outcome', async () => {
    expect.hasAssertions();
    const sender = device();
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
    await press('Discard');
    await press('Discard Draft');
    sender.gmail.failSend({ status: 400, body: '{}' }, { lost: true });
    await compose('Refused');
    await press('Send');
    await compose('Lost');
    await press('Send');
    await later(sender, 10_000);

    expect(sender.gmail.sends).toHaveLength(1);
    expect(
      screen.getByLabelText(
        'Refused. To sam@example.invalid. Not sent. Gmail refused this message.',
      ),
    ).toBeOnTheScreen();
    expect(
      screen.getByLabelText(
        'Lost. To sam@example.invalid. Delivery unknown. Check Sent in Gmail before sending it again.',
      ),
    ).toBeOnTheScreen();
    // Only the refused message returns to edit; the unknown one offers no way to send it again.
    expect(screen.getAllByRole('button', { name: 'Edit' })).toHaveLength(1);
    await press('Edit');
    expect(screen.getByLabelText('Subject')).toHaveProp('value', 'Refused');
    await later(sender, 60_000);
    expect(sender.gmail.sends).toHaveLength(1);
    sender.outbox.dispose();
  });
});
