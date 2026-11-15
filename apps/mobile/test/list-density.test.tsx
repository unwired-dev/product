import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { ReactElement } from 'react';
import type { useWindowDimensions } from 'react-native';

import { fixtureMessages } from '@private-email/mail-core';
import { createInboxPreferences } from '@private-email/mail-core/inbox-preferences';
import { defaultProfile } from '@private-email/mail-core/registration';
import { fireEvent, render, waitFor } from '@testing-library/react-native';

import { MessageRow } from '../src/inbox-rows.tsx';
import {
  InboxPreferencesContext,
  ListDensitySettings,
} from '../src/list-density.tsx';

const message = fixtureMessages[0]!;

// Inbox preferences kept for one signed-in Product Account, as native storage keeps them.
const preferences = () => {
  const kept = { revision: 0, document: null as string | null };
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: 'connected',
        productAccountId: 'account-1',
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  };
  return () =>
    createInboxPreferences(
      {
        openInboxPreferences: async () => ({ owner: 'account-1', ...kept }),
        commitInboxPreferences: async (owner, expectedRevision, document) => {
          Object.assign(kept, { revision: expectedRevision + 1, document });
          return { owner, revision: kept.revision };
        },
      },
      registration,
    );
};

// The checked rows of Settings › Appearance › List density.
const checked = (app: Awaited<ReturnType<typeof render>>) =>
  app
    .getAllByRole('radio')
    .filter((row) => row.props.accessibilityState?.checked === true)
    .map((row) => row.props.accessibilityLabel);

// The window's text size, which a test sets before it renders.
const window = (fontScale: number) =>
  jest
    .spyOn(
      jest.requireActual<{ useWindowDimensions: typeof useWindowDimensions }>(
        'react-native',
      ),
      'useWindowDimensions',
    )
    .mockReturnValue({ width: 402, height: 874, scale: 3, fontScale });

// How many lines the row gives its subject and preview, at the default text size and at an
// accessibility size; 0 wraps.
const lines = async (
  app: Awaited<ReturnType<typeof render>>,
  tree: () => ReactElement,
) => {
  const measured: Record<string, unknown> = {};
  for (const [size, fontScale] of [
    ['default', 1],
    ['accessibility', 2],
  ] as const) {
    window(fontScale);
    await app.rerender(tree());
    measured[size] = {
      subject: app.getByText(message.subject).props.numberOfLines,
      preview: app.getByText(message.preview).props.numberOfLines,
    };
  }
  return measured;
};

describe('settings › Appearance › List density', () => {
  it("starts Comfortable, and Compact wraps the Profile's subjects, keeps one preview line and lasts a relaunch", async () => {
    expect.hasAssertions();
    const relaunch = preferences();
    const store = relaunch();
    await store.load();
    const tree = () => (
      <InboxPreferencesContext value={store}>
        <ListDensitySettings profile={defaultProfile} />
        <MessageRow
          message={message}
          mailbox={undefined}
          status={undefined}
          selected={false}
          onSelect={() => undefined}
          now={Date.parse(message.receivedAt)}
        />
      </InboxPreferencesContext>
    );
    window(1);
    const app = await render(tree());
    const initial = { checked: checked(app), lines: await lines(app, tree) };
    const footer = app.queryByText(
      'Compact shows one preview line. Rows grow with Text Size.',
    );
    await fireEvent.press(app.getByRole('radio', { name: 'Compact' }));
    await waitFor(() => {
      expect(checked(app)).toStrictEqual(['Compact']);
    });
    const relaunched = relaunch();
    await relaunched.load();
    expect({
      initial,
      footer: footer !== null,
      compact: await lines(app, tree),
      kept: relaunched.listDensity(defaultProfile),
      otherProfile: relaunched.listDensity('profile-work'),
    }).toStrictEqual({
      initial: {
        checked: ['Comfortable'],
        lines: {
          default: { subject: 1, preview: 1 },
          accessibility: { subject: 0, preview: 2 },
        },
      },
      footer: true,
      compact: {
        default: { subject: 0, preview: 1 },
        accessibility: { subject: 0, preview: 1 },
      },
      kept: 'compact',
      otherProfile: 'comfortable',
    });
  });
});
