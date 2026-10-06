import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useLayoutEffect } from 'react';
import { Clipboard, Linking } from 'react-native';

import {
  GmailMessageBody,
  LinkConfirmationProvider,
} from '../src/message-body.tsx';

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

// These are rendered host/store tests. Only WebKit and the native clipboard/opener are substituted.
describe('queued message link privacy', () => {
  it.each(['forget', 'message', 'account', 'unmount'] as const)(
    'never reveals queued keyboard or WebKit links after %s',
    async (transition) => {
      expect.hasAssertions();
      const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
      const copy = jest
        // oxlint-disable-next-line typescript/no-deprecated -- Tests the existing core Clipboard boundary in both hosts.
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
        expect(screen.getByText(oldHref)).toBeVisible();
        const queuedCopy = pressHandler(
          screen.getByRole('button', { name: 'Copy link' }),
        );
        const queuedProceed = pressHandler(
          screen.getByRole('button', { name: 'Proceed' }),
        );
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
        expect(screen.queryByText(oldHref)).toBeNull();
        await act(() => {
          queuedPress();
          queuedNavigation({
            url: 'about:blank#unwired-link-0',
            navigationType: 'click',
          });
        });
        expect({
          url: screen.queryByText(oldHref),
          copy: screen.queryByRole('button', { name: 'Copy link' }),
          proceed: screen.queryByRole('button', { name: 'Proceed' }),
        }).toStrictEqual({ url: null, copy: null, proceed: null });
        await act(() => {
          queuedCopy();
          queuedProceed();
        });
        expect({
          copied: copy.mock.calls,
          opened: open.mock.calls,
        }).toStrictEqual({ copied: [], opened: [] });
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
describe('message link ownership at commit', () => {
  it.each(['message', 'account'] as const)(
    'hides the old destination and rejects queued input before passive cleanup after %s changes',
    async (transition) => {
      expect.hasAssertions();
      const open = jest.spyOn(Linking, 'openURL').mockResolvedValue(true);
      const copy = jest
        // oxlint-disable-next-line typescript/no-deprecated -- Exercises the retained native clipboard boundary.
        .spyOn(Clipboard, 'setString')
        .mockReturnValue(undefined);
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({
        content: { html: `<a href="${oldHref}">https://bank.invalid</a>` },
      });
      const next = gmail.deliver({
        content: { html: '<p>Another message</p>' },
      });
      const store = createGmailInbox(gmail.native);
      const other = createSyntheticGmail({
        address: 'another@example.invalid',
      });
      const sameId = other.deliver({
        content: { html: '<p>Another owner</p>' },
      });
      const otherStore = createGmailInbox(other.native);
      await store.load();
      await otherStore.load();
      const app = await render(
        <LinkConfirmationProvider
          inbox={store}
          id={id}>
          <GmailMessageBody
            inbox={store}
            id={id}
          />
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
          screen.getByRole('link', { name: 'Open link: https://bank.invalid' }),
        );
        const queuedCopy = pressHandler(
          screen.getByRole('button', { name: 'Copy link' }),
        );
        const queuedProceed = pressHandler(
          screen.getByRole('button', { name: 'Proceed' }),
        );
        const observations: Array<{ href: boolean; retained: boolean }> = [];
        const replacement = {
          message: { store, id: next },
          account: { store: otherStore, id: sameId },
        }[transition];
        await app.rerender(
          <LinkConfirmationProvider
            inbox={replacement.store}
            id={replacement.id}>
            <GmailMessageBody
              inbox={replacement.store}
              id={replacement.id}
            />
            <CommitProbe
              inspect={() => {
                observations.push({
                  href: JSON.stringify(app.toJSON()).includes(oldHref),
                  retained: store.messageBody(id)?.kind === 'ready',
                });
                queuedPress();
                queuedNavigation({
                  url: 'about:blank#unwired-link-0',
                  navigationType: 'click',
                });
                queuedCopy();
                queuedProceed();
              }}
            />
          </LinkConfirmationProvider>,
        );
        expect({
          observations,
          copied: copy.mock.calls,
          opened: open.mock.calls,
        }).toStrictEqual({
          observations: [{ href: false, retained: true }],
          copied: [],
          opened: [],
        });
        expect(screen.queryByText(oldHref)).toBeNull();
      } finally {
        await app.unmount();
        copy.mockRestore();
        open.mockRestore();
      }
    },
  );
});
