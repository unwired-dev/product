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

import { InboxProvider, MailboxScope } from '../src/mailbox.tsx';
import { MessageBody } from '../src/message-body.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { UnsubscribeContext } from '../src/unsubscribe.tsx';

const account = 'synthetic-product-account';
const address = 'mara.novak@icloud.com';
const { icloud } = imapProviders;
const to = 'leave@alza.example';

// The controlled clock every journey runs on.
const clock = { now: 0 };

// A device whose iCloud Mail mailbox, with an outgoing server when `smtp`, received a newsletter
// that unsubscribes only by email; the Product Account reports the mailbox in `state` while its
// Inbox is open. Only the native unsubscribe record and the AppKit controls are substituted.
async function device({ state = 'connected', smtp = true } = {}) {
  // Outcomes outlive a reader for the app's lifetime, so each test opens its own connection.
  const mara = { id: `connection-${crypto.randomUUID()}`, address };
  const snapshotIn = (now: string): RegistrationSnapshot => ({
    kind: 'connected',
    productAccountId: account,
    signInProvider: 'google',
    mailboxes: JSON.stringify([
      {
        ...mara,
        provider: 'imap',
        state: now,
        imap: { host: icloud.host, port: icloud.port, username: 'mara.novak' },
        ...(smtp ? { smtp: { ...icloud.smtp, username: address } } : {}),
      },
    ]),
  });
  const snapshot = snapshotIn('connected');
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
  const outbox = createOutbox({
    drafts,
    mailboxes,
    registration,
    claims: storage.delivery,
  });
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
    outbox,
  );
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
        mailboxes: mailboxesOf(snapshotIn(state)),
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
          <MailboxScope id={mara.id}>
            <MessageBody
              inbox={mailbox.inbox}
              id={id}
              connection={mara.id}
              message={{
                name: 'Alza.cz',
                address: 'news@alza.example',
                receivedAt: clock.now,
              }}
            />
          </MailboxScope>
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
  return { imap, outbox, opened, signIns, deliver };
}

const press = async (name: string) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

const confirm = async () => {
  await press('Unsubscribe…');
  expect(
    screen.getByText(
      `Unwired emails an unsubscribe request to ${to} from ${address}. It appears in Sent. It can take a few days to stop. Mail you already have stays.`,
    ),
  ).toBeOnTheScreen();
  await press('Unsubscribe');
};

describe('the reader’s mailto: Unsubscribe on the Mac', () => {
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
  });
  /* oxlint-enable vitest/max-expects */

  it('takes the request back with the toast’s Undo and offers it again', async () => {
    expect.hasAssertions();
    const mail = await device();
    await confirm();
    await press('Undo');
    await expect(
      screen.findByRole('button', { name: 'Unsubscribe…' }),
    ).resolves.toBeEnabled();
    expect(mail.outbox.getSnapshot()).toStrictEqual([]);
    expect(
      screen.queryByText('Unsubscribe request waiting to send'),
    ).toBeNull();
  });

  it('says why a mailbox that must sign in again cannot send, and opens its settings', async () => {
    expect.hasAssertions();
    const mail = await device({ state: 'authorization' });
    await expect(
      screen.findByText(
        `Alza.cz newsletter unsubscribes by email from ${address}. iCloud Mail needs you to sign in again before this address can send.`,
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    // An IMAP password is entered again in the mailbox's settings.
    await press('Sign In…');
    expect(mail.opened).toStrictEqual(['mailboxes']);
    expect(mail.signIns).toStrictEqual([]);
  });

  it('says why a receive-only mailbox cannot send, and never uses another address', async () => {
    expect.hasAssertions();
    const mail = await device({ smtp: false });
    await expect(
      screen.findByText(
        `Alza.cz newsletter unsubscribes by email, but ${address} has no outgoing server, so Unwired can’t send it. It won’t use another address.`,
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    await press('Mailbox Settings…');
    expect(mail.opened).toStrictEqual(['mailboxes']);
    expect(mail.imap.smtp.accepted).toStrictEqual([]);
  });
});
