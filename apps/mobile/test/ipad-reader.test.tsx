import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { Platform } from 'react-native';

import {
  createDrafts,
  draftsOf,
  ownerOf,
} from '@private-email/mail-core/drafts';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPins } from '@private-email/mail-core/pins';
import { mailboxesOf } from '@private-email/mail-core/registration';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-vault';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import { useState } from 'react';
import { Dimensions, View } from 'react-native';

import {
  CommandPaletteProvider,
  InSheet,
  SheetPalette,
} from '../src/command-palette.tsx';
import { Composer } from '../src/composer.tsx';
import { InboxProvider } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { PinsContext } from '../src/pins.tsx';
import { AccountContext } from '../src/registration-gate.tsx';

// Set the device boundary before the reader's platform-specific modules load.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's platform adapter boundary.
jest.mock('react-native/Libraries/Utilities/Platform', () => {
  const { default: platform } = jest.requireActual<{
    default: typeof Platform;
  }>('react-native/Libraries/Utilities/Platform');
  return { __esModule: true, default: { ...platform, isPad: true } };
});

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The palette clears the status bar itself; this host has no inset.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

const alex = syntheticMailboxes['alex@example.invalid'];
// A persistent reader notice must scroll with content, outside the fixed toolbar.
function isScrollable(
  element: ReturnType<typeof screen.getByText> | null,
): boolean {
  return (
    element !== null &&
    (element.props.onScroll !== undefined || isScrollable(element.parent))
  );
}

const ignore = () => undefined;

function Reader({
  inbox,
  drafts,
  message,
  sheet = false,
}: {
  readonly inbox: ReturnType<typeof createInboxStore>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly message: string;
  // Whether the composer opens in the compact window's system sheet.
  readonly sheet?: boolean;
}) {
  const [composing, setComposing] = useState<string>();
  return (
    <InboxProvider
      drafts={drafts}
      mailboxes={singleMailbox(inbox, alex)}>
      <CommandPaletteProvider>
        {composing === undefined ? (
          <MessageDetail
            mailbox={alex}
            id={message}
            onClose={ignore}
            onCompose={setComposing}
          />
        ) : (
          <View
            testID="sheet-content"
            style={{ flex: 1 }}>
            <InSheet value={sheet}>
              <Composer
                id={composing}
                onClose={() => {
                  setComposing(undefined);
                }}
                onRebind={setComposing}
              />
            </InSheet>
            <SheetPalette />
          </View>
        )}
      </CommandPaletteProvider>
    </InboxProvider>
  );
}

describe('iPad reader', () => {
  it('retires an open Move panel when IMAP loses move capability', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Projects');
    const uid = imap.deliver('INBOX', { subject: 'Project plans' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'imap-reader')}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox="imap-reader"
            id={`7.${uid}.INBOX`}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(screen.getByTestId('reader-panel-dismissal')).toBeOnTheScreen();
    imap.server.capabilities.moves = false;
    await act(inbox.load);
    expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
    // Restoring the capability does not reopen the retired panel.
    imap.server.capabilities.moves = true;
    await act(inbox.load);
    expect(
      screen.getByRole('button', { name: 'Folders', expanded: false }),
    ).toBeVisible();
    expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
    // On iPad More is the system menu the frames draw.
    const sections: ReadonlyArray<{ items: ReadonlyArray<{ title: string }> }> =
      screen.getByLabelText('More').props.sections;
    expect(
      sections.flatMap(({ items }) => items.map(({ title }) => title)),
    ).toContain('Mark as Unread');
  });

  it('moves once from the system popover on Move, and a dismissal moves nothing', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Projects');
    const uid = imap.deliver('INBOX', { subject: 'Project plans' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, 'imap-reader')}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox="imap-reader"
            id={`7.${uid}.INBOX`}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(screen.getByTestId('popover')).toBeVisible();
    // Dismissing the popover, as a tap outside does, moves nothing.
    await fireEvent(screen.getByTestId('popover'), 'accessibilityEscape');
    expect(
      screen.getByRole('button', { name: 'Folders', expanded: false }),
    ).toBeVisible();
    const moves = () =>
      imap.server.changes.filter((change) => change.startsWith('move '));
    expect(moves()).toStrictEqual([]);
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    const projects = within(screen.getByTestId('move-panel')).getByRole(
      'button',
      { name: 'Move to Projects' },
    );
    // Choosing closes the popover and moves once, and the moved message leaves the reader.
    await fireEvent.press(projects);
    expect(screen.queryByTestId('popover')).toBeNull();
    await waitFor(() => {
      expect(moves()).toStrictEqual([`move INBOX ${uid} Projects`]);
    });
  });

  it('creates a Gmail label from Labels in the panel the labels were shown in', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 0 });
    gmail.createLabel('Clients');
    const message = gmail.deliver({ subject: 'Invoice 2026-114 for October' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    await render(
      <InboxProvider mailboxes={singleMailbox(inbox, alex)}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox={alex}
            id={message}
          />
        </CommandPaletteProvider>
      </InboxProvider>,
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Labels' }),
    );
    await fireEvent.press(screen.getByRole('button', { name: 'New Label…' }));
    const labels = within(screen.getByTestId('new-label'));
    // Labels takes the labels' place beneath the toolbar, whose Move hides it.
    expect(
      within(screen.getByTestId('reader-panels')).getByTestId('new-label'),
    ).toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Hide Labels', expanded: true }),
    ).toBeVisible();
    await fireEvent.changeText(
      labels.getByLabelText('Label name'),
      'Clients/Acme',
    );
    await act(async () => {
      await fireEvent.press(labels.getByRole('button', { name: 'Apply' }));
    });
    expect(screen.queryByTestId('new-label')).toBeNull();
    expect(gmail.labelsOf(message)).toContain('Label_2');
    expect(screen.getByText('Labels: Clients/Acme')).toBeVisible();
  });

  it('lists Move to Spam after the read state, and Not Spam in Spam', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Junk', ['junk']);
    const uid = imap.deliver('INBOX', { subject: 'Project plans' });
    const junk = imap.deliver('Junk', { subject: 'Seed catalogue' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const titles = () =>
      screen
        .getByLabelText('More')
        .props.sections.map(
          ({ items }: { items: ReadonlyArray<{ title: string }> }) =>
            items.map(({ title }) => title),
        );
    const reader = (id: string) => (
      <InboxProvider mailboxes={singleMailbox(inbox, 'imap-reader')}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox="imap-reader"
            id={id}
          />
        </CommandPaletteProvider>
      </InboxProvider>
    );
    await render(reader(`7.${uid}.INBOX`));
    // The approved iPad More Menu frame: Mark as Unread, Move to Spam, Move to….
    expect(titles()).toStrictEqual([
      ['Mark as Unread', 'Move to Spam', 'Move to…'],
    ]);
    await act(() => inbox.openFolder('Junk'));
    await screen.rerender(reader(`3.${junk}.Junk`));
    expect(titles()).toStrictEqual([
      ['Mark as Unread', 'Not Spam', 'Move to…'],
    ]);
    const more = screen.getByLabelText('More');
    await act(async () => {
      await fireEvent(more, 'select', {
        nativeEvent: { id: 'notSpam' },
      });
    });
    await waitFor(() => {
      expect(imap.server.changes).toContain(`move Junk ${junk} INBOX`);
    });
  });

  it('pins the Thread from the toolbar’s last group, before More', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    const uid = imap.deliver('INBOX', { subject: 'Project plans' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const snapshot: RegistrationSnapshot = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      mailboxes: JSON.stringify([]),
    };
    const saved = { revision: 0, document: null as string | null };
    const pins = createPins(
      {
        openPins: () => Promise.resolve({ owner: ownerOf(snapshot), ...saved }),
        commitPins: (owner, revision, document) => {
          Object.assign(saved, { revision: revision + 1, document });
          return Promise.resolve({ owner, revision: saved.revision });
        },
      },
      { getSnapshot: () => ({ snapshot, busy: false, failed: false }) },
    );
    await render(
      <PinsContext value={pins}>
        <InboxProvider mailboxes={singleMailbox(inbox, 'imap-reader')}>
          <CommandPaletteProvider>
            <MessageDetail
              mailbox="imap-reader"
              id={`7.${uid}.INBOX`}
            />
          </CommandPaletteProvider>
        </InboxProvider>
      </PinsContext>,
    );
    // iPad's toolbar shows Pin, so More does not list it.
    expect(
      screen
        .getByLabelText('More')
        .props.sections.flatMap(
          ({ items }: { items: ReadonlyArray<{ title: string }> }) =>
            items.map(({ title }) => title),
        ),
    ).not.toContain('Pin');
    await act(async () => {
      await fireEvent.press(await screen.findByRole('button', { name: 'Pin' }));
    });
    await expect(
      screen.findByRole('button', { name: 'Unpin' }),
    ).resolves.toBeVisible();
    await expect(pins.pins(['imap-reader'])).resolves.toMatchObject([
      { connection: 'imap-reader', thread: `7.${uid}.INBOX` },
    ]);
  });

  it('opens another message in the same reader with its panels closed', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.addFolder('Projects');
    const first = imap.deliver('INBOX', { subject: 'Project plans' });
    const second = imap.deliver('INBOX', { subject: 'Garden plans' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    const reader = (uid: number) => (
      <InboxProvider mailboxes={singleMailbox(inbox, 'imap-reader')}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox="imap-reader"
            id={`7.${uid}.INBOX`}
          />
        </CommandPaletteProvider>
      </InboxProvider>
    );
    await render(reader(first));
    await fireEvent.press(screen.getByRole('button', { name: 'Folders' }));
    expect(screen.getByTestId('reader-panel-dismissal')).toBeOnTheScreen();
    await screen.rerender(reader(second));
    expect(
      screen.getByRole('button', { name: 'Folders', expanded: false }),
    ).toBeVisible();
    expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
  });

  /* oxlint-disable vitest/max-expects -- One reader journey covers Labels, the saved-only notice and Reply All. */
  it.each([320, 1024])(
    'keeps direct response actions in the fixed header and the palette in the navigation bar at %i points',
    async (width) => {
      expect.hasAssertions();
      const window = Dimensions.get('window');
      Dimensions.set({ window: { ...window, width, height: 768 } });
      const snapshot: RegistrationSnapshot = {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        mailboxes: JSON.stringify([
          { id: alex, address: 'alex@example.invalid', state: 'connected' },
        ]),
      };
      const account = { snapshot, busy: false, failed: false };
      const registration = {
        getSnapshot: () => account,
        subscribe: () => ignore,
      };
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      const gmail = createSyntheticGmail({ messages: 0 });
      const message = gmail.deliver({
        from: 'Maya Chen <maya@example.invalid>',
        headers: {
          To: 'Alex <alex@example.invalid>, Bob <bob@example.invalid>',
        },
        subject: 'iPad plans',
        content: { text: 'Shall we meet on Friday?' },
      });
      const inbox = createInboxStore(gmail.native);
      try {
        await render(
          <AccountContext
            value={{
              mailboxes: mailboxesOf(snapshot),
              openAccount: ignore,
              authorizeMailbox: () => Promise.resolve(),
              refreshInbox: (load) => load(),
              account: 'synthetic-product-account',
              profiles: [],
              createProfile: () => Promise.resolve(undefined),
              chooseFolders: () => Promise.resolve(true),
            }}>
            <Reader
              inbox={inbox}
              drafts={drafts}
              message={message}
            />
          </AccountContext>,
        );
        await act(inbox.load);
        await screen.findByText('Shall we meet on Friday?');
        expect(
          screen.getByRole('header', { name: 'iPad plans' }),
        ).toBeVisible();
        // The subject text itself stays selectable inside the accessible header.
        expect(screen.getByText('iPad plans')).toHaveProp('selectable', true);
        expect(screen.queryByRole('button', { name: /^Back/u })).toBeNull();
        const commands = screen.getByRole('button', {
          name: 'Open Command Palette',
        });
        expect({ scrollable: isScrollable(commands) }).toStrictEqual({
          scrollable: false,
        });
        // A reader shown alone puts the input in its navigation bar, beside Back (#2133).
        expect(
          within(screen.getByTestId('system-back')).getByRole('button', {
            name: 'Open Command Palette',
          }),
        ).toBe(commands);
        await fireEvent.press(commands);
        const palette = within(screen.getByTestId('command-palette'));
        expect(
          palette.getByRole('header', {
            name: 'Selected Message · iPad plans',
          }),
        ).toBeVisible();
        expect(
          palette.getByRole('button', { name: 'Reply All' }),
        ).toBeEnabled();
        expect(palette.getByRole('button', { name: 'Archive' })).toBeEnabled();
        await fireEvent.press(palette.getByRole('button', { name: 'Cancel' }));
        await fireEvent.press(screen.getByRole('button', { name: 'Labels' }));
        expect(
          screen.getByText('This Gmail mailbox has no labels of its own yet.'),
        ).toBeVisible();
        expect(screen.getByTestId('reader-panels')).toHaveStyle({
          position: 'absolute',
        });
        await fireEvent.press(
          screen.getByRole('button', { name: 'Hide Labels' }),
        );
        await fireEvent.press(screen.getByRole('button', { name: 'Labels' }));
        expect(screen.getByTestId('reader-panel-dismissal')).toBeOnTheScreen();
        const { openMailbox } = gmail.native;
        gmail.native.openMailbox = async () => ({
          ...(await openMailbox()),
          availability: 'retry',
        });
        await act(inbox.load);
        // Organizing that becomes unavailable takes its open panel and dismissal with it.
        expect(screen.queryByTestId('reader-panel-dismissal')).toBeNull();
        expect(
          isScrollable(
            screen.getByText(
              'Organizing mail waits until Gmail can be checked again. Try again to reconnect.',
            ),
          ),
        ).toBe(true);
        const create = jest
          .spyOn(drafts, 'create')
          .mockRejectedValueOnce(new TypeError('Synthetic host failure'));
        try {
          await fireEvent.press(
            screen.getByRole('button', { name: 'Reply All' }),
          );
          expect(
            isScrollable(
              await screen.findByText(
                'The reply or forward didn’t open. Choose Reply or Forward again.',
              ),
            ),
          ).toBe(true);
          expect(screen.getByRole('alert')).toBeVisible();
        } finally {
          create.mockRestore();
        }
        await fireEvent.press(
          screen.getByRole('button', { name: 'Reply All' }),
        );
        await expect(screen.findByLabelText('Subject')).resolves.toHaveProp(
          'value',
          'Re: iPad plans',
        );
        expect(draftsOf(drafts.getSnapshot())[0]).toMatchObject({
          response: { kind: 'replyAll' },
          to: [
            { name: 'Maya Chen', address: 'maya@example.invalid' },
            { name: 'Bob', address: 'bob@example.invalid' },
          ],
        });
      } finally {
        await act(() => {
          Dimensions.set({ window });
        });
      }
    },
  );
  /* oxlint-enable vitest/max-expects */

  // The compact window's composer sheet owns the downward swipe; its Command input ends the From
  // row as the command symbol alone (#2133).
  it.each([
    { sheet: false, labels: 1, palettes: 0 },
    { sheet: true, labels: 0, palettes: 1 },
  ])(
    'offers one Command input in a compact composer, symbol-only in the sheet (sheet=$sheet)',
    async ({ sheet, labels, palettes }) => {
      expect.hasAssertions();
      const snapshot: RegistrationSnapshot = {
        kind: 'connected',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        mailboxes: JSON.stringify([
          { id: alex, address: 'alex@example.invalid', state: 'connected' },
        ]),
      };
      const account = { snapshot, busy: false, failed: false };
      const drafts = createDrafts(
        createSyntheticDrafts(() => 'synthetic-product-account').native,
        { getSnapshot: () => account, subscribe: () => ignore },
      );
      const gmail = createSyntheticGmail({ messages: 0 });
      const message = gmail.deliver({
        from: 'Maya Chen <maya@example.invalid>',
        subject: 'iPad plans',
        content: { text: 'Shall we meet on Friday?' },
      });
      const inbox = createInboxStore(gmail.native);
      await render(
        <AccountContext
          value={{
            mailboxes: mailboxesOf(snapshot),
            openAccount: ignore,
            authorizeMailbox: () => Promise.resolve(),
            refreshInbox: (load) => load(),
            account: 'synthetic-product-account',
            profiles: [],
            createProfile: () => Promise.resolve(undefined),
            chooseFolders: () => Promise.resolve(true),
          }}>
          <Reader
            inbox={inbox}
            drafts={drafts}
            message={message}
            sheet={sheet}
          />
        </AccountContext>,
      );
      await act(inbox.load);
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Reply' }),
      );
      await screen.findByLabelText('Subject');
      expect(screen.queryAllByText('Commands')).toHaveLength(labels);
      await fireEvent.press(
        screen.getByRole('button', { name: 'Open Command Palette' }),
      );
      // A sheet covers the window, so the palette its input opens shows over the sheet itself.
      expect(
        within(
          screen.getByTestId('sheet-content', { includeHiddenElements: true }),
        ).queryAllByTestId('command-palette'),
      ).toHaveLength(palettes);
      // Leaving the composer, as the sheet's swipe does, asks about changes in place of the
      // palette, and leaves no palette open behind it.
      await fireEvent.changeText(
        screen.getByLabelText('Message body', { includeHiddenElements: true }),
        'Friday works.',
      );
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Close',
          includeHiddenElements: true,
        }),
      );
      await waitFor(() => {
        expect(screen.queryByTestId('command-palette')).toBeNull();
      });
      await fireEvent.press(
        screen.getByRole('button', { name: 'Delete Draft' }),
      );
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Open Command Palette',
          includeHiddenElements: true,
        }),
      );
      expect(screen.getByTestId('command-palette')).toBeOnTheScreen();
    },
  );
});
