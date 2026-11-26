import type {
  SentUnsubscribeRequest,
  Unsubscribe,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';
import type { ReactNode } from 'react';

import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useState } from 'react';

import { InboxProvider, MailboxScope, ProfileScope } from '../src/mailbox.tsx';
import { MessageBody } from '../src/message-body.tsx';
import { AccountContext } from '../src/registration-gate.tsx';
import { UnsubscribeContext, useUnsubscribeMenu } from '../src/unsubscribe.tsx';

const me = 'mara@example.invalid';
const profile = 'work';
const oneClick = {
  'List-Id': 'Alza.cz newsletter <newsletter.alza.example>',
  'List-Unsubscribe': '<https://alza.example/u/42>',
  'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
};
const receivedAt = Date.UTC(2026, 10, 20, 9);
const sentAt = Date.UTC(2026, 10, 8, 9);
const confirmation =
  'Unwired sends Alza.cz an unsubscribe request from mara@example.invalid. It can take a few days to stop. Mail you already have stays.';

type Menu = ReturnType<typeof useUnsubscribeMenu>['items'];

// The reader of `ids[shown]` with the More menu's Unsubscribe items and confirmation beside it.
function Reader({
  inbox,
  ids,
  connection,
  onMenu,
  onShow,
}: {
  readonly inbox: ReturnType<typeof createInboxStore>;
  readonly ids: readonly string[];
  readonly connection: string;
  readonly onMenu: (items: Menu) => void;
  readonly onShow: (show: (index: number) => void) => void;
}) {
  const [shown, setShown] = useState(0);
  onShow(setShown);
  const id = ids[shown] ?? '';
  const { items, confirmation: confirm } = useUnsubscribeMenu(inbox, id);
  onMenu(items);
  return (
    <>
      {confirm('Alza.cz')}
      <MessageBody
        key={id}
        inbox={inbox}
        id={id}
        connection={connection}
        message={{
          name: 'Alza.cz',
          address: 'news@alza.example',
          receivedAt,
        }}
      />
    </>
  );
}

// The reader showing the first of `count` messages with `headers` from a synthetic Gmail mailbox,
// in the `work` Profile. Each request ends as `outcomes` says, and each stored-request lookup answers
// as `stored` says, in turn; later ones find none. Only the native request and its record are
// substituted.
async function opened({
  headers = oneClick,
  outcomes = [],
  stored = [],
  count = 1,
}: Readonly<{
  headers?: Readonly<Record<string, string>>;
  outcomes?: ReadonlyArray<() => Promise<UnsubscribeOutcome>>;
  stored?: ReadonlyArray<Promise<SentUnsubscribeRequest | undefined>>;
  count?: number;
}> = {}) {
  const gmail = createSyntheticGmail({ address: me });
  const ids = Array.from({ length: count }, () =>
    gmail.deliver({
      from: 'Alza.cz <news@alza.example>',
      subject: 'Black Friday',
      headers,
      content: { text: 'This week only.' },
    }),
  );
  const inbox = createInboxStore(gmail.native);
  await inbox.load();
  // Outcomes outlive a reader for the app's lifetime, so each test opens its own connection.
  const connection = `gmail-${crypto.randomUUID()}`;
  const requests: string[] = [];
  const lookups: unknown[] = [];
  const unsubscribe: Unsubscribe = {
    sentRequest: (owner, offer, at) => {
      lookups.push([owner, offer.identity, at]);
      return stored[lookups.length - 1] ?? Promise.resolve(undefined);
    },
    request: (owner) => {
      requests.push(owner);
      return outcomes[requests.length - 1]?.() ?? Promise.resolve('failed');
    },
    record: () => Promise.resolve(),
  };
  const mailboxes = [
    {
      provider: 'gmail' as const,
      address: me,
      profile,
      id: connection,
      inbox,
      state: inbox.getSnapshot(),
    },
  ];
  let menu: Menu = [];
  let show: (index: number) => void = () => undefined;
  const scoped = (children: ReactNode) => (
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
          <ProfileScope profile={profile}>
            <MailboxScope id={connection}>{children}</MailboxScope>
          </ProfileScope>
        </InboxProvider>
      </UnsubscribeContext>
    </AccountContext>
  );
  await render(
    scoped(
      <Reader
        inbox={inbox}
        ids={ids}
        connection={connection}
        onMenu={(items) => {
          menu = items;
        }}
        onShow={(setShown) => {
          show = setShown;
        }}
      />,
    ),
  );
  await screen.findByText('This week only.');
  return {
    requests,
    lookups,
    menu: () => menu,
    show: async (index: number) => {
      await act(() => {
        show(index);
      });
      await screen.findByText('This week only.');
    },
  };
}

// A promise the test settles.
function deferred<T>() {
  let settle: (value: T) => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Hold the answer until the test settles it.
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });
  return { promise, resolve: settle };
}

// Whether the banner's Unsubscribe… is disabled.
const unsubscribeState = () =>
  screen.getByRole('button', { name: 'Unsubscribe…' }).props.accessibilityState;

const press = async (name: string) => {
  await fireEvent.press(screen.getByRole('button', { name }));
};

// A request in the `work` Profile sent before the message arrived.
const record = (owner: string) => ({
  profile: owner,
  identity: 'newsletter.alza.example',
  list: 'Alza.cz newsletter',
  sentAt,
});

describe('the reader’s one-click Unsubscribe', () => {
  it('names the list and the receiving address, and Cancel sends nothing', async () => {
    expect.hasAssertions();
    const { requests, menu } = await opened();
    await expect(
      screen.findByRole('button', { name: 'Unsubscribe…' }),
    ).resolves.toBeOnTheScreen();
    expect(screen.getByText('Alza.cz newsletter')).toBeOnTheScreen();
    expect(menu().map(({ title }) => title)).toStrictEqual(['Unsubscribe…']);

    await press('Unsubscribe…');
    expect(screen.getByText(confirmation)).toBeOnTheScreen();
    await press('Cancel');
    expect(requests).toStrictEqual([]);
  });

  it('sends once from the More menu’s confirmation, then shows that it was sent', async () => {
    expect.hasAssertions();
    const { requests, menu } = await opened({
      outcomes: [() => Promise.resolve('sent')],
    });
    await screen.findByRole('button', { name: 'Unsubscribe…' });
    await act(() => {
      menu()[0]?.run?.();
    });
    await press('Unsubscribe');
    await expect(
      screen.findByText('Unsubscribe request sent'),
    ).resolves.toBeOnTheScreen();
    expect(requests).toStrictEqual([profile]);
    expect(screen.queryByRole('button', { name: 'Try Again' })).toBeNull();
    expect(menu()).toStrictEqual([]);
  });

  it('offers Try Again after a failed or uncertain request, without asking again', async () => {
    expect.hasAssertions();
    const { requests } = await opened({
      outcomes: [
        () => Promise.resolve('failed'),
        () => Promise.resolve('uncertain'),
        () => Promise.resolve('sent'),
      ],
    });
    await screen.findByRole('button', { name: 'Unsubscribe…' });
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

  it('shows the Profile’s request sent in the last 14 days, dated', async () => {
    expect.hasAssertions();
    const { requests, lookups } = await opened({
      stored: [Promise.resolve(record(profile))],
    });
    await expect(
      screen.findByText(
        'To Alza.cz on Nov 8. If their mail keeps coming after 14 days, you can try again.',
      ),
    ).resolves.toBeOnTheScreen();
    expect(lookups).toStrictEqual([
      [profile, 'newsletter.alza.example', receivedAt],
    ]);
    expect(screen.queryByRole('button', { name: 'Unsubscribe…' })).toBeNull();
    expect(requests).toStrictEqual([]);
  });

  it('shows a recorded request emailed to the list as emailed, in Sent', async () => {
    expect.hasAssertions();
    await opened({
      stored: [
        Promise.resolve({ ...record(profile), to: 'leave@alza.example' }),
      ],
    });
    await expect(
      screen.findByText(
        'Emailed to leave@alza.example on Nov 8. It’s in Sent. If their mail keeps coming after 14 days, you can try again.',
      ),
    ).resolves.toBeOnTheScreen();
  });

  it('offers nothing until the stored request is known', async () => {
    expect.hasAssertions();
    const lookup = deferred<undefined>();
    const { menu } = await opened({ stored: [lookup.promise] });
    expect(unsubscribeState()).toStrictEqual({ disabled: true });
    expect(menu()).toStrictEqual([]);

    await act(() => {
      lookup.resolve(undefined);
    });
    expect(unsubscribeState()).toStrictEqual({ disabled: false });
  });

  it('looks the stored request up again when the message is opened again', async () => {
    expect.hasAssertions();
    const again = deferred<SentUnsubscribeRequest>();
    const { requests, menu, show } = await opened({
      count: 2,
      stored: [
        Promise.resolve(undefined),
        Promise.resolve(undefined),
        again.promise,
      ],
    });
    await screen.findByRole('button', { name: 'Unsubscribe…' });
    await act(() => {
      menu()[0]?.run?.();
    });
    await show(1);
    await show(0);
    expect(unsubscribeState()).toStrictEqual({ disabled: true });
    expect(screen.queryByText(confirmation)).toBeNull();

    await act(() => {
      again.resolve(record(profile));
    });
    expect(screen.getByText('Unsubscribe request sent')).toBeOnTheScreen();
    expect(requests).toStrictEqual([]);
  });

  it('ignores an earlier lookup that answers after the message was opened again', async () => {
    expect.hasAssertions();
    const first = deferred<undefined>();
    const again = deferred<undefined>();
    const { menu, show } = await opened({
      count: 2,
      stored: [first.promise, Promise.resolve(undefined), again.promise],
    });
    await show(1);
    await show(0);
    await act(() => {
      first.resolve(undefined);
    });
    expect(unsubscribeState()).toStrictEqual({ disabled: true });
    expect(menu()).toStrictEqual([]);

    await act(() => {
      again.resolve(undefined);
    });
    expect(unsubscribeState()).toStrictEqual({ disabled: false });
  });

  it('closes another open confirmation once the request was sent', async () => {
    expect.hasAssertions();
    const { requests, menu } = await opened({
      outcomes: [() => Promise.resolve('sent')],
    });
    await screen.findByRole('button', { name: 'Unsubscribe…' });
    await press('Unsubscribe…');
    await act(() => {
      menu()[0]?.run?.();
    });
    await fireEvent.press(
      screen.getAllByRole('button', { name: 'Unsubscribe' })[0]!,
    );
    await screen.findByText('Unsubscribe request sent');
    expect(screen.queryByRole('button', { name: 'Unsubscribe' })).toBeNull();
    expect(requests).toStrictEqual([profile]);
  });

  it('shows a late result only on the message it was sent from', async () => {
    expect.hasAssertions();
    const request = deferred<UnsubscribeOutcome>();
    const { show } = await opened({
      count: 2,
      outcomes: [() => request.promise],
    });
    await screen.findByRole('button', { name: 'Unsubscribe…' });
    await press('Unsubscribe…');
    await press('Unsubscribe');
    await show(1);
    await act(() => {
      request.resolve('sent');
    });
    expect(screen.queryByText('Unsubscribe request sent')).toBeNull();

    await show(0);
    await expect(
      screen.findByText('Unsubscribe request sent'),
    ).resolves.toBeOnTheScreen();
  });
});
