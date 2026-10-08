import type { NativeTranslation } from '@private-email/mail-core/translation';

import { createGmailInbox } from '@private-email/mail-core/gmail-inbox';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { makeMockInboxStorage } from '@private-email/mail-core/mock-storage';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import {
  createMockMailSession,
  syntheticTranslation,
} from '@private-email/mail-core/testing/mock-session';
import { fireEvent, render, screen } from '@testing-library/react-native';

import { InboxProvider } from '../src/mailbox.tsx';
import { GmailMessageBody } from '../src/message-body.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { MessageTranslation, TranslationContext } from '../src/translation.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest's host adapter boundary.
jest.mock('../src/private-storage.ts', () => ({
  __esModule: true,
  mailboxes: undefined,
}));

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// A promise the test settles.
function deferred() {
  let settle: (value: unknown) => void = () => undefined;
  let fail: (reason: unknown) => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Hold the native answer until the test settles it.
  const promise = new Promise<unknown>((resolve, reject) => {
    settle = resolve;
    fail = reject;
  });
  return { promise, resolve: settle, reject: fail };
}

// A native Translation whose answers the test releases, recording what it was asked.
function scriptedTranslation() {
  const asked: Array<{
    request: string;
    input: string;
    target: string;
    answer: ReturnType<typeof deferred>;
  }> = [];
  const cancelled: string[] = [];
  const native: NativeTranslation = {
    translationLanguages: () =>
      Promise.resolve([
        { code: 'es', name: 'Spanish' },
        { code: 'de', name: 'German' },
        { code: 'en', name: 'English' },
      ]),
    translate: (request, input, target) => {
      const answer = deferred();
      asked.push({ request, input, target, answer });
      return answer.promise;
    },
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  return { native, asked, cancelled };
}

async function openReader(translation: NativeTranslation) {
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
  const reader = (id: string, owner = inbox) => (
    <TranslationContext value={translation}>
      <GmailMessageBody
        inbox={owner}
        id={id}
      />
    </TranslationContext>
  );
  const app = await render(reader(venue));
  await expect(
    screen.findByText('Please confirm the venue by Friday.'),
  ).resolves.toBeOnTheScreen();
  return {
    gmail,
    app,
    showLunch: () => app.rerender(reader(lunch)),
    // The same message in another account's mailbox store.
    switchAccount: async () => {
      const other = createGmailInbox(gmail.native);
      await other.load();
      return app.rerender(reader(venue, other));
    },
  };
}

const translateInto = async (language: string) => {
  await fireEvent.press(
    await screen.findByRole('radio', { name: `Translate into ${language}` }),
  );
};

// A rendered host/store test of the reader's on-device translation. Only WebKit and Apple
// Translation are substituted.
describe('on-device translation in the reader', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one translation path end to end. */
  it('translates only the local text into the chosen language as an unsaved preview', async () => {
    expect.hasAssertions();
    const { native, asked } = scriptedTranslation();
    const { gmail, app } = await openReader(native);
    try {
      const reads = gmail.requests.length;
      await fireEvent.press(screen.getByLabelText('Translate this message'));
      // Nothing is translated until a target language is chosen.
      await screen.findByRole('radio', { name: 'Translate into Spanish' });
      expect(asked).toHaveLength(0);
      await translateInto('Spanish');
      expect(asked).toHaveLength(1);
      expect(asked[0]?.input).toBe('Please confirm the venue by Friday.');
      expect(asked[0]?.target).toBe('es');
      asked[0]?.answer.resolve({
        source: 'en',
        text: 'Confirma el lugar antes del viernes.',
      });
      await expect(
        screen.findByText('Confirma el lugar antes del viernes.'),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.getByText(
          'Translated from English to Spanish on this device. It may be inaccurate and is not saved.',
        ),
      ).toBeOnTheScreen();
      // The message stays readable beside its preview, and translating fetched nothing.
      expect(
        screen.getByText('Please confirm the venue by Friday.'),
      ).toBeOnTheScreen();
      expect(gmail.requests).toHaveLength(reads);

      await fireEvent.press(screen.getByLabelText('Dismiss translation'));
      expect(
        screen.queryByText('Confirma el lugar antes del viernes.'),
      ).toBeNull();
      expect(screen.getByLabelText('Translate this message')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('explains an uninstalled language without downloading and keeps mail readable', async () => {
    expect.hasAssertions();
    const { app } = await openReader(
      createMockMailSession('assistance-unavailable').translation,
    );
    try {
      await fireEvent.press(screen.getByLabelText('Translate this message'));
      await translateInto('Spanish');
      await expect(
        screen.findByText(
          'Download this language in the system Translate settings, then try again. Nothing is downloaded here.',
        ),
      ).resolves.toBeOnTheScreen();
      expect(
        screen.getByText('Please confirm the venue by Friday.'),
      ).toBeOnTheScreen();
      expect(screen.getByLabelText('Translate again')).toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });

  it('cancels on request and drops results after the message or account changes', async () => {
    expect.hasAssertions();
    const { native, asked, cancelled } = scriptedTranslation();
    const { app, showLunch, switchAccount } = await openReader(native);
    try {
      await fireEvent.press(screen.getByLabelText('Translate this message'));
      await translateInto('German');
      await fireEvent.press(await screen.findByLabelText('Cancel translation'));
      expect(screen.getByText('Translation cancelled.')).toBeOnTheScreen();
      expect(cancelled).toStrictEqual([asked[0]?.request]);

      await fireEvent.press(screen.getByLabelText('Translate again'));
      await screen.findByLabelText('Cancel translation');
      await showLunch();
      await expect(
        screen.findByText('Lunch at noon on Tuesday?'),
      ).resolves.toBeOnTheScreen();
      expect(cancelled).toStrictEqual([asked[0]?.request, asked[1]?.request]);
      asked[1]?.answer.resolve({ source: 'en', text: 'Ein verworfener Text.' });
      await expect(
        screen.findByLabelText('Translate this message'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByText('Ein verworfener Text.')).toBeNull();

      // A finished preview belongs to its account's mailbox store too.
      await fireEvent.press(screen.getByLabelText('Translate this message'));
      await translateInto('German');
      asked[2]?.answer.resolve({
        source: 'en',
        text: 'Mittagessen am Dienstag?',
      });
      await screen.findByText('Mittagessen am Dienstag?');
      await switchAccount();
      await expect(
        screen.findByText('Please confirm the venue by Friday.'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByText('Mittagessen am Dienstag?')).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('forgets a translation when the same message text belongs to another mailbox store', async () => {
    expect.hasAssertions();
    const { native, asked, cancelled } = scriptedTranslation();
    const translated = (source: object) => (
      <TranslationContext value={native}>
        <MessageTranslation
          source={source}
          id="message"
          body="Hola"
        />
      </TranslationContext>
    );
    const app = await render(translated({}));
    try {
      await fireEvent.press(screen.getByLabelText('Translate this message'));
      await translateInto('English');
      await screen.findByLabelText('Cancel translation');
      await app.rerender(translated({}));
      expect(cancelled).toStrictEqual([asked[0]?.request]);
      asked[0]?.answer.resolve({ source: 'es', text: 'Hello' });
      await expect(
        screen.findByLabelText('Translate this message'),
      ).resolves.toBeOnTheScreen();
      expect(screen.queryByText('Hello')).toBeNull();
    } finally {
      await app.unmount();
    }
  });

  it('translates the preview fixture with the fixed Mock Mail Session outcome', async () => {
    expect.hasAssertions();
    const session = createMockMailSession('open-read-relaunch');
    const fixture = singleMailbox(
      createPersistentInbox(makeMockInboxStorage(), session.mail.list),
      'preview',
    );
    const app = await render(
      <TranslationContext value={session.translation}>
        <InboxProvider mailboxes={fixture}>
          <MessageDetail
            mailbox="preview"
            id="studio-review"
          />
        </InboxProvider>
      </TranslationContext>,
    );
    try {
      await fireEvent.press(
        await screen.findByLabelText('Translate this message'),
      );
      await translateInto('German');
      await expect(
        screen.findByText(syntheticTranslation),
      ).resolves.toBeOnTheScreen();
    } finally {
      await app.unmount();
    }
  });
});
