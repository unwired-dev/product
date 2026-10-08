import type { NativeAssistance } from '@private-email/mail-core/assistance';

import { summaryCopy } from '@private-email/mail-core/assistance';
import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { fireEvent, render, screen } from '@testing-library/react-native';

import { InboxProvider } from '../src/mailbox.tsx';
import { GmailMessageBody } from '../src/message-body.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// A native model whose answers the test releases, recording what it was asked.
function scriptedAssistance() {
  const asked: Array<{
    request: string;
    input: string;
    answer: (summary: string) => void;
  }> = [];
  const cancelled: string[] = [];
  const native: NativeAssistance = {
    availability: () => Promise.resolve('available'),
    summarize: (request, input) =>
      // oxlint-disable-next-line promise/avoid-new -- Hold the model until the test answers.
      new Promise((resolve) => {
        asked.push({ request, input, answer: resolve });
      }),
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  return { native, asked, cancelled };
}

async function openReader(assistance: NativeAssistance) {
  const gmail = createSyntheticGmail();
  const venue = gmail.deliver({
    subject: 'Venue',
    content: { text: 'Please confirm the venue by Friday.' },
  });
  const lunch = gmail.deliver({
    subject: 'Lunch',
    content: { text: 'Lunch at noon on Tuesday?' },
  });
  const inbox = createGmailInbox(gmail.native);
  await inbox.load();
  const reader = (id: string, subject: string) => (
    <AssistanceContext value={assistance}>
      <GmailMessageBody
        inbox={inbox}
        id={id}
        subject={subject}
      />
    </AssistanceContext>
  );
  const app = await render(reader(venue, 'Venue'));
  await expect(
    screen.findByText('Please confirm the venue by Friday.'),
  ).resolves.toBeOnTheScreen();
  return {
    gmail,
    app,
    showLunch: () => app.rerender(reader(lunch, 'Lunch')),
    showVenue: (subject: string) => app.rerender(reader(venue, subject)),
  };
}

// A rendered host/store test of the reader's on-device summary. Only WebKit and the Apple model
// are substituted.
describe('on-device message summaries in the reader', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one summary path end to end. */
  it('summarizes the opened message only when asked, from its local text', async () => {
    expect.hasAssertions();
    const { native, asked } = scriptedAssistance();
    const { gmail, app } = await openReader(native);
    try {
      expect(asked).toHaveLength(0);
      const reads = gmail.requests.length;
      await fireEvent.press(screen.getByLabelText('Summarize this message'));
      await expect(
        screen.findByText(summaryCopy.summarizing),
      ).resolves.toBeOnTheScreen();
      expect(asked.map(({ input }) => input)).toStrictEqual([
        'Subject: Venue\n\nPlease confirm the venue by Friday.',
      ]);
      asked[0]?.answer('Confirm the venue by Friday.');
      await expect(
        screen.findByText('Confirm the venue by Friday.'),
      ).resolves.toBeOnTheScreen();
      expect(screen.getByText(summaryCopy.disclaimer)).toBeOnTheScreen();
      // The message stays readable beside its preview, and summarizing fetched nothing.
      expect(
        screen.getByText('Please confirm the venue by Friday.'),
      ).toBeOnTheScreen();
      expect(gmail.requests).toHaveLength(reads);

      await fireEvent.press(screen.getByLabelText('Dismiss summary'));
      expect(screen.queryByText('Confirm the venue by Friday.')).toBeNull();
      expect(screen.getByLabelText('Summarize this message')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('keeps the message readable when the Mock Mail Session has no assistance', async () => {
    expect.hasAssertions();
    const { app } = await openReader(
      createMockMailSession('assistance-unavailable').assistance,
    );
    try {
      await fireEvent.press(screen.getByLabelText('Summarize this message'));
      await expect(
        screen.findByText(summaryCopy['model-not-ready']),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.getByText('Please confirm the venue by Friday.'),
      ).toBeOnTheScreen();
      expect(
        screen.getByLabelText('Summarize this message again'),
      ).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('cancels on request and discards a summary that finishes after the message changed', async () => {
    expect.hasAssertions();
    const { native, asked, cancelled } = scriptedAssistance();
    const { app, showLunch } = await openReader(native);
    try {
      await fireEvent.press(screen.getByLabelText('Summarize this message'));
      await fireEvent.press(await screen.findByLabelText('Cancel summary'));
      expect(screen.getByText(summaryCopy.cancelled)).toBeOnTheScreen();
      expect(cancelled).toStrictEqual([asked[0]?.request]);

      await fireEvent.press(
        screen.getByLabelText('Summarize this message again'),
      );
      await screen.findByLabelText('Cancel summary');
      // The reader moves to another message before the model answers.
      await showLunch();
      await expect(
        screen.findByText('Lunch at noon on Tuesday?'),
      ).resolves.toBeOnTheScreen();
      expect(cancelled).toStrictEqual([asked[0]?.request, asked[1]?.request]);
      asked[1]?.answer('Confirm the venue by Friday.');
      await expect(
        screen.findByLabelText('Summarize this message'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByText('Confirm the venue by Friday.')).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('discards previews and pending work when the same message input changes', async () => {
    expect.hasAssertions();
    const { native, asked, cancelled } = scriptedAssistance();
    const { app, showVenue } = await openReader(native);
    try {
      await fireEvent.press(screen.getByLabelText('Summarize this message'));
      await screen.findByLabelText('Cancel summary');
      asked[0]?.answer('Confirm the venue by Friday.');
      await screen.findByText('Confirm the venue by Friday.');
      await showVenue('Updated venue');
      expect(screen.queryByText('Confirm the venue by Friday.')).toBeNull();
      await showVenue('Venue');
      expect(screen.queryByText('Confirm the venue by Friday.')).toBeNull();
      expect(screen.getByLabelText('Summarize this message')).toBeOnTheScreen();

      await fireEvent.press(screen.getByLabelText('Summarize this message'));
      await screen.findByLabelText('Cancel summary');
      await showVenue('Updated venue');
      expect(cancelled).toStrictEqual([asked[1]?.request]);
      asked[1]?.answer('A discarded preview.');
      await showVenue('Venue');
      expect(screen.queryByText('A discarded preview.')).toBeNull();
      expect(screen.getByLabelText('Summarize this message')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('forgets the preview fixture summary when the reader moves to another message', async () => {
    expect.hasAssertions();
    const { native, asked, cancelled } = scriptedAssistance();
    const session = createMockMailSession('open-read-relaunch');
    const fixture = singleMailbox(
      createPersistentInbox(makeMockInboxStorage(), session.mail.list),
      'preview',
    );
    const reader = (id: string) => (
      <AssistanceContext value={native}>
        <InboxProvider mailboxes={fixture}>
          <MessageDetail
            mailbox="preview"
            id={id}
          />
        </InboxProvider>
      </AssistanceContext>
    );
    const app = await render(reader('studio-review'));
    try {
      await fireEvent.press(
        await screen.findByLabelText('Summarize this message'),
      );
      await screen.findByLabelText('Cancel summary');
      expect(asked[0]?.input).toMatch(
        /^Subject: A little more room to think\n\nHi Alex,/u,
      );
      // The fixture body is local, so the summary control stays mounted across messages.
      await app.rerender(reader('weekend-walk'));
      expect(cancelled).toStrictEqual([asked[0]?.request]);
      expect(screen.getByLabelText('Summarize this message')).toBeOnTheScreen();
      asked[0]?.answer('A studio review on Thursday.');
      await expect(
        screen.findByText('Saturday, by the river?'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByText('A studio review on Thursday.')).toBeNull();
    } finally {
      await app.unmount();
    }
  });
  /* oxlint-enable vitest/max-expects */
});
