import { ok } from 'node:assert';

import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type { ModalProps, Platform } from 'react-native';

import { inboxCommands } from '@private-email/mail-core/commands';
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
import { Dimensions, Modal, Settings, View } from 'react-native';

import {
  CommandPaletteProvider,
  RegisterCommands,
} from '../src/command-palette.tsx';
import { ComposerSheet } from '../src/composer-sheet.tsx';
import { Composer } from '../src/composer.tsx';
import { useLocalization } from '../src/localization.ts';
import { InboxProvider, useLeaveComposer } from '../src/mailbox.tsx';
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

// iOS keeps a dismissed sheet's content until it has slid away; `slid` ends the slide.
async function holdingSheetDismissal(
  run: (slid: () => Promise<void>) => Promise<void>,
) {
  const { render } = Modal.prototype;
  let dismiss: (() => void) | undefined = undefined;
  const shown = jest
    .spyOn(Modal.prototype, 'render')
    .mockImplementation(function (this: { readonly props: ModalProps }) {
      if (this.props.visible === false) {
        dismiss = this.props.onDismiss;
      }
      return render.call({ props: { ...this.props, visible: true } });
    });
  const dismissing = jest
    .spyOn(Modal.prototype, 'componentDidUpdate')
    .mockImplementation(ignore);
  try {
    await run(async () => {
      await act(() => {
        dismiss?.();
      });
    });
  } finally {
    shown.mockRestore();
    dismissing.mockRestore();
  }
}

// The composer's host: the compact window's sheet, whose swipe leaves the composer as the app's
// does, or the regular window's card.
function ComposerHost({
  draft,
  sheet,
  onLeft,
  onRebind,
}: {
  readonly draft: string | undefined;
  readonly sheet: boolean;
  readonly onLeft: () => void;
  readonly onRebind: (draft: string) => void;
}) {
  const leave = useLeaveComposer();
  const composer = (id: string) => (
    <Composer
      id={id}
      onClose={onLeft}
      onRebind={onRebind}
    />
  );
  if (sheet) {
    return (
      <ComposerSheet
        draft={draft}
        onLeave={() => {
          void leave();
        }}
        composer={composer}
      />
    );
  }
  return draft === undefined ? null : (
    <View
      testID="composer-overlay"
      style={{ flex: 1 }}>
      {composer(draft)}
    </View>
  );
}

// Hands over the shared leave guard a tapped notification waits on before it navigates, and
// offers the window's Account and Go To Inbox, which leaves the composer first, as the app's does.
function Window({
  onLeave,
  onAccount,
  onInbox,
}: {
  readonly onLeave: (leave: ReturnType<typeof useLeaveComposer>) => void;
  readonly onAccount: () => void;
  readonly onInbox: () => void;
}) {
  const { t } = useLocalization();
  const leave = useLeaveComposer();
  onLeave(leave);
  return (
    <RegisterCommands
      offer={() =>
        inboxCommands(t, {
          account: onAccount,
          inbox: async () => {
            if (await leave()) {
              onInbox();
            }
          },
        })
      }
    />
  );
}

function Reader({
  inbox,
  drafts,
  message,
  sheet = false,
  onLeave = ignore,
  onAccount = ignore,
  onInbox = ignore,
  reopen = false,
  onOpen = ignore,
}: {
  readonly inbox: ReturnType<typeof createInboxStore>;
  readonly drafts: ReturnType<typeof createDrafts>;
  readonly message: string;
  // Whether the composer opens in the compact window's system sheet.
  readonly sheet?: boolean;
  readonly onLeave?: (leave: ReturnType<typeof useLeaveComposer>) => void;
  readonly onAccount?: () => void;
  readonly onInbox?: () => void;
  // Whether the route reopens a closed Draft at once, as its Open Draft notification can in the
  // same batch, so the composer stays.
  readonly reopen?: boolean;
  // Hands over opening or closing a Draft's composer, as its route does.
  readonly onOpen?: (open: (draft: string | undefined) => void) => void;
}) {
  const [composing, setComposing] = useState<string>();
  onOpen(setComposing);
  return (
    <InboxProvider
      drafts={drafts}
      mailboxes={singleMailbox(inbox, alex)}>
      <CommandPaletteProvider>
        <Window
          onLeave={onLeave}
          onAccount={onAccount}
          onInbox={onInbox}
        />
        {composing === undefined ? (
          <MessageDetail
            mailbox={alex}
            id={message}
            onClose={ignore}
            onCompose={setComposing}
          />
        ) : null}
        {/* The sheet stays mounted while it slides away, as the app's does. */}
        {sheet || composing !== undefined ? (
          <ComposerHost
            draft={composing}
            sheet={sheet}
            onLeft={() => {
              if (!reopen) {
                setComposing(undefined);
              }
            }}
            onRebind={setComposing}
          />
        ) : null}
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
    expect(screen.getByTestId('popover')).toBeVisible();
    imap.server.capabilities.moves = false;
    await act(inbox.load);
    expect(screen.queryByTestId('popover')).toBeNull();
    // Restoring the capability does not reopen the retired panel.
    imap.server.capabilities.moves = true;
    await act(inbox.load);
    expect(
      screen.getByRole('button', { name: 'Folders', expanded: false }),
    ).toBeVisible();
    expect(screen.queryByTestId('popover')).toBeNull();
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

  it('creates a Gmail label from Labels in the popover the labels were shown in', async () => {
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
    const popover = within(screen.getByTestId('popover'));
    // The labels sit under the #1683 frames' Labels title, as New Label's form does; getBy throws
    // without it.
    popover.getByRole('header', { name: 'Labels' });
    await fireEvent.press(popover.getByRole('button', { name: 'New Label…' }));
    const labels = within(screen.getByTestId('new-label'));
    // Labels takes the labels' place in the system popover on the toolbar's Labels, which hides it.
    expect(
      within(screen.getByTestId('popover')).getByTestId('new-label'),
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
      ['Message Zoom…'],
    ]);
    await act(() => inbox.openFolder('Junk'));
    await screen.rerender(reader(`3.${junk}.Junk`));
    expect(titles()).toStrictEqual([
      ['Mark as Unread', 'Not Spam', 'Move to…'],
      ['Message Zoom…'],
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

  it('zooms one message from More until another opens, and keeps a level for all messages', async () => {
    expect.hasAssertions();
    Settings.set({ UnwiredMessageZoom: 100 });
    const gmail = createSyntheticGmail({ messages: 0 });
    const [first, second] = ['Invoice 2026-114', 'Receipt 2026-115'].map(
      (subject) =>
        gmail.deliver({ subject, content: { html: `<p>${subject}</p>` } }),
    );
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const reader = (id: string | undefined) => (
      <InboxProvider mailboxes={singleMailbox(inbox, alex)}>
        <CommandPaletteProvider>
          <MessageDetail
            mailbox={alex}
            id={id}
          />
        </CommandPaletteProvider>
      </InboxProvider>
    );
    // The zoom the reader adds to the shown document, in percent.
    const zoom = async () => {
      const webview = await screen.findByTestId('message-webview');
      const html: string = webview.props.source.html;
      const scale = /<style>body\{zoom:([\d.]+)\}/u.exec(html)?.[1];
      return scale === undefined ? 100 : Math.round(Number(scale) * 100);
    };
    const press = async (name: string) => {
      await fireEvent.press(screen.getByRole('button', { name }));
    };
    await render(reader(first));
    await zoom();
    await act(async () => {
      await fireEvent(screen.getByLabelText('More'), 'select', {
        nativeEvent: { id: 'zoom' },
      });
    });
    expect(screen.getByText('Message zoom · 100%')).toBeVisible();
    await press('Zoom In');
    await press('Zoom In');
    const zoomedIn = {
      title: screen.getByText('Message zoom · 125%').props.children,
      document: await zoom(),
    };
    await press('Zoom Out');
    const zoomedOut = await zoom();
    await press('Actual Size');
    const actual = await zoom();
    await press('Zoom In');
    await screen.rerender(reader(second));
    const next = await zoom();
    await act(async () => {
      await fireEvent(screen.getByLabelText('More'), 'select', {
        nativeEvent: { id: 'zoom' },
      });
    });
    await press('Zoom Out');
    await press('Use 85% for All Messages');
    await screen.rerender(reader(first));

    expect({
      zoomedIn,
      zoomedOut,
      actual,
      next,
      stored: Settings.get('UnwiredMessageZoom'),
      reopened: await zoom(),
    }).toStrictEqual({
      zoomedIn: { title: 'Message zoom · 125%', document: 125 },
      zoomedOut: 115,
      actual: 100,
      next: 100,
      stored: 85,
      reopened: 85,
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
    expect(screen.getByTestId('popover')).toBeVisible();
    await screen.rerender(reader(second));
    expect(
      screen.getByRole('button', { name: 'Folders', expanded: false }),
    ).toBeVisible();
    expect(screen.queryByTestId('popover')).toBeNull();
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
        expect(screen.getByTestId('popover')).toBeVisible();
        await fireEvent.press(
          screen.getByRole('button', { name: 'Hide Labels' }),
        );
        await fireEvent.press(screen.getByRole('button', { name: 'Labels' }));
        expect(screen.getByTestId('popover')).toBeVisible();
        const { openMailbox } = gmail.native;
        gmail.native.openMailbox = async () => ({
          ...(await openMailbox()),
          availability: 'retry',
        });
        await act(inbox.load);
        // Organizing that becomes unavailable takes its open popover with it.
        expect(screen.queryByTestId('popover')).toBeNull();
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

  // A reader whose responses open the composer in the compact window's sheet, or the regular
  // window's card, with its Reply's composer open.
  const replyFromReader = async (
    sheet: boolean,
    {
      onLeave = ignore,
      onAccount = ignore,
      onInbox = ignore,
      reopen = false,
      onOpen = ignore,
    }: Readonly<{
      onLeave?: (leave: ReturnType<typeof useLeaveComposer>) => void;
      onAccount?: () => void;
      onInbox?: () => void;
      reopen?: boolean;
      onOpen?: (open: (draft: string | undefined) => void) => void;
    }> = {},
  ) => {
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
          onLeave={onLeave}
          onAccount={onAccount}
          onInbox={onInbox}
          reopen={reopen}
          onOpen={onOpen}
        />
      </AccountContext>,
    );
    await act(inbox.load);
    await fireEvent.press(await screen.findByRole('button', { name: 'Reply' }));
    await screen.findByLabelText('Subject');
    return drafts;
  };
  const palettesInComposer = () =>
    within(
      screen.getByTestId('composer-overlay', { includeHiddenElements: true }),
    ).queryAllByTestId('command-palette');

  // The compact window's composer sheet owns the downward swipe; its Command input ends the From
  // row as the command symbol alone (#2133).
  it.each([
    { sheet: false, labels: 1, palettes: 0 },
    { sheet: true, labels: 0, palettes: 1 },
  ])(
    'offers one Command input in a compact composer, symbol-only in the sheet (sheet=$sheet)',
    async ({ sheet, labels, palettes }) => {
      expect.hasAssertions();
      await replyFromReader(sheet);
      expect(screen.queryAllByText('Commands')).toHaveLength(labels);
      await fireEvent.press(
        screen.getByRole('button', { name: 'Open Command Palette' }),
      );
      // A sheet covers the window, so the palette its input opens shows over the sheet itself.
      expect(palettesInComposer()).toHaveLength(palettes);
      // Closing the composer leaves no palette open behind it.
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Close',
          includeHiddenElements: true,
        }),
      );
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Open Command Palette',
          includeHiddenElements: true,
        }),
      );
      expect(screen.getByTestId('command-palette')).toBeOnTheScreen();
      // A sheet that opens over the window's palette still opens its own. The reader's Reply
      // precedes the palette's.
      const [reply] = screen.getAllByRole('button', {
        name: 'Reply',
        includeHiddenElements: true,
      });
      ok(reply);
      await fireEvent.press(reply);
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Open Command Palette',
          includeHiddenElements: true,
        }),
      );
      expect(palettesInComposer()).toHaveLength(palettes);
    },
  );

  it('swipes a composer sheet away with the palette it showed', async () => {
    expect.hasAssertions();
    await replyFromReader(true);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await act(async () => {
      await fireEvent(
        screen.getByTestId('composer-sheet', { includeHiddenElements: true }),
        'requestClose',
      );
    });
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Open Command Palette' }),
    );
    expect(screen.getByTestId('command-palette')).toBeOnTheScreen();
  });

  it('asks a changed composer sheet’s Save or Delete question in place of its palette', async () => {
    expect.hasAssertions();
    let leaveComposer: ReturnType<typeof useLeaveComposer> = () =>
      Promise.resolve(true);
    await replyFromReader(true, {
      onLeave: (leave) => {
        leaveComposer = leave;
      },
    });
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.changeText(
      screen.getByLabelText('Message body', { includeHiddenElements: true }),
      'Friday works.',
    );
    // A tapped notification waits on the composer's question.
    await act(() => {
      void leaveComposer();
    });
    await waitFor(() => {
      expect(palettesInComposer()).toHaveLength(0);
    });
    await fireEvent.press(screen.getByRole('button', { name: 'Delete Draft' }));
    expect(screen.queryByLabelText('Message body')).not.toBeOnTheScreen();
  });

  it('leaves a changed composer sheet before a window command acts behind it', async () => {
    expect.hasAssertions();
    const account = jest.fn<undefined, []>();
    await replyFromReader(true, { onAccount: account });
    await fireEvent.changeText(
      screen.getByLabelText('Message body', { includeHiddenElements: true }),
      'Friday works.',
    );
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Account',
        includeHiddenElements: true,
      }),
    );
    // Settings would open beneath the sheet, so the Draft's question comes first.
    expect(account).not.toHaveBeenCalled();
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Save Draft' }),
    );
    await waitFor(() => {
      expect(account).toHaveBeenCalledWith();
    });
    expect(screen.queryByLabelText('Message body')).not.toBeOnTheScreen();
  });

  it('goes to the Inbox from a changed composer sheet once Delete Draft answers', async () => {
    expect.hasAssertions();
    await holdingSheetDismissal(async (slid) => {
      const inbox = jest.fn<undefined, []>();
      await replyFromReader(true, { onInbox: inbox });
      await fireEvent.changeText(
        screen.getByLabelText('Message body', { includeHiddenElements: true }),
        'Friday works.',
      );
      await fireEvent.press(
        screen.getByRole('button', { name: 'Open Command Palette' }),
      );
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Inbox',
          includeHiddenElements: true,
        }),
      );
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Delete Draft' }),
      );
      // The command runs once the composer has closed, while the sheet still slides away with it.
      await waitFor(() => {
        expect(inbox).toHaveBeenCalledWith();
      });
      expect(
        screen.getByLabelText('Message body', { includeHiddenElements: true }),
      ).toBeOnTheScreen();
      await slid();
      expect(
        screen.queryByLabelText('Message body', {
          includeHiddenElements: true,
        }),
      ).not.toBeOnTheScreen();
    });
  });

  it('swipes away an unchanged Draft opened again while its sheet slides away', async () => {
    expect.hasAssertions();
    await holdingSheetDismissal(async (slid) => {
      let open: (draft: string | undefined) => void = ignore;
      const drafts = await replyFromReader(true, {
        onOpen: (opening) => {
          open = opening;
        },
      });
      const [draft] = draftsOf(drafts.getSnapshot());
      ok(draft);
      await fireEvent.press(screen.getByRole('button', { name: 'Close' }));
      await act(() => {
        open(draft.id);
      });
      await act(async () => {
        await fireEvent(
          screen.getByTestId('composer-sheet', { includeHiddenElements: true }),
          'requestClose',
        );
      });
      await slid();
      expect(
        screen.queryByLabelText('Message body', {
          includeHiddenElements: true,
        }),
      ).not.toBeOnTheScreen();
    });
  });

  it('drops a composer sheet’s command when its route reopens the Draft as it closes', async () => {
    expect.hasAssertions();
    const account = jest.fn<undefined, []>();
    let leaveComposer: ReturnType<typeof useLeaveComposer> = () =>
      Promise.resolve(true);
    let open: (draft: string | undefined) => void = ignore;
    await replyFromReader(true, {
      onAccount: account,
      onLeave: (leave) => {
        leaveComposer = leave;
      },
      onOpen: (opening) => {
        open = opening;
      },
      reopen: true,
    });
    await fireEvent.changeText(
      screen.getByLabelText('Message body', { includeHiddenElements: true }),
      'Friday works.',
    );
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Account',
        includeHiddenElements: true,
      }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Save Draft' }),
    );
    // A tapped Open Draft notification leaves and opens the Draft again in the same commit.
    await act(async () => {
      await leaveComposer();
    });
    // The Draft opened again still answers its swipe.
    await fireEvent.changeText(
      screen.getByLabelText('Message body', { includeHiddenElements: true }),
      'Saturday works.',
    );
    await act(async () => {
      await fireEvent(
        screen.getByTestId('composer-sheet', { includeHiddenElements: true }),
        'requestClose',
      );
    });
    await expect(
      screen.findByRole('button', { name: 'Save Draft' }),
    ).resolves.toBeOnTheScreen();
    await fireEvent.press(screen.getByRole('button', { name: 'Save Draft' }));
    await act(() => {
      open(undefined);
    });
    expect(account).not.toHaveBeenCalled();
  });

  it('runs a composer sheet’s command once its route closes, despite a swipe meanwhile', async () => {
    expect.hasAssertions();
    const account = jest.fn<undefined, []>();
    let open: (draft: string | undefined) => void = ignore;
    await replyFromReader(true, {
      onAccount: account,
      onOpen: (opening) => {
        open = opening;
      },
      reopen: true,
    });
    await fireEvent.changeText(
      screen.getByLabelText('Message body', { includeHiddenElements: true }),
      'Friday works.',
    );
    await fireEvent.press(
      screen.getByRole('button', { name: 'Open Command Palette' }),
    );
    await fireEvent.press(
      screen.getByRole('button', {
        name: 'Account',
        includeHiddenElements: true,
      }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Save Draft' }),
    );
    // The swipe lands before the route commits the close the command already asked for.
    await act(async () => {
      await fireEvent(
        screen.getByTestId('composer-sheet', { includeHiddenElements: true }),
        'requestClose',
      );
    });
    await act(() => {
      open(undefined);
    });
    expect(account).toHaveBeenCalledWith();
  });

  it('asks again about a Draft its route reopens as it closes', async () => {
    expect.hasAssertions();
    let leaveComposer: ReturnType<typeof useLeaveComposer> = () =>
      Promise.resolve(true);
    await replyFromReader(true, {
      onLeave: (leave) => {
        leaveComposer = leave;
      },
      reopen: true,
    });
    const edit = async (text: string) => {
      await fireEvent.changeText(
        screen.getByLabelText('Message body', { includeHiddenElements: true }),
        text,
      );
    };
    await edit('Friday works.');
    await act(() => {
      void leaveComposer();
    });
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Save Draft' }),
    );
    await edit('Saturday works.');
    let left: boolean | undefined = undefined;
    await act(() => {
      void (async () => {
        left = await leaveComposer();
      })();
    });
    await expect(
      screen.findByRole('button', { name: 'Save Draft' }),
    ).resolves.toBeOnTheScreen();
    expect(left).toBeUndefined();
  });
});
