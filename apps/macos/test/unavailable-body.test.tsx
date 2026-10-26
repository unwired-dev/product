import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';

import { MessageBody } from '../src/message-body.tsx';

// Rendered host/store tests. The reader is shared, so each provider keeps its own copy and
// retry rule.
describe('unavailable message body', () => {
  it('names the mail server for an IMAP body and tries the download again', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap({ address: 'alex@example.invalid' });
    const uid = imap.deliver('INBOX', {
      subject: 'Report',
      body: 'Quarterly numbers.',
    });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.server.failure = 'offline';
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={`7.${uid}.INBOX`}
      />,
    );
    try {
      await expect(
        screen.findByRole('alert', {
          name: 'This message is not saved on this device, and the mail server could not be reached to download it.',
        }),
      ).resolves.toBeOnTheScreen();
      imap.server.failure = undefined;
      await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
      await expect(
        screen.findByText('Quarterly numbers.'),
      ).resolves.toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('offers no Try again for an IMAP message gone from its folder', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap({ address: 'alex@example.invalid' });
    const uid = imap.deliver('INBOX', { subject: 'Moved elsewhere' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.expunge('INBOX', uid);
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={`7.${uid}.INBOX`}
      />,
    );
    try {
      await expect(
        screen.findByRole('alert', {
          name: 'This message is no longer in this folder on the mail server.',
        }),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('names Gmail for a Gmail body that could not be downloaded', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Not downloaded yet' });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
    const app = await render(
      <MessageBody
        inbox={inbox}
        id={id}
      />,
    );
    try {
      await expect(
        screen.findByRole('alert', {
          name: 'This message is not saved on this device, and Gmail could not be reached to download it.',
        }),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.getByRole('button', { name: 'Try again' }),
      ).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });
});
