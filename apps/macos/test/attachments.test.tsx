import type { TurboModule } from 'react-native';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useLayoutEffect } from 'react';
import {
  AccessibilityInfo,
  ScrollView,
  TurboModuleRegistry,
} from 'react-native';

import {
  SaveFailedNotice,
  SaveOutcomeToast,
  useRememberedDownloads,
  useSaveOutcome,
} from '../src/attachment-save.tsx';
import { languageStorage } from '../src/language-storage.ts';
import { localization } from '../src/localization.ts';
import {
  DownloadsContext,
  MessageBody,
  ReaderScrollView,
  SaveOutcomeContext,
} from '../src/message-body.tsx';
import { chooseSheetButton, sheetShown } from './native-alert.ts';

// The application callback behind a rendered control, as delayed native input would invoke it.
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

// A rendered host/store test of received attachments. Only WebKit is substituted.
describe('received attachments in the reader', () => {
  it('formats attachment sizes by the selected locale, then downloads, opens and shares only when asked', async () => {
    expect.hasAssertions();
    jest.spyOn(languageStorage, 'getSettings').mockResolvedValueOnce({
      preference: null,
      language: 'en',
      locale: 'en-u-nu-arab',
      timeZone: 'UTC',
    });
    await localization.refresh();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: {
        text: 'Report attached.',
        attachments: [
          {
            filename: 'report.pdf',
            mimeType: 'application/pdf',
            bytes: [...Buffer.from('%PDF-1.7 synthetic')],
          },
          { filename: 'one-byte.txt', mimeType: 'text/plain', bytes: [65] },
        ],
      },
    });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      await expect(
        screen.findByText('3 attachments'),
      ).resolves.toBeOnTheScreen();
      expect([
        screen.getByText('١٨ bytes').props.children,
        screen.getByText('١ byte').props.children,
      ]).toStrictEqual(['١٨ bytes', '١ byte']);
      await act(async () => {
        await localization.setLanguage('en');
      });
      expect({
        sizes: [
          screen.getByText('18 bytes').props.children,
          screen.getByText('1 byte').props.children,
        ],
        downloads: gmail.requests.filter(({ path }) =>
          path.includes('/attachments/'),
        ),
      }).toStrictEqual({ sizes: ['18 bytes', '1 byte'], downloads: [] });

      await fireEvent.press(screen.getByLabelText('Download report.pdf'));
      const open = await screen.findByLabelText('Open report.pdf');
      await fireEvent.press(open);
      await fireEvent.press(screen.getByLabelText('Share report.pdf'));
      expect(gmail.presentations).toStrictEqual([
        { name: 'report.pdf', action: 'open' },
        { name: 'report.pdf', action: 'share' },
      ]);
      // The other attachment was never downloaded.
      expect(screen.getByLabelText('Download notes.txt')).toBeOnTheScreen();
    } finally {
      await app.unmount();
      await localization.setLanguage('en');
      jest.restoreAllMocks();
    }
    // Closing the reader deletes the Downloaded Attachment.
    expect(gmail.savedFiles.size).toBe(0);
  });

  it('renders a message with many attachments in bounded batches', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({
      content: {
        text: 'Many files.',
        attachments: Array.from({ length: 44 }, (_, index) => ({
          filename: `file-${index}.txt`,
          mimeType: 'text/plain',
          bytes: [index],
        })),
      },
    });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        key={id}
        inbox={inbox}
        id={id}
      />,
    );
    try {
      // 44 files plus the default notes.txt.
      await expect(
        screen.findByText('45 attachments'),
      ).resolves.toBeOnTheScreen();
      const more = screen.getByRole('button', {
        name: 'Show more attachments, 25 not shown',
      });
      expect({
        rows: screen.getAllByText(/^Download$/u).length,
        hidden: screen.queryByLabelText('Download file-43.txt'),
        focusable: more.props.focusable,
      }).toStrictEqual({ rows: 20, hidden: null, focusable: true });
      screen.getByText('Show 20 More');
      await fireEvent.press(more);
      expect(screen.getAllByText(/^Download$/u)).toHaveLength(40);
      screen.getByText('Show 5 More');
      await fireEvent.press(
        screen.getByRole('button', {
          name: 'Show more attachments, 5 not shown',
        }),
      );
      screen.getByLabelText('Download file-43.txt');
      expect({
        rows: screen.getAllByText(/^Download$/u).length,
        more: screen.queryByText(/^Show \d+ more$/u),
      }).toStrictEqual({ rows: 45, more: null });
      // A replacement message starts with a fresh batch, even near the MIME part limit.
      const next = gmail.deliver({
        content: {
          text: 'Thousands of files.',
          attachments: Array.from({ length: 9995 }, (_, index) => ({
            filename: `many-${index}.txt`,
            mimeType: 'text/plain',
            bytes: [index % 256],
          })),
        },
      });
      await act(async () => {
        await inbox.load();
      });
      await app.rerender(
        <MessageBody
          key={next}
          inbox={inbox}
          id={next}
        />,
      );
      await screen.findByText('9996 attachments');
      screen.getByRole('button', {
        name: 'Show more attachments, 9976 not shown',
      });
      expect({
        rows: screen.getAllByText(/^Download$/u).length,
        hidden: screen.queryByLabelText('Download many-9994.txt'),
        downloads: gmail.requests.filter(({ path }) =>
          path.includes('/attachments/'),
        ),
        saved: gmail.savedFiles.size,
      }).toStrictEqual({ rows: 20, hidden: null, downloads: [], saved: 0 });
    } finally {
      await app.unmount();
    }
  });

  it('ignores an Open press from the previous message delivered after the reader changed', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const first = gmail.deliver({ content: { text: 'First.' } });
    const second = gmail.deliver({ content: { text: 'Second.' } });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={first}
      />,
    );
    try {
      await fireEvent.press(await screen.findByLabelText('Download notes.txt'));
      // Native input queued against the first message's Open control.
      const staleOpen = pressHandler(
        await screen.findByLabelText('Open notes.txt'),
      );
      // Delivered during the switch's commit, before the previous reader's passive cleanup.
      await app.rerender(
        <>
          <MessageBody
            inbox={inbox}
            id={second}
          />
          <CommitProbe inspect={staleOpen} />
        </>,
      );
      await act(async () => {
        await Promise.resolve();
      });
      expect(gmail.presentations).toStrictEqual([]);
    } finally {
      await app.unmount();
    }
  });

  it('ignores a Cancel press from the previous reader while a new reader downloads the same attachment', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ content: { text: 'Notes attached.' } });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        key="previous"
        inbox={inbox}
        id={id}
      />,
    );
    const save = gmail.native.saveAttachment;
    let release: () => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- Keep both saves pending until the stale Cancel is delivered.
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    gmail.native.saveAttachment = async (...args) => {
      await held;
      return save(...args);
    };
    try {
      await fireEvent.press(await screen.findByLabelText('Download notes.txt'));
      const staleCancel = pressHandler(
        await screen.findByLabelText('Cancel downloading notes.txt'),
      );
      // Closing the previous reader cancels its attempt; the replacement owns a new one.
      await app.rerender(
        <MessageBody
          key="replacement"
          inbox={inbox}
          id={id}
        />,
      );
      await fireEvent.press(await screen.findByLabelText('Download notes.txt'));
      await act(async () => {
        staleCancel();
      });
      expect(
        screen.getByLabelText('Cancel downloading notes.txt'),
      ).toBeOnTheScreen();
      await act(async () => {
        release();
      });
      await expect(
        screen.findByLabelText('Open notes.txt'),
      ).resolves.toBeOnTheScreen();
    } finally {
      release();
      await app.unmount();
    }
    expect(gmail.savedFiles.size).toBe(0);
  });

  it('cancels a slow download and offers Try again after Gmail fails', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ content: { text: 'Notes attached.' } });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      const request = gmail.native.gmailRequest;
      let release: () => void = () => undefined;
      // oxlint-disable-next-line promise/avoid-new -- Hold Gmail's answer until the download is cancelled.
      const held = new Promise<void>((resolve) => {
        release = resolve;
      });
      gmail.native.gmailRequest = async (...args) => {
        await held;
        return request(...args);
      };
      const download = await screen.findByLabelText('Download notes.txt');
      await fireEvent.press(download);
      expect(screen.getByText('Downloading…')).toBeOnTheScreen();
      await fireEvent.press(
        screen.getByLabelText('Cancel downloading notes.txt'),
      );
      await act(async () => {
        release();
        await Promise.resolve();
      });
      expect(screen.getByLabelText('Download notes.txt')).toBeOnTheScreen();
      gmail.native.gmailRequest = request;

      gmail.fail({ code: 'unavailable' });
      await fireEvent.press(screen.getByLabelText('Download notes.txt'));
      await expect(
        screen.findByText(
          'Gmail could not be reached to download this attachment.',
        ),
      ).resolves.toBeOnTheScreen();
      await fireEvent.press(
        screen.getByLabelText('Try Again to download notes.txt'),
      );
      await expect(
        screen.findByLabelText('Open notes.txt'),
      ).resolves.toBeOnTheScreen();
      expect(gmail.savedFiles.size).toBe(1);
    } finally {
      await app.unmount();
    }
  });

  it('says an attachment did not download when saving it fails, and Try Again downloads it', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ content: { text: 'Notes attached.' } });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={id}
      />,
    );
    const save = gmail.native.saveAttachment;
    gmail.native.saveAttachment = () => {
      gmail.native.saveAttachment = save;
      return Promise.reject(new Error('Synthetic save failure'));
    };
    try {
      await fireEvent.press(await screen.findByLabelText('Download notes.txt'));
      await expect(
        screen.findByText(
          'This attachment didn’t download. Choose Try Again to download it.',
        ),
      ).resolves.toBeOnTheScreen();
      expect(gmail.savedFiles.size).toBe(0);
      await fireEvent.press(
        screen.getByLabelText('Try Again to download notes.txt'),
      );
      await expect(
        screen.findByLabelText('Open notes.txt'),
      ).resolves.toBeOnTheScreen();
      expect(gmail.savedFiles.size).toBe(1);
    } finally {
      await app.unmount();
    }
  });
});

// The native context menu around a rendered control.
const contextMenuOf = (element: Parameters<typeof fireEvent.press>[0]) => {
  let node = element.parent;
  while (node !== null && node.type !== 'UnwiredContextMenu') {
    node = node.parent;
  }
  if (node === null) {
    throw new Error('Expected a context menu');
  }
  return node;
};

// A Mac reader's Save As… outcomes around one message body.
function SavingReader({
  inbox,
  id,
  readable = true,
  account = 'account',
}: {
  readonly inbox: ReturnType<typeof createInboxStore>;
  readonly id: string;
  // False while storage is locked.
  readonly readable?: boolean;
  // The signed-in Product Account, whose Default Profile remembers Downloads on this Mac.
  readonly account?: string;
}) {
  const saving = useSaveOutcome(id, readable);
  const downloads = useRememberedDownloads({ account }, 'default');
  return (
    <SaveOutcomeContext value={saving.start}>
      <DownloadsContext value={downloads}>
        <ReaderScrollView>
          <SaveFailedNotice shown={saving.shown} />
          <MessageBody
            inbox={inbox}
            id={id}
          />
        </ReaderScrollView>
        <SaveOutcomeToast shown={saving.shown} />
      </DownloadsContext>
    </SaveOutcomeContext>
  );
}

// The save panel's reply for a copy saved as Downloads/notes 2.txt.
const savedInDownloads = {
  name: 'notes 2.txt',
  folder: 'Downloads',
  show: 'file:///Users/person/Downloads/notes%202.txt',
};

// The attachment's context menu items as now rendered, and a way to choose one by its title.
const attachmentMenu = async () => {
  const menu = contextMenuOf(await screen.findByLabelText('Open notes.txt'));
  const sections: ReadonlyArray<{
    items: ReadonlyArray<{ id: string; title: string }>;
  }> = menu.props.sections;
  const items = sections.flatMap((section) => section.items);
  const choose = async (title: string) => {
    const item = items.find((candidate) => candidate.title === title);
    await fireEvent(menu, 'select', { nativeEvent: { id: item?.id } });
  };
  return { items, choose };
};

// Renders a reader around one downloaded notes.txt, with its context menu and Save As… item.
const openSaving = async (account = 'account') => {
  const gmail = createSyntheticGmail();
  const id = gmail.deliver({ content: { text: 'Notes attached.' } });
  const inbox = createInboxStore(gmail.native);
  await inbox.load();
  const app = await render(
    <SavingReader
      inbox={inbox}
      id={id}
      account={account}
    />,
  );
  await fireEvent.press(await screen.findByLabelText('Download notes.txt'));
  const { items, choose } = await attachmentMenu();
  const save = async () => {
    await choose('Save As…');
  };
  return { gmail, inbox, id, app, items, save };
};

// The native preferences behind the reader, as this Mac saved them.
const preferences = () =>
  TurboModuleRegistry.getEnforcing<
    TurboModule &
      Readonly<{
        preference: (key: string) => Promise<unknown>;
        setPreference: (key: string, value: string) => Promise<unknown>;
      }>
  >('UnwiredRegistration');

// Only the native window host is substituted; returns the windows it brought forward and the
// files it was asked to reveal.
const finderHost = () => {
  const get = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  const focusWindow = jest.fn<undefined, [string]>();
  const showInFinder = jest.fn<undefined, [string]>();
  const host: TurboModule &
    Readonly<{
      focusWindow: typeof focusWindow;
      showInFinder: typeof showInFinder;
    }> = { focusWindow, showInFinder };
  jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name) =>
      name === 'UnwiredCommands' ? host : get(name),
    );
  return host;
};

describe('saving a received attachment with Save As…', () => {
  it('offers Save As… between Quick Look and Share, brings its window forward, and names the saved copy and its folder with Show in Finder', async () => {
    expect.hasAssertions();
    const { focusWindow, showInFinder } = finderHost();
    const { gmail, app, items, save } = await openSaving();
    jest
      .spyOn(gmail.native, 'presentAttachment')
      .mockResolvedValueOnce(savedInDownloads);
    try {
      expect(items.map(({ title }) => title)).toStrictEqual([
        'Quick Look',
        'Save As…',
        'Share…',
      ]);
      await save();
      await expect(
        screen.findByText('Saved “notes 2.txt” to Downloads'),
      ).resolves.toBeOnTheScreen();
      await fireEvent.press(
        screen.getByLabelText('Show notes 2.txt in Finder'),
      );
      expect({
        focused: focusWindow.mock.calls,
        revealed: showInFinder.mock.calls,
      }).toStrictEqual({
        // The palette's default window, as this reader renders outside an Inbox window.
        focused: [['inbox-window-']],
        revealed: [['file:///Users/person/Downloads/notes%202.txt']],
      });
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });

  it('says nothing when the person cancels the save panel', async () => {
    expect.hasAssertions();
    const { gmail, app, save } = await openSaving();
    try {
      gmail.cancelSave();
      await save();
      expect({
        presentations: gmail.presentations,
        failed: screen.queryByText('Couldn’t save “notes.txt”'),
        saved: screen.queryByText(/^Saved/u),
      }).toStrictEqual({
        presentations: [{ name: 'notes.txt', action: 'save' }],
        failed: null,
        saved: null,
      });
    } finally {
      await app.unmount();
    }
  });

  it('reports nothing for a save that finishes after storage locked and unlocked again', async () => {
    expect.hasAssertions();
    const { gmail, inbox, id, app, save } = await openSaving();
    // React Native's preset mock keeps the calls earlier tests made.
    const announce = jest
      .spyOn(AccessibilityInfo, 'announceForAccessibility')
      .mockClear();
    let finish: (reply: unknown) => void = () => undefined;
    // oxlint-disable-next-line promise/avoid-new -- The test controls when the save panel answers.
    const answer = new Promise<unknown>((resolve) => {
      finish = resolve;
    });
    jest.spyOn(gmail.native, 'presentAttachment').mockReturnValueOnce(answer);
    try {
      await save();
      await app.rerender(
        <SavingReader
          inbox={inbox}
          id={id}
          readable={false}
        />,
      );
      await app.rerender(
        <SavingReader
          inbox={inbox}
          id={id}
        />,
      );
      await act(async () => {
        finish(savedInDownloads);
      });
      expect({
        saved: screen.queryByText('Saved “notes 2.txt” to Downloads'),
        announced: announce.mock.calls,
      }).toStrictEqual({ saved: null, announced: [] });
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });

  it('names the chosen folder when writing there fails, and the file when no panel could open, scrolling up to say so', async () => {
    expect.hasAssertions();
    const { gmail, app, save } = await openSaving();
    jest
      .spyOn(gmail.native, 'presentAttachment')
      .mockResolvedValueOnce({ failed: 'Home' });
    const scrollTo = jest.spyOn(ScrollView.prototype, 'scrollTo');
    try {
      await save();
      await expect(
        screen.findByLabelText('Couldn’t save to Home The file was not saved.'),
      ).resolves.toBeOnTheScreen();
      expect(scrollTo.mock.calls).toStrictEqual([[{ y: 0 }]]);
      jest.restoreAllMocks();
      gmail.failPresent('unavailable');
      await save();
      await expect(
        screen.findByLabelText(
          'Couldn’t save “notes.txt” The file was not saved.',
        ),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.queryByLabelText(
          'Couldn’t save to Home The file was not saved.',
        ),
      ).not.toBeOnTheScreen();
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });
});

describe('saving a received attachment to Downloads', () => {
  it('offers Save to Downloads once a Save As… copy landed there, then saves there directly', async () => {
    expect.hasAssertions();
    const setPreference = jest.spyOn(preferences(), 'setPreference');
    const { gmail, app, items, save } = await openSaving('remembers');
    const present = jest.spyOn(gmail.native, 'presentAttachment');
    try {
      expect(items.map(({ title }) => title)).not.toContain(
        'Save to Downloads',
      );
      present.mockResolvedValueOnce({ ...savedInDownloads, downloads: true });
      await save();
      await expect(
        screen.findByText('Saved “notes 2.txt” to Downloads'),
      ).resolves.toBeOnTheScreen();
      const menu = await attachmentMenu();
      expect(menu.items.map(({ title }) => title)).toStrictEqual([
        'Quick Look',
        'Save to Downloads',
        'Save As…',
        'Share…',
      ]);
      present.mockResolvedValueOnce({
        name: 'notes.txt',
        folder: 'Downloads',
        show: 'file:///Users/person/Downloads/notes.txt',
        downloads: true,
      });
      await menu.choose('Save to Downloads');
      await expect(
        screen.findByText('Saved “notes.txt” to Downloads'),
      ).resolves.toBeOnTheScreen();
      expect({
        actions: present.mock.calls.map((call) => call[2]),
        remembered: setPreference.mock.calls,
      }).toStrictEqual({
        actions: ['save', 'downloads'],
        remembered: [['attachment-save-folder:remembers:default', 'downloads']],
      });
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });

  it('keeps a Save As… copy elsewhere from remembering Downloads, and reads a Profile that already did', async () => {
    expect.hasAssertions();
    // The elsewhere Profile has saved nothing; the already Profile remembered Downloads.
    const preference = jest
      .spyOn(preferences(), 'preference')
      .mockResolvedValueOnce({ value: null })
      .mockResolvedValueOnce({ value: 'downloads' });
    try {
      const elsewhere = await openSaving('elsewhere');
      jest
        .spyOn(elsewhere.gmail.native, 'presentAttachment')
        .mockResolvedValueOnce({ ...savedInDownloads, folder: 'Home' });
      await elsewhere.save();
      await expect(
        screen.findByText('Saved “notes 2.txt” to Home'),
      ).resolves.toBeOnTheScreen();
      const { items: afterElsewhere } = await attachmentMenu();
      await elsewhere.app.unmount();
      const already = await openSaving('already');
      const { items } = await attachmentMenu();
      await already.app.unmount();
      expect({
        elsewhere: afterElsewhere.map(({ title }) => title),
        already: items.map(({ title }) => title),
        read: preference.mock.calls.map(([key]) => key),
      }).toStrictEqual({
        elsewhere: ['Quick Look', 'Save As…', 'Share…'],
        already: ['Quick Look', 'Save to Downloads', 'Save As…', 'Share…'],
        read: [
          'attachment-save-folder:elsewhere:default',
          'attachment-save-folder:already:default',
        ],
      });
    } finally {
      jest.restoreAllMocks();
    }
  });

  it('asks about a name already in Downloads: Keep Both saves beside it, Replace overwrites it, Cancel saves nothing', async () => {
    expect.hasAssertions();
    jest.spyOn(preferences(), 'preference').mockResolvedValue({
      value: 'downloads',
    });
    const { gmail, app } = await openSaving('collides');
    const present = jest.spyOn(gmail.native, 'presentAttachment');
    const exists = { exists: 'Downloads' };
    const toDownloads = async () => {
      const menu = await attachmentMenu();
      await menu.choose('Save to Downloads');
    };
    try {
      present.mockResolvedValueOnce(exists).mockResolvedValueOnce({
        name: 'notes 2.txt',
        folder: 'Downloads',
        show: 'file:///Users/person/Downloads/notes%202.txt',
        downloads: true,
      });
      await toDownloads();
      expect(sheetShown()).toStrictEqual({
        title: '“notes.txt” already exists',
        detail: 'A file with this name is already in this Mac › Downloads.',
        buttons: ['Keep Both', 'Replace', 'Cancel'],
      });
      await act(async () => {
        chooseSheetButton('Keep Both');
      });
      await expect(
        screen.findByText('Saved “notes 2.txt” to Downloads'),
      ).resolves.toBeOnTheScreen();

      present.mockResolvedValueOnce(exists).mockResolvedValueOnce({
        name: 'notes.txt',
        folder: 'Downloads',
        show: 'file:///Users/person/Downloads/notes.txt',
        downloads: true,
      });
      await toDownloads();
      await act(async () => {
        chooseSheetButton('Replace');
      });
      await expect(
        screen.findByText('Saved “notes.txt” to Downloads'),
      ).resolves.toBeOnTheScreen();

      present.mockResolvedValueOnce(exists);
      await toDownloads();
      await act(async () => {
        chooseSheetButton('Cancel');
      });
      // Leaving the reader withdraws a question still open.
      present.mockResolvedValueOnce(exists);
      await toDownloads();
      expect(sheetShown()?.title).toBe('“notes.txt” already exists');
      await app.unmount();
      expect({
        sheet: sheetShown(),
        actions: present.mock.calls.map((call) => call[2]),
      }).toStrictEqual({
        sheet: undefined,
        actions: [
          'downloads',
          'downloadsKeepBoth',
          'downloads',
          'downloadsReplace',
          'downloads',
          'downloads',
        ],
      });
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });

  it('names Downloads when writing there fails, and keeps Save As… to try again', async () => {
    expect.hasAssertions();
    jest.spyOn(preferences(), 'preference').mockResolvedValue({
      value: 'downloads',
    });
    const { gmail, app } = await openSaving('fails');
    jest
      .spyOn(gmail.native, 'presentAttachment')
      .mockResolvedValueOnce({ failed: 'Downloads' });
    try {
      const menu = await attachmentMenu();
      await menu.choose('Save to Downloads');
      await expect(
        screen.findByLabelText(
          'Couldn’t save to Downloads The file was not saved.',
        ),
      ).resolves.toBeOnTheScreen();
      const { items } = await attachmentMenu();
      expect(items.map(({ title }) => title)).toContain('Save As…');
    } finally {
      await app.unmount();
      jest.restoreAllMocks();
    }
  });
});

// The IMAP Inbox's only listed message.
const imapMessageId = (inbox: ReturnType<typeof createImapInbox>) => {
  const state = inbox.getSnapshot();
  const id = state.kind === 'ready' ? state.messages[0]?.id : undefined;
  if (id === undefined) {
    throw new Error('Expected the delivered IMAP message');
  }
  return id;
};

// The IMAP reader lists the same rows from the message source it downloaded.
describe('received attachments in IMAP mail', () => {
  it('downloads, opens and shares an IMAP attachment, and says when the mail server cannot be reached', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap();
    imap.deliver('INBOX', {
      subject: 'Report',
      raw: [
        'From: Synthetic Sender <sender@example.invalid>',
        'To: alex@example.invalid',
        'Subject: Report',
        'MIME-Version: 1.0',
        'Content-Type: multipart/mixed; boundary="mixed"',
        '',
        '--mixed',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'Report attached.',
        '--mixed',
        'Content-Type: application/pdf; name="report.pdf"',
        'Content-Disposition: attachment; filename="report.pdf"',
        'Content-Transfer-Encoding: base64',
        '',
        Buffer.from('%PDF-1.7 synthetic').toString('base64'),
        '--mixed--',
      ].join('\r\n'),
    });
    const inbox = createImapInbox(imap.native, { connection: 'imap-a' });
    await inbox.load();
    const id = imapMessageId(inbox);
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      await expect(
        screen.findByText('1 attachment'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('18 bytes')).toBeOnTheScreen();

      imap.server.failure = 'offline';
      await fireEvent.press(screen.getByLabelText('Download report.pdf'));
      await expect(
        screen.findByText(
          'The mail server could not be reached to download this attachment.',
        ),
      ).resolves.toBeOnTheScreen();
      imap.server.failure = undefined;
      await fireEvent.press(
        screen.getByLabelText('Try Again to download report.pdf'),
      );
      await fireEvent.press(await screen.findByLabelText('Open report.pdf'));
      await fireEvent.press(screen.getByLabelText('Share report.pdf'));
      expect({
        saved: [...imap.files.savedFiles.values()].map(({ name }) => name),
        presentations: imap.files.presentations,
      }).toStrictEqual({
        saved: ['report.pdf'],
        presentations: [
          { name: 'report.pdf', action: 'open' },
          { name: 'report.pdf', action: 'share' },
        ],
      });
    } finally {
      await app.unmount();
    }
    // Closing the reader deletes the Downloaded Attachment.
    expect(imap.files.savedFiles.size).toBe(0);
  });
});
