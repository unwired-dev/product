import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useLayoutEffect } from 'react';

import { languageStorage } from '../src/language-storage.ts';
import { localization } from '../src/localization.ts';
import { GmailMessageBody } from '../src/message-body.tsx';

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
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
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
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
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
      screen.getByText('Show 20 more');
      await fireEvent.press(more);
      expect(screen.getAllByText(/^Download$/u)).toHaveLength(40);
      screen.getByText('Show 5 more');
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
        <GmailMessageBody
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
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
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
          <GmailMessageBody
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
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
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
        <GmailMessageBody
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
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const app = await render(
      <GmailMessageBody
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
        screen.getByLabelText('Try downloading notes.txt again'),
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
