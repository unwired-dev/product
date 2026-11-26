import type { Unsubscribe } from '@private-email/mail-core/unsubscribe';

import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { InboxProvider, MailboxScope, ProfileScope } from '../src/mailbox.tsx';
import { MessageBody } from '../src/message-body.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import {
  UnsubscribeContext,
  useUnsubscribeItems,
} from '../src/unsubscribe.tsx';

const me = 'mara@example.invalid';
const oneClick = {
  'List-Id': 'Alza.cz newsletter <newsletter.alza.example>',
  'List-Unsubscribe': '<https://alza.example/u/42>',
  'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
};
const receivedAt = Date.UTC(2026, 10, 20, 9);
const sentAt = Date.UTC(2026, 10, 8, 9);

// The More menu's items for the reader's message, as a list of titles.
function MoreMenu({
  inbox,
  id,
  onItems,
}: {
  readonly inbox: ReturnType<typeof createInboxStore>;
  readonly id: string;
  readonly onItems: (items: ReturnType<typeof useUnsubscribeItems>) => void;
}) {
  onItems(useUnsubscribeItems(inbox, id));
  return null;
}

// The reader showing a message with `headers` from a synthetic Gmail mailbox, whose unsubscribe
// requests end as `outcomes` says, in turn. Only the native request and its record are substituted.
async function opened(
  headers: Readonly<Record<string, string>>,
  outcomes: ReadonlyArray<() => Promise<'sent' | 'failed' | 'uncertain'>>,
  recorded?: number,
) {
  const gmail = createSyntheticGmail({ address: me });
  const id = gmail.deliver({
    from: 'Alza.cz <news@alza.example>',
    subject: 'Black Friday',
    headers,
    content: { text: 'This week only.' },
  });
  const inbox = createInboxStore(gmail.native);
  await inbox.load();
  // Outcomes outlive a reader for the app's lifetime, so each test opens its own connection.
  const connection = `gmail-${crypto.randomUUID()}`;
  const requests: string[] = [];
  const unsubscribe: Unsubscribe = {
    sentRequest: (profile, offer) =>
      Promise.resolve(
        recorded === undefined || offer.identity === undefined
          ? undefined
          : { profile, identity: offer.identity, list: offer.list, sentAt },
      ),
    request: (profile) => {
      requests.push(profile);
      return outcomes[requests.length - 1]?.() ?? Promise.resolve('failed');
    },
  };
  const mailboxes = [
    {
      provider: 'gmail' as const,
      address: me,
      profile: 'default',
      id: connection,
      inbox,
      state: inbox.getSnapshot(),
    },
  ];
  let menu: ReturnType<typeof useUnsubscribeItems> = [];
  await render(
    <AccountContext
      value={{
        mailboxes: [],
        openAccount: () => undefined,
        authorizeMailbox: () => Promise.resolve(),
        refreshInbox: (load) => load(),
        account: 'synthetic-product-account',
        profiles: [],
        createProfile: () => Promise.resolve(undefined),
        chooseFolders: () => Promise.resolve(true),
      }}>
      <UnsubscribeContext value={unsubscribe}>
        <InboxProvider
          mailboxes={{
            getSnapshot: () => mailboxes,
            subscribe: () => () => undefined,
            load: () => Promise.resolve(),
          }}>
          <ProfileScope profile="default">
            <MailboxScope id={connection}>
              <MoreMenu
                inbox={inbox}
                id={id}
                onItems={(items) => {
                  menu = items;
                }}
              />
              <MessageBody
                inbox={inbox}
                id={id}
                connection={connection}
                message={{
                  name: 'Alza.cz',
                  address: 'news@alza.example',
                  receivedAt,
                }}
              />
            </MailboxScope>
          </ProfileScope>
        </InboxProvider>
      </UnsubscribeContext>
    </AccountContext>,
  );
  await screen.findByText('This week only.');
  return { requests, menu: () => menu };
}

const press = async (name: string) => {
  await fireEvent.press(screen.getByRole('button', { name }));
};

describe('the reader’s one-click Unsubscribe', () => {
  it('names the list and the receiving address, and Cancel sends nothing', async () => {
    expect.hasAssertions();
    const { requests, menu } = await opened(oneClick, []);
    expect(screen.getByText('Alza.cz newsletter')).toBeOnTheScreen();
    expect(menu().map(({ title }) => title)).toStrictEqual(['Unsubscribe…']);

    await press('Unsubscribe…');
    expect(
      screen.getByText(
        'Unwired sends Alza.cz an unsubscribe request from mara@example.invalid. It can take a few days to stop. Mail you already have stays.',
      ),
    ).toBeOnTheScreen();
    await press('Cancel');
    expect(requests).toStrictEqual([]);
  });

  it('sends once from the More menu’s confirmation, then shows that it was sent', async () => {
    expect.hasAssertions();
    const { requests, menu } = await opened(oneClick, [
      () => Promise.resolve('sent'),
    ]);
    await act(() => {
      menu()[0]?.run?.();
    });
    await press('Unsubscribe');
    await expect(
      screen.findByText('Unsubscribe request sent'),
    ).resolves.toBeOnTheScreen();
    expect(requests).toStrictEqual(['default']);
    expect(screen.queryByRole('button', { name: 'Try Again' })).toBeNull();
    expect(menu()).toStrictEqual([]);
  });

  it('offers Try Again after a failed or uncertain request, without asking again', async () => {
    expect.hasAssertions();
    const { requests } = await opened(oneClick, [
      () => Promise.resolve('failed'),
      () => Promise.resolve('uncertain'),
      () => Promise.resolve('sent'),
    ]);
    await press('Unsubscribe…');
    await press('Unsubscribe');
    await expect(
      screen.findByText(
        'Alza.cz didn’t accept it. Try again later, or block the sender instead.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(
      screen.getByRole('button', { name: 'Block Sender…' }),
    ).toBeOnTheScreen();

    await press('Try Again');
    await expect(
      screen.findByText('No clear answer to the request'),
    ).resolves.toBeOnTheScreen();
    await press('Try Again');
    await expect(
      screen.findByText('Unsubscribe request sent'),
    ).resolves.toBeOnTheScreen();
    expect(requests).toHaveLength(3);
  });

  it('shows a request the Profile sent in the last 14 days, dated', async () => {
    expect.hasAssertions();
    const { requests } = await opened(oneClick, [], sentAt);
    await expect(
      screen.findByText(
        'To Alza.cz on Nov 8. If their mail keeps coming after 14 days, you can try again.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    expect(requests).toStrictEqual([]);
  });

  it('offers nothing for a mailto-only message', async () => {
    expect.hasAssertions();
    const { menu } = await opened(
      {
        'List-Id': oneClick['List-Id'],
        'List-Unsubscribe': '<mailto:leave@alza.example>',
      },
      [],
    );
    expect(screen.queryByText('Alza.cz newsletter')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    expect(menu()).toStrictEqual([]);
  });
});
