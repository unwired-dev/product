import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import Clipboard from '@react-native-clipboard/clipboard';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useLayoutEffect } from 'react';
import { Linking, View } from 'react-native';

import { ImapMessageBody } from '../src/imap-message-body.tsx';
import {
  GmailMessageBody,
  LinkConfirmationProvider,
} from '../src/message-body.tsx';
import { chooseSheetButton, sheetShown } from './native-alert.ts';

// Capture the application callback through the same composite-fiber boundary as fireEvent.
// Host nodes expose responder handlers rather than the Pressable's onPress prop.
const pressHandler = (
  element: Parameters<typeof fireEvent.press>[0],
): (() => void) => {
  let fiber = element.unstable_fiber;
  while (fiber !== null) {
    const handler = fiber.memoizedProps?.onPress;
    if (typeof handler === 'function') {
      return () => {
        handler();
      };
    }
    fiber = fiber.return;
  }
  throw new Error('Expected a rendered press handler');
};

function CommitProbe({ inspect }: { readonly inspect: () => void }) {
  useLayoutEffect(inspect, [inspect]);
  return null;
}

const oldHref = 'https://phish.invalid/private?ticket=synthetic-secret';
const view = (store: ReturnType<typeof createGmailInbox>, id: string) => (
  <LinkConfirmationProvider
    inbox={store}
    id={id}>
    <GmailMessageBody
      inbox={store}
      id={id}
    />
  </LinkConfirmationProvider>
);

const linkMailbox = (
  provider: 'gmail' | 'imap',
  address = 'alex@example.invalid',
) => {
  if (provider === 'imap') {
    const native = createSyntheticImap({ address });
    return {
      store: createImapInbox(native.native),
      deliver: (html: string) =>
        `7.${native.deliver('INBOX', {
          subject: 'Synthetic link message',
          raw: `Content-Type: text/html; charset=utf-8\r\n\r\n${html}`,
        })}.INBOX`,
    };
  }
  const native = createSyntheticGmail({ address });
  return {
    store: createGmailInbox(native.native),
    deliver: (html: string) => native.deliver({ content: { html } }),
  };
};

const reader = (store: ReturnType<typeof linkMailbox>['store'], id: string) =>
  'openFolder' in store ? (
    <ImapMessageBody
      inbox={store}
      id={id}
    />
  ) : (
    <GmailMessageBody
      inbox={store}
      id={id}
    />
  );

// These are rendered host/store tests. Only WebKit and the native clipboard/opener are substituted.
describe('queued message link privacy', () => {
  it.each([
    {
      kind: 'ordinary',
      text: 'the plan',
      question: {
        title: 'Open this link in your browser?',
        detail: '',
        buttons: ['Open link', 'Cancel'],
        symbol: { name: 'link' },
      },
      opens: 'Open link',
    },
    {
      kind: 'caution',
      text: 'https://bank.invalid',
      question: {
        title: 'This link may not be what it seems',
        buttons: ['Cancel', 'Copy link', 'Proceed'],
        cancel: 0,
        destructive: 2,
        symbol: { name: 'exclamationmark.shield' },
      },
      opens: 'Proceed',
    },
  ])(
    'asks about the $kind link in a sheet that opens only on its choice',
    async ({ text, question, opens }) => {
      expect.hasAssertions();
      const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        content: { html: `<a href="${oldHref}">${text}</a>` },
      });
      const store = createGmailInbox(gmail.native);
      await store.load();
      const app = await render(view(store, id));
      try {
        const link = screen.getByRole('link', { name: `Open link: ${text}` });
        await fireEvent.press(link);
        expect(sheetShown()).toMatchObject({ ...question, passage: oldHref });
        await act(() => {
          chooseSheetButton('Cancel');
        });
        expect(sheetShown()).toBeUndefined();
        await fireEvent.press(link);
        await act(() => {
          chooseSheetButton(opens);
        });
        expect(open.mock.calls).toStrictEqual([[oldHref]]);
      } finally {
        await app.unmount();
        open.mockRestore();
      }
    },
  );

  it('lists every warning before the caution destination', async () => {
    expect.hasAssertions();
    const href = 'http://user@127.0.0.1/?next=https%3A%2F%2Fother.invalid';
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: { html: `<a href="${href}">https://bank.invalid</a>` },
    });
    const store = createGmailInbox(gmail.native);
    await store.load();
    const app = await render(view(store, id));
    try {
      await fireEvent.press(
        screen.getByRole('link', { name: 'Open link: https://bank.invalid' }),
      );
      expect(sheetShown()).toMatchObject({
        passage: href,
        detail: [
          'Check this link before opening it:',
          '• The link text shows a different address.',
          '• The link text shows a secure address, but the link is not secure.',
          '• The address is a numeric IP address.',
          '• The address contains a user name or password.',
          '• The address forwards to another site.',
        ].join('\n'),
      });
    } finally {
      await app.unmount();
    }
  });

  it('copies the inspected destination through the native Clipboard', async () => {
    expect.hasAssertions();
    const copy = jest.spyOn(Clipboard, 'setString').mockReturnValue(undefined);
    const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: { html: `<a href="${oldHref}">https://bank.invalid</a>` },
    });
    const store = createGmailInbox(gmail.native);
    await store.load();
    await render(view(store, id));
    try {
      await fireEvent.press(
        screen.getByRole('link', { name: 'Open link: https://bank.invalid' }),
      );
      await act(() => {
        chooseSheetButton('Copy link');
      });
      expect(copy).toHaveBeenCalledWith(oldHref);
      expect(open).not.toHaveBeenCalled();
    } finally {
      copy.mockRestore();
      open.mockRestore();
    }
  });

  it.each(['forget', 'message', 'account', 'unmount'] as const)(
    'never reveals queued keyboard or WebKit links after %s',
    async (transition) => {
      expect.hasAssertions();
      const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
      const copy = jest
        .spyOn(Clipboard, 'setString')
        .mockReturnValue(undefined);
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        at: Date.UTC(2020, 0, 1),
        content: { html: `<a href="${oldHref}">https://bank.invalid</a>` },
      });
      const next = gmail.deliver({
        at: Date.UTC(2020, 0, 1),
        content: { html: '<p>Another message</p>' },
      });
      const store = createGmailInbox(gmail.native);
      const other = createSyntheticGmail({
        address: 'another@example.invalid',
      });
      const otherId = other.deliver({
        at: Date.UTC(2020, 0, 1),
        content: { html: '<p>Another owner</p>' },
      });
      const otherStore = createGmailInbox(other.native);
      await store.load();
      await otherStore.load();
      const app = await render(view(store, id));
      try {
        const link = await screen.findByRole('link', {
          name: 'Open link: https://bank.invalid',
        });
        const queuedPress = pressHandler(link);
        const queuedNavigation =
          screen.getByTestId('message-webview').props
            .onShouldStartLoadWithRequest;
        await fireEvent.press(link);
        expect(sheetShown()?.passage).toBe(oldHref);
        const transitions = {
          forget: async () => {
            await act(() => store.forget());
          },
          message: async () => {
            await app.rerender(view(store, next));
          },
          account: async () => {
            await app.rerender(view(otherStore, otherId));
          },
          unmount: async () => {
            await app.rerender(
              <LinkConfirmationProvider
                inbox={store}
                id={id}>
                {null}
              </LinkConfirmationProvider>,
            );
          },
        };
        await transitions[transition]();
        expect(sheetShown()).toBeUndefined();
        await act(() => {
          queuedPress();
          queuedNavigation({
            url: 'about:blank#unwired-link-0',
            navigationType: 'click',
          });
        });
        expect({
          sheet: sheetShown(),
          copied: copy.mock.calls,
          opened: open.mock.calls,
        }).toStrictEqual({ sheet: undefined, copied: [], opened: [] });
      } finally {
        await app.unmount();
        copy.mockRestore();
        open.mockRestore();
      }
    },
  );
});

// A layout probe observes the committed host tree and delivers queued input before passive
// retainMessage cleanup. Awaiting rerender alone would erase this regression window.
describe.each(['gmail', 'imap'] as const)(
  '%s message link ownership at commit',
  (provider) => {
    it.each(['message', 'account'] as const)(
      'keeps the replacement reader confirmation through old passive cleanup after %s changes',
      async (transition) => {
        expect.hasAssertions();
        const mailbox = linkMailbox(provider);
        const id = mailbox.deliver(
          `<a href="${oldHref}">https://bank.invalid</a>`,
        );
        const nextHref = 'https://next.invalid/reader';
        const next = mailbox.deliver(`<a href="${nextHref}">Next link</a>`);
        const other = linkMailbox(provider, 'another@example.invalid');
        const sameId = other.deliver(`<a href="${nextHref}">Next link</a>`);
        await mailbox.store.load();
        await other.store.load();
        const replacement = {
          message: { store: mailbox.store, id: next },
          account: { store: other.store, id: sameId },
        }[transition];
        const app = await render(
          <LinkConfirmationProvider
            inbox={mailbox.store}
            id={id}>
            <View key="old">{reader(mailbox.store, id)}</View>
            <View key="replacement">
              {reader(replacement.store, replacement.id)}
            </View>
          </LinkConfirmationProvider>,
        );
        try {
          expect(sameId).toBe(id);
          await screen.findByRole('link', {
            name: 'Open link: https://bank.invalid',
          });
          const chooseNext = pressHandler(
            await screen.findByRole('link', { name: 'Open link: Next link' }),
          );
          const retainedAtCommit: boolean[] = [];
          await app.rerender(
            <LinkConfirmationProvider
              inbox={replacement.store}
              id={replacement.id}>
              <View key="replacement">
                {reader(replacement.store, replacement.id)}
              </View>
              <CommitProbe
                inspect={() => {
                  retainedAtCommit.push(
                    mailbox.store.messageBody(id)?.kind === 'ready',
                  );
                  chooseNext();
                }}
              />
            </LinkConfirmationProvider>,
          );
          expect(retainedAtCommit).toStrictEqual([true]);
          expect(sheetShown()?.passage).toBe(nextHref);
          await act(() => {
            chooseSheetButton('Cancel');
          });
          expect(sheetShown()).toBeUndefined();
        } finally {
          await app.unmount();
        }
      },
    );

    it.each([
      ['message', 'Copy link'],
      ['message', 'Proceed'],
      ['account', 'Copy link'],
      ['account', 'Proceed'],
    ] as const)(
      'withdraws the old sheet and rejects queued input and a %s-change %s answer',
      async (transition, choice) => {
        expect.hasAssertions();
        const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
        const copy = jest
          .spyOn(Clipboard, 'setString')
          .mockReturnValue(undefined);
        const mailbox = linkMailbox(provider);
        const id = mailbox.deliver(
          `<a href="${oldHref}">https://bank.invalid</a>`,
        );
        const next = mailbox.deliver('<p>Another message</p>');
        const { store } = mailbox;
        const other = linkMailbox(provider, 'another@example.invalid');
        const sameId = other.deliver('<p>Another owner</p>');
        const otherStore = other.store;
        await store.load();
        await otherStore.load();
        const app = await render(
          <LinkConfirmationProvider
            inbox={store}
            id={id}>
            {reader(store, id)}
            <CommitProbe inspect={() => undefined} />
          </LinkConfirmationProvider>,
        );
        try {
          expect(sameId).toBe(id);
          const queuedPress = pressHandler(
            await screen.findByRole('link', {
              name: 'Open link: https://bank.invalid',
            }),
          );
          const queuedNavigation =
            screen.getByTestId('message-webview').props
              .onShouldStartLoadWithRequest;
          await fireEvent.press(
            screen.getByRole('link', {
              name: 'Open link: https://bank.invalid',
            }),
          );
          const retained: boolean[] = [];
          const replacement = {
            message: { store, id: next },
            account: { store: otherStore, id: sameId },
          }[transition];
          await app.rerender(
            <LinkConfirmationProvider
              inbox={replacement.store}
              id={replacement.id}>
              {reader(replacement.store, replacement.id)}
              <CommitProbe
                inspect={() => {
                  retained.push(store.messageBody(id)?.kind === 'ready');
                  queuedPress();
                  queuedNavigation({
                    url: 'about:blank#unwired-link-0',
                    navigationType: 'click',
                  });
                  // Native resolves now; the async answer continuation may run after withdrawal.
                  chooseSheetButton(choice);
                }}
              />
            </LinkConfirmationProvider>,
          );
          expect({
            retained,
            sheet: sheetShown(),
            copied: copy.mock.calls,
            opened: open.mock.calls,
          }).toStrictEqual({
            retained: [true],
            sheet: undefined,
            copied: [],
            opened: [],
          });
        } finally {
          await app.unmount();
          copy.mockRestore();
          open.mockRestore();
        }
      },
    );
  },
);
