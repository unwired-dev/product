import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';

import { ImapMessageBody } from '../src/imap-message-body.tsx';

// Rendered host/store tests.
describe('unavailable message body', () => {
  it('says a body that failed for an unnamed reason didn’t open, and opens it on Try Again', async () => {
    expect.hasAssertions();
    const logged = jest.spyOn(console, 'error').mockReturnValue(undefined);
    const imap = createSyntheticImap({ address: 'alex@example.invalid' });
    const uid = imap.deliver('INBOX', {
      subject: 'Report',
      body: 'Quarterly numbers.',
    });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.server.failure = 'imap-rejected';
    const app = await render(
      <ImapMessageBody
        inbox={inbox}
        id={`7.${uid}.INBOX`}
      />,
    );
    try {
      await expect(
        screen.findByRole('alert', {
          name: 'This message didn’t open. Your saved mail has been kept. Choose Try Again to open it again.',
        }),
      ).resolves.toBeOnTheScreen();
      imap.server.failure = undefined;
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await expect(
        screen.findByText('Quarterly numbers.'),
      ).resolves.toBeOnTheScreen();
    } finally {
      await app.unmount();
      logged.mockRestore();
    }
  });
});
