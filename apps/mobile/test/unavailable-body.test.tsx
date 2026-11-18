import type { ReactElement } from 'react';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import { fireEvent, render, screen } from '@testing-library/react-native';
import { AccessibilityInfo } from 'react-native';

import { ImapMessageBody } from '../src/imap-message-body.tsx';
import {
  AnnouncedFailuresContext,
  GmailMessageBody,
} from '../src/message-body.tsx';

// The iPhone and iPad frames draw the body states differently, so each case sets the device.
const onDevice = (isPad: boolean) =>
  jest.replaceProperty(
    jest.requireActual<{ ipad: boolean }>('../src/inbox-styles.ts'),
    'ipad',
    isPad,
  );

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
      expect(screen.getByText('Couldn’t load this message')).toBeOnTheScreen();
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

  it.each([
    [false, 'It’s still in Gmail. Check your connection, then try again.'],
    [
      true,
      'Gmail didn’t respond, so the message text isn’t on this iPad yet. Nothing was changed.',
    ],
  ])(
    'says what each device’s frame says for a Gmail body that could not be downloaded, once (isPad=%s)',
    async (isPad, sentence) => {
      expect.hasAssertions();
      const device = onDevice(isPad);
      const announce = jest.mocked(
        AccessibilityInfo.announceForAccessibilityWithOptions,
      );
      announce.mockClear();
      const gmail = createSyntheticGmail();
      const id = gmail.deliver({ subject: 'Not downloaded yet' });
      const inbox = createInboxStore(gmail.native);
      await inbox.load();
      gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
      const app = await render(
        <GmailMessageBody
          inbox={inbox}
          id={id}
        />,
      );
      try {
        await expect(
          screen.findByRole('alert', { name: sentence }),
        ).resolves.toBeOnTheScreen();
        expect(
          screen.getByRole('button', { name: 'Try Again' }),
        ).toBeOnTheScreen();
        expect(announce.mock.calls).toStrictEqual([
          [sentence, { queue: true }],
        ]);
      } finally {
        await app.unmount();
        device.restore();
      }
    },
  );

  it('announces a Thread message’s failure once as it scrolls away and back, and again after Try Again', async () => {
    expect.hasAssertions();
    const sentence =
      'It’s still in Gmail. Check your connection, then try again.';
    const announce = jest.mocked(
      AccessibilityInfo.announceForAccessibilityWithOptions,
    );
    announce.mockClear();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Not downloaded yet' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const offline = () => {
      gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
    };
    const announced = new Set<string>();
    const body = (
      <GmailMessageBody
        inbox={inbox}
        id={id}
      />
    );
    const thread = (message: ReactElement | null) => (
      <AnnouncedFailuresContext value={announced}>
        {message}
      </AnnouncedFailuresContext>
    );
    offline();
    const app = await render(thread(body));
    try {
      await expect(
        screen.findByRole('alert', { name: sentence }),
      ).resolves.toBeOnTheScreen();
      offline();
      await app.rerender(thread(null));
      await app.rerender(thread(body));
      await expect(
        screen.findByRole('alert', { name: sentence }),
      ).resolves.toBeOnTheScreen();
      expect(announce.mock.calls).toStrictEqual([[sentence, { queue: true }]]);
      offline();
      await fireEvent.press(screen.getByRole('button', { name: 'Try Again' }));
      await expect(
        screen.findByRole('alert', { name: sentence }),
      ).resolves.toBeOnTheScreen();
      expect(announce.mock.calls).toStrictEqual([
        [sentence, { queue: true }],
        [sentence, { queue: true }],
      ]);
    } finally {
      await app.unmount();
    }
  });

  it('announces a Thread message’s new failure after it scrolls away and back', async () => {
    expect.hasAssertions();
    const offline =
      'It’s still in Gmail. Check your connection, then try again.';
    const gone = 'This message is no longer in Gmail.';
    const announce = jest.mocked(
      AccessibilityInfo.announceForAccessibilityWithOptions,
    );
    announce.mockClear();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ subject: 'Deleted while away' });
    const inbox = createInboxStore(gmail.native);
    await inbox.load();
    const announced = new Set<string>();
    const body = (
      <GmailMessageBody
        inbox={inbox}
        id={id}
      />
    );
    const thread = (message: ReactElement | null) => (
      <AnnouncedFailuresContext value={announced}>
        {message}
      </AnnouncedFailuresContext>
    );
    gmail.fail({ code: 'unavailable' }, { code: 'unavailable' });
    const app = await render(thread(body));
    try {
      await expect(
        screen.findByRole('alert', { name: offline }),
      ).resolves.toBeOnTheScreen();
      gmail.fail({ status: 404 });
      await app.rerender(thread(null));
      await app.rerender(thread(body));
      await expect(
        screen.findByRole('alert', { name: gone }),
      ).resolves.toBeOnTheScreen();
      expect(announce.mock.calls).toStrictEqual([
        [offline, { queue: true }],
        [gone, { queue: true }],
      ]);
    } finally {
      await app.unmount();
    }
  });

  it('offers no Try Again for an IMAP message gone from its folder', async () => {
    expect.hasAssertions();
    const imap = createSyntheticImap({ address: 'alex@example.invalid' });
    const uid = imap.deliver('INBOX', { subject: 'Moved elsewhere' });
    const inbox = createImapInbox(imap.native);
    await inbox.load();
    imap.expunge('INBOX', uid);
    const app = await render(
      <ImapMessageBody
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
      expect(screen.queryByRole('button', { name: 'Try Again' })).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it.each([
    [false, 'Loading message…'],
    [true, 'Downloading from the mail server…'],
  ])(
    'shows the body loading as one progress element until it arrives (isPad=%s)',
    async (isPad, progress) => {
      expect.hasAssertions();
      const device = onDevice(isPad);
      const imap = createSyntheticImap({ address: 'alex@example.invalid' });
      const uid = imap.deliver('INBOX', {
        subject: 'Report',
        body: 'Quarterly numbers.',
      });
      // The mail server answers the body download only once the test has seen the progress.
      const answered = Promise.withResolvers<undefined>();
      const inbox = createImapInbox({
        ...imap.native,
        imapMessage: async (...request) => {
          await answered.promise;
          return imap.native.imapMessage(...request);
        },
      });
      await inbox.load();
      const app = await render(
        <ImapMessageBody
          inbox={inbox}
          id={`7.${uid}.INBOX`}
        />,
      );
      try {
        await expect(
          screen.findByRole('progressbar', { name: progress }),
        ).resolves.toBeOnTheScreen();
        answered.resolve(undefined);
        await expect(
          screen.findByText('Quarterly numbers.'),
        ).resolves.toBeOnTheScreen();
        expect(screen.queryByRole('progressbar')).toBeNull();
      } finally {
        answered.resolve(undefined);
        await app.unmount();
        device.restore();
      }
    },
  );
});
