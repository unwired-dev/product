import type { Invitation } from '@private-email/mail-core/invitations';
import type { ImapMailbox } from '@private-email/mail-core/mailboxes';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';

import { english } from '@private-email/localization';
import { createDrafts } from '@private-email/mail-core/drafts';
import { imapProviders } from '@private-email/mail-core/imap-setup';
import {
  imapInvitationResponses,
  invitationOf,
} from '@private-email/mail-core/invitations';
import { createMailboxes } from '@private-email/mail-core/mailboxes';
import { createOutbox, undoSendWindow } from '@private-email/mail-core/outbox';
import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import { syntheticConnections } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { SectionList } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import type { Selection } from '../src/inbox.tsx';

import { CommandPaletteProvider } from '../src/command-palette.tsx';
import { ImapMessageBody } from '../src/imap-message-body.tsx';
import { Inbox } from '../src/inbox.tsx';
import { ShowOutboxContext } from '../src/invitation.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

const account = 'synthetic-product-account';
const mara = { id: 'connection-mara', address: 'mara.novak@icloud.com' };
const { icloud } = imapProviders;
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
      smtp: { ...icloud.smtp, username: mara.address },
    },
  ]),
};
const registration = {
  getSnapshot: () => ({ snapshot, busy: false, failed: false }),
  resume: () => Promise.resolve(),
  subscribe: () => () => undefined,
};

const invitationMessage = (summary: string, uid: string) =>
  [
    'From: Lena Fischer <lena@northwind.example>',
    `To: ${mara.address}`,
    `Subject: Invitation: ${summary}`,
    `Message-ID: <${uid}@northwind.example>`,
    'MIME-Version: 1.0',
    'Content-Type: multipart/alternative; boundary="alt"',
    '',
    '--alt',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'Please join.',
    '--alt',
    'Content-Type: text/calendar; charset=utf-8; method=REQUEST',
    '',
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'METHOD:REQUEST',
    'BEGIN:VEVENT',
    `UID:${uid}@northwind.example`,
    'SEQUENCE:0',
    `SUMMARY:${summary}`,
    'DTSTART:20261106T130000Z',
    'DTEND:20261106T140000Z',
    'ORGANIZER;CN=Lena Fischer:mailto:lena@northwind.example',
    `ATTENDEE;CN=Mara;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${mara.address}`,
    'END:VEVENT',
    'END:VCALENDAR',
    '--alt--',
  ].join('\r\n');

// The controlled clock every journey runs on.
const clock = { now: 0 };

// A device whose iCloud Mail mailbox, which can send, received `summaries` as invitations. Only
// WebKit and the SwiftUI controls are substituted.
async function device(summaries: readonly string[]) {
  const imap = createSyntheticImap({ address: mara.address });
  imap.addFolder('Sent', ['sent']);
  const ids = summaries.map(
    (summary, index) =>
      `7.${imap
        .deliver('INBOX', {
          subject: `Invitation: ${summary}`,
          raw: invitationMessage(summary, `meeting-${index.toString()}`),
        })
        .toString()}.INBOX`,
  );
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
  const mailbox = mailboxes
    .getConnections()
    .find((each): each is ImapMailbox => each.id === mara.id);
  if (mailbox === undefined) {
    throw new Error('Expected the IMAP mailbox');
  }
  await mailbox.inbox.load();
  // Ends the Undo Send Window and hands what is due to the mail server.
  const deliver = async () => {
    clock.now += undoSendWindow;
    jest.setSystemTime(clock.now);
    await act(async () => {
      await outbox.process();
    });
  };
  function Providers({ children }: { readonly children: React.ReactNode }) {
    return (
      <AccountContext
        value={{
          mailboxes: mailboxesOf(snapshot),
          openAccount: () => undefined,
          authorizeMailbox: () => Promise.resolve(),
          refreshInbox: (load) => load(),
          account,
          profiles: [],
          createProfile: () => Promise.resolve(undefined),
          chooseFolders: () => Promise.resolve(true),
        }}>
        <InboxProvider
          drafts={drafts}
          // As the app lists them: every connection, IMAP included.
          mailboxes={{ ...mailboxes, getSnapshot: mailboxes.getConnections }}
          outbox={outbox}>
          {children}
        </InboxProvider>
      </AccountContext>
    );
  }
  return {
    imap,
    ids,
    inbox: mailbox.inbox,
    outbox,
    storage,
    deliver,
    Providers,
  };
}

const present = <T,>(value: T | undefined, what: string): T => {
  if (value === undefined) {
    throw new Error(`Expected ${what}`);
  }
  return value;
};

// The invitation of the message `id` in `inbox`, as its reader finds it.
async function offerOf(
  inbox: ImapMailbox['inbox'],
  id: string,
): Promise<Invitation> {
  inbox.retainMessage(id, Symbol('test reader'));
  await inbox.readMessage(id);
  const offer = invitationOf(
    present(inbox.responseSource(id), 'the opened invitation'),
    mara.address,
  );
  if (offer?.kind !== 'invited') {
    throw new Error('Expected an invitation to answer');
  }
  return offer;
}

const press = async (name: string) => {
  const button = await screen.findByRole('button', { name });
  await act(async () => {
    await fireEvent.press(button);
  });
};

describe('imap invitation responses on iPhone and iPad', () => {
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
    clock.now = Date.UTC(2026, 10, 2, 9, 52);
    jest.setSystemTime(clock.now);
  });
  // oxlint-disable-next-line vitest/no-hooks -- Every journey runs on the same controlled clock.
  afterEach(() => {
    jest.useRealTimers();
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves one response path end to end. */
  it('answers through the Outbox: Undo, View in Outbox, accepted, refused and unknown', async () => {
    expect.hasAssertions();
    const mail = await device(['Q4 roadmap review']);
    const [id = ''] = mail.ids;
    const shown: string[] = [];
    const app = await render(
      <mail.Providers>
        <ShowOutboxContext
          value={() => {
            shown.push('outbox');
          }}>
          <ImapMessageBody
            inbox={mail.inbox}
            id={id}
            connection={mara.id}
          />
        </ShowOutboxContext>
      </mail.Providers>,
    );
    try {
      await expect(
        screen.findByText('Q4 roadmap review'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText(`${mara.address} · iCloud`)).toBeOnTheScreen();

      // I1: the choice waits out the Undo Send Window, and Undo takes it back.
      await press('Accept');
      expect(screen.getByText('In the Outbox')).toBeOnTheScreen();
      expect(
        screen.getByText('Your Accept response is queued. Undo is available.'),
      ).toBeOnTheScreen();
      expect(screen.getByRole('button', { name: 'Maybe' })).toBeDisabled();
      await press('View in Outbox');
      expect(shown).toStrictEqual(['outbox']);
      await press('Undo');
      expect(mail.outbox.getSnapshot()).toStrictEqual([]);
      expect(screen.queryByText('In the Outbox')).toBeNull();
      expect(screen.getByRole('button', { name: 'Accept' })).toBeEnabled();

      // I2: once the window ends, the mail server accepts it.
      await press('Decline');
      await mail.deliver();
      expect(mail.imap.smtp.accepted).toHaveLength(1);
      expect(screen.getByText('Declined')).toBeOnTheScreen();
      expect(
        screen.getByText(
          /^iCloud’s mail server accepted your response at .+\. Choose another response to change it\.$/u,
        ),
      ).toBeOnTheScreen();
      expect(
        screen.queryByRole('button', { name: 'View in Outbox' }),
      ).toBeNull();

      // I4: a refusal leaves every choice for a fresh one.
      mail.imap.smtp.failure = 'smtp-rejected';
      await press('Accept');
      await mail.deliver();
      expect(screen.getByText('Not sent')).toBeOnTheScreen();
      expect(
        screen.getByText(
          'iCloud’s mail server refused your response. Choose a response to try again.',
        ),
      ).toBeOnTheScreen();
      expect(screen.getByRole('button', { name: 'Accept' })).toBeEnabled();

      // I5: an unconfirmed handoff offers no choice, only the Outbox.
      mail.imap.smtp.lost = true;
      await press('Maybe');
      await mail.deliver();
      expect(screen.getByText('Delivery unknown')).toBeOnTheScreen();
      expect(
        screen.getByText(
          'iCloud’s mail server didn’t confirm your response. It may have been sent.',
        ),
      ).toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Accept' })).toBeNull();
      expect(
        screen.getByRole('button', { name: 'View in Outbox' }),
      ).toBeOnTheScreen();
    } finally {
      await app.unmount();
      mail.outbox.dispose();
    }
  });

  it('says when storage refused Undo, and Try Again takes the response back', async () => {
    expect.hasAssertions();
    const mail = await device(['Q4 roadmap review']);
    const [id = ''] = mail.ids;
    const app = await render(
      <mail.Providers>
        <ShowOutboxContext value={() => undefined}>
          <ImapMessageBody
            inbox={mail.inbox}
            id={id}
            connection={mara.id}
          />
        </ShowOutboxContext>
      </mail.Providers>,
    );
    try {
      await press('Accept');
      mail.storage.failNextCommit('locked');
      await press('Undo');
      expect(screen.getByText('Couldn’t undo your response')).toBeOnTheScreen();
      expect(
        screen.getByText(
          'Your Accept response is still in the Outbox. Choose Try Again to undo it.',
        ),
      ).toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
      expect(screen.getByRole('button', { name: 'Maybe' })).toBeDisabled();
      expect(
        screen.getByRole('button', { name: 'View in Outbox' }),
      ).toBeOnTheScreen();

      await press('Try Again');
      expect(mail.outbox.getSnapshot()).toStrictEqual([]);
      expect(screen.queryByText('Couldn’t undo your response')).toBeNull();
      expect(screen.getByRole('button', { name: 'Accept' })).toBeEnabled();

      // The notice clears once the response stops waiting.
      await press('Decline');
      mail.storage.failNextCommit('locked');
      await press('Undo');
      expect(screen.getByText('Couldn’t undo your response')).toBeOnTheScreen();
      await mail.deliver();
      expect(screen.queryByText('Couldn’t undo your response')).toBeNull();
      expect(screen.getByText('Declined')).toBeOnTheScreen();
    } finally {
      await app.unmount();
      mail.outbox.dispose();
    }
  });

  it('shows the response sending once the window ends, with View in Outbox', async () => {
    expect.hasAssertions();
    const mail = await device(['Q4 roadmap review']);
    const [id = ''] = mail.ids;
    const app = await render(
      <mail.Providers>
        <ShowOutboxContext value={() => undefined}>
          <ImapMessageBody
            inbox={mail.inbox}
            id={id}
            connection={mara.id}
          />
        </ShowOutboxContext>
      </mail.Providers>,
    );
    try {
      await press('Accept');
      // The mail server takes the submission and has not answered yet.
      mail.imap.smtp.stopped = true;
      clock.now += undoSendWindow;
      jest.setSystemTime(clock.now);
      void mail.outbox.process();
      await expect(
        screen.findByText(`Sending your Accept response from ${mara.address}.`),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('In the Outbox')).toBeOnTheScreen();
      for (const name of ['Accept', 'Maybe', 'Decline']) {
        expect(screen.getByRole('button', { name })).toBeDisabled();
      }
      expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();
      expect(
        screen.getByRole('button', { name: 'View in Outbox' }),
      ).toBeOnTheScreen();
    } finally {
      await app.unmount();
      mail.outbox.dispose();
    }
  });

  it('shows each response in its own Outbox row, with no Edit', async () => {
    expect.hasAssertions();
    const mail = await device(['Q4 roadmap review', 'Release readiness']);
    const opened: Selection[] = [];
    const [roadmap = '', release = ''] = mail.ids;
    const responses = imapInvitationResponses(mail.inbox, mail.outbox, mara.id);
    const outboxView = { outbox: true };
    const list = (outboxShown?: object) => (
      <mail.Providers>
        <SafeAreaProvider
          initialMetrics={{
            frame: { x: 0, y: 0, width: 393, height: 852 },
            insets: { top: 59, bottom: 34, left: 0, right: 0 },
          }}>
          <CommandPaletteProvider>
            <Inbox
              composing={undefined}
              onCompose={() => undefined}
              onSelect={(selection) => {
                opened.push(selection);
              }}
              selected={undefined}
              // The Outbox chosen in Mailboxes, which lists the responses while they wait.
              view={outboxView}
              outboxShown={outboxShown}
            />
          </CommandPaletteProvider>
        </SafeAreaProvider>
      </mail.Providers>
    );
    const app = await render(list());
    try {
      // One response delivery is unknown, the other waits out its window.
      mail.imap.smtp.lost = true;
      await act(async () => {
        await responses.respond(
          await offerOf(mail.inbox, release),
          'accepted',
          english,
        );
      });
      await mail.deliver();
      await act(async () => {
        await responses.respond(
          await offerOf(mail.inbox, roadmap),
          'declined',
          english,
        );
      });

      await expect(
        screen.findByText('Invitation response · Decline'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('Q4 roadmap review')).toBeOnTheScreen();
      expect(
        screen.getByText('Undo available. Waiting to send.'),
      ).toBeOnTheScreen();
      expect(screen.getByText('Release readiness')).toBeOnTheScreen();
      expect(
        screen.getByText(
          'Delivery unknown. The mail server hasn’t confirmed this response.',
        ),
      ).toBeOnTheScreen();
      expect(screen.getAllByRole('button', { name: 'Undo' })).toHaveLength(1);
      expect(
        screen.getAllByRole('button', { name: 'Check Again' }),
      ).toHaveLength(1);
      expect(
        screen.getAllByRole('button', { name: 'Open Invitation' }),
      ).toHaveLength(2);
      expect(screen.queryByRole('button', { name: 'Edit' })).toBeNull();

      // Open Invitation opens the invitation message it answers; the older row comes first.
      const [, open] = screen.getAllByRole('button', {
        name: 'Open Invitation',
      });
      await act(async () => {
        await fireEvent.press(
          present(open, 'the waiting row’s Open Invitation'),
        );
      });
      expect(opened).toStrictEqual([{ mailbox: mara.id, id: roadmap }]);

      // A refused Undo keeps the row waiting, and Try Again takes Undo's place.
      mail.storage.failNextCommit('locked');
      await press('Undo');
      expect(
        screen.getByText('Couldn’t undo. Still waiting to send.'),
      ).toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Undo' })).toBeNull();

      // Try Again removes the waiting response without a Draft.
      await press('Try Again');
      expect(screen.queryByText('Invitation response · Decline')).toBeNull();
      expect(mail.outbox.getSnapshot()).toHaveLength(1);

      // A search hides the Outbox; View in Outbox ends it, so the rows show again.
      expect(screen.queryByRole('button', { name: 'Close Search' })).toBeNull();
      await fireEvent.changeText(
        await screen.findByLabelText('Search senders and subjects'),
        'roadmap',
      );
      expect(screen.queryByText('Release readiness')).toBeNull();
      expect(
        screen.getByRole('button', { name: 'Close Search' }),
      ).toBeOnTheScreen();
      // The section each scroll targets, read from the list as it stood then.
      const targets: unknown[] = [];
      const scroll = jest
        .spyOn(SectionList.prototype, 'scrollToLocation')
        .mockImplementation(function (this: SectionList, { sectionIndex }) {
          targets.push(this.props.sections[sectionIndex]?.key);
        });
      await app.rerender(list({}));
      expect(screen.getByText('Release readiness')).toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Close Search' })).toBeNull();
      // It scrolls only once the search has ended and the Outbox is listed again.
      expect(scroll.mock.calls).toStrictEqual([
        [{ sectionIndex: 0, itemIndex: 0 }],
      ]);
      expect(targets).toStrictEqual(['outbox']);
      scroll.mockRestore();

      // Check Again finds the response in Sent and keeps it, without sending it again.
      const [sent] = mail.imap.smtp.accepted;
      mail.imap.deliver('Sent', {
        subject: 'Accepted: Release readiness',
        raw: present(sent, 'the submitted response').raw,
      });
      await press('Check Again');
      await waitFor(() => {
        expect(mail.outbox.getSnapshot()).toStrictEqual([]);
      });
      expect(screen.queryByText('Release readiness')).toBeNull();
      expect(mail.imap.smtp.accepted).toHaveLength(1);
    } finally {
      await app.unmount();
      mail.outbox.dispose();
    }
  });
});
