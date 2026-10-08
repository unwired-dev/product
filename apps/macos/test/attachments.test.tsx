import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { GmailMessageBody } from '../src/message-body.tsx';

// A rendered host/store test of received attachments. Only WebKit is substituted.
describe('received attachments in the reader', () => {
  it('lists attachments, then downloads, opens and shares one only when asked', async () => {
    expect.hasAssertions();
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
        screen.findByText('2 attachments'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText('18 bytes')).toBeOnTheScreen();
      expect(
        gmail.requests.filter(({ path }) => path.includes('/attachments/')),
      ).toHaveLength(0);

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
