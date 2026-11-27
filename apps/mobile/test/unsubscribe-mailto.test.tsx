import type { ImapMailbox } from '@private-email/mail-core/mailboxes';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { createDrafts } from '@private-email/mail-core/drafts';
import { imapProviders } from '@private-email/mail-core/imap-setup';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox, undoSendWindow } from '@private-email/mail-core/outbox';
import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { createUnsubscribe } from '@private-email/mail-core/unsubscribe';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import type { SettingsDestination } from '../src/settings.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { UnsubscribeContext } from '../src/unsubscribe.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The reader clears no inset on this host.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const account = 'synthetic-product-account';
const address = 'mara.novak@icloud.com';
const { icloud } = imapProviders;
const to = 'leave@alza.example';
// The name the synthetic server's envelope gives every sender, which the reader shows.
const sender = 'Synthetic Sender';

// The controlled clock every journey runs on.
const clock = { now: 0 };

// An iPhone whose iCloud Mail mailbox, with an outgoing server when `smtp`, received a newsletter
// that unsubscribes only by email, opened in the reader. Only the native unsubscribe record and the
// SwiftUI controls are substituted.
async function device({ smtp = true } = {}) {
  // Outcomes outlive a reader for the app's lifetime, so each test opens its own connection.
  const mara = { id: `connection-${crypto.randomUUID()}`, address };
  const snapshot: RegistrationSnapshot = {
    kind: 'connected',
    productAccountId: account,
    signInProvider: 'google',
    mailboxes: JSON.stringify([
      {
        ...mara,
        provider: 'imap',
        state: 'connected',
        imap: { host: icloud.host, port: icloud.port, username: 'mara.novak' },
        ...(smtp ? { smtp: { ...icloud.smtp, username: address } } : {}),
      },
    ]),
  };
  const registration = {
    getSnapshot: () => ({ snapshot, busy: false, failed: false }),
    resume: () => Promise.resolve(),
    subscribe: () => () => undefined,
  };
  const imap = createSyntheticImap({ address });
  imap.addFolder('Sent', ['sent']);
  const id = `7.${imap
    .deliver('INBOX', {
      subject: 'Black Friday',
      raw: [
        'From: Alza.cz <news@alza.example>',
        `To: ${address}`,
        'Subject: Black Friday',
        'List-Id: Alza.cz newsletter <newsletter.alza.example>',
        `List-Unsubscribe: <mailto:${to}?subject=unsubscribe>`,
        'Content-Type: text/plain; charset=utf-8',
        '',
        'This week only.',
      ].join('\r\n'),
    })
    .toString()}.INBOX`;
  const storage = createSyntheticDrafts(() => account, {
    server: createSyntheticProductSync(),
  });
  const drafts = createDrafts(storage.native, registration);
  const mailboxes = createMailboxes(
    syntheticConnections({}, { [mara.id]: imap.native }),
    registration,
  );
  await mailboxes.load();
  const record = { document: null as string | null, revision: 0 };
  const unsubscribe = createUnsubscribe(
    {
      requestUnsubscribe: () => Promise.resolve({ outcome: 'failed' }),
      openUnsubscribeRequests: () =>
        Promise.resolve({ owner: account, ...record }),
      commitUnsubscribeRequests: (owner, revision, document) => {
        Object.assign(record, { document, revision: revision + 1 });
        return Promise.resolve({ owner, revision: record.revision });
      },
    },
    registration,
  );
  const outbox = createOutbox({
    drafts,
    mailboxes,
    registration,
    claims: storage.delivery,
    requests: unsubscribe,
  });
  const mailbox = mailboxes
    .getConnections()
    .find((each): each is ImapMailbox => each.id === mara.id);
  if (mailbox === undefined) {
    throw new Error('Expected the IMAP mailbox');
  }
  await mailbox.inbox.load();
  const opened: SettingsDestination[] = [];
  const signIns: string[] = [];
  await render(
    <AccountContext
      value={{
        mailboxes: mailboxesOf(snapshot),
        openAccount: (destination) => {
          opened.push(destination ?? 'account');
        },
        authorizeMailbox: (connection) => {
          signIns.push(connection);
          return Promise.resolve();
        },
        refreshInbox: (load) => load(),
        account,
        profiles: [],
        createProfile: () => Promise.resolve(undefined),
        chooseFolders: () => Promise.resolve(true),
      }}>
      <UnsubscribeContext value={unsubscribe}>
        <InboxProvider
          drafts={drafts}
          mailboxes={{ ...mailboxes, getSnapshot: mailboxes.getConnections }}
          outbox={outbox}>
          <CommandPaletteProvider>
            <MessageDetail
              mailbox={mara.id}
              id={id}
            />
          </CommandPaletteProvider>
        </InboxProvider>
      </UnsubscribeContext>
    </AccountContext>,
  );
  await screen.findByText('This week only.');
  // Ends the Undo Send Window and hands what is due to the mail server.
  const deliver = async () => {
    clock.now += undoSendWindow;
    jest.setSystemTime(clock.now);
    await act(async () => {
      await outbox.process();
    });
  };
  // The request the Mail Profile recorded for the newsletter, as reopening the message finds it.
  const recorded = () =>
    unsubscribe.sentRequest(
      mailboxesOf(snapshot)[0]?.profile ?? '',
      {
        kind: 'mailto',
        list: 'Alza.cz newsletter',
        identity: 'newsletter.alza.example',
        address: to,
      },
      clock.now,
    );
  return { imap, outbox, opened, signIns, deliver, recorded };
}

const press = async (name: string) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

// The titles More lists for the opened message.
const moreItems = (): readonly string[] =>
  screen
    .getByLabelText('More')
    .props.sections.flatMap(
      ({ items }: { items: ReadonlyArray<{ title: string }> }) =>
        items.map(({ title }) => title),
    );

const confirm = async () => {
  await press('Unsubscribe…');
  expect(
    screen.getByText(
      `Unwired emails an unsubscribe request to ${to} from ${address}. It appears in Sent. It can take a few days to stop. Mail you already have stays.`,
    ),
  ).toBeOnTheScreen();
  await press('Unsubscribe');
};

describe('the reader’s mailto: Unsubscribe on iPhone', () => {
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  beforeEach(() => {
    // Only the clock is controlled; storage and the mail server answer as promises do.
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
    clock.now = Date.UTC(2026, 10, 24, 9);
    jest.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    jest.useRealTimers();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves the waiting and sent states end to end. */
  it('emails the request from the receiving mailbox after the Undo Send Window, then shows it sent', async () => {
    expect.hasAssertions();
    const mail = await device();
    expect(screen.getByText('Alza.cz newsletter')).toBeOnTheScreen();
    expect(moreItems()).toContain('Unsubscribe…');
    await confirm();
    await expect(
      screen.findByText('Unsubscribe request waiting to send'),
    ).resolves.toBeOnTheScreen();
    expect(
      screen.getByText(
        `Sending in 10 seconds to ${to} from ${address}. The email will be in Sent.`,
      ),
    ).toBeOnTheScreen();
    expect(screen.getByText('Sending unsubscribe request')).toBeOnTheScreen();
    expect(moreItems()).not.toContain('Unsubscribe…');

    await mail.deliver();
    await expect(
      screen.findByText('Unsubscribe request sent'),
    ).resolves.toBeOnTheScreen();
    expect(
      screen.getByText(
        `Emailed to ${to} on Nov 24. It’s in Sent. If their mail keeps coming after 14 days, you can try again.`,
      ),
    ).toBeOnTheScreen();
    expect(mail.imap.smtp.accepted).toHaveLength(1);
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    await expect(mail.recorded()).resolves.toMatchObject({
      sentAt: clock.now,
    });
  });
  /* oxlint-enable vitest/max-expects */

  it('takes the request back with the toast’s Undo and offers it again', async () => {
    expect.hasAssertions();
    const mail = await device();
    await confirm();
    await press('Undo');
    await expect(
      screen.findByRole('button', { name: 'Unsubscribe…' }),
    ).resolves.toBeOnTheScreen();
    expect(mail.outbox.getSnapshot()).toStrictEqual([]);
    expect(
      screen.queryByText('Unsubscribe request waiting to send'),
    ).toBeNull();
    await expect(mail.recorded()).resolves.toBeUndefined();
  });

  it('says the mailbox must sign in again when the server refuses it, then offers the request again', async () => {
    expect.hasAssertions();
    const mail = await device();
    await confirm();
    mail.imap.smtp.failure = 'smtp-refused';
    await mail.deliver();
    await expect(
      screen.findByText(
        `${sender} unsubscribes by email from ${address}. iCloud Mail needs you to sign in again before this address can send.`,
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    expect(moreItems()).not.toContain('Unsubscribe…');
    // An IMAP password is entered again in the mailbox's settings, and the refused request leaves.
    await press('Sign In…');
    await expect(
      screen.findByRole('button', { name: 'Unsubscribe…' }),
    ).resolves.toBeOnTheScreen();
    expect({
      opened: mail.opened,
      signIns: mail.signIns,
      outbox: mail.outbox.getSnapshot(),
    }).toStrictEqual({ opened: ['mailboxes'], signIns: [], outbox: [] });
  });

  it('says why a receive-only mailbox cannot send, and never uses another address', async () => {
    expect.hasAssertions();
    const mail = await device({ smtp: false });
    await expect(
      screen.findByText(
        `${sender} unsubscribes by email, but ${address} has no outgoing server, so Unwired can’t send it. It won’t use another address.`,
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    expect(moreItems()).not.toContain('Unsubscribe…');
    await press('Mailbox Settings…');
    expect(mail.opened).toStrictEqual(['mailboxes']);
    expect(mail.imap.smtp.accepted).toStrictEqual([]);
  });
});
