import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { NativeTranslation } from '@private-email/mail-core/translation';

import { createMailAssistanceEnablement } from '@private-email/mail-core/assistance-enablement';
import {
  createRegistration,
  defaultProfile,
} from '@private-email/mail-core/registration';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import {
  createMockRegistrationSession,
  syntheticRecoveryKey,
} from '@private-email/mail-core/testing/registration-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { Profiler, use } from 'react';

import { Action } from '../src/action.tsx';
import {
  MailAssistanceContext,
  MailAssistanceGate,
} from '../src/mail-assistance.tsx';
import { MessageSummary } from '../src/message-summary.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';
import { DraftTranslation, MessageTranslation } from '../src/translation.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));

// A native model whose summaries the test releases, recording every call that reached it.
function scriptedAssistance() {
  const calls: string[] = [];
  const answers: Array<(summary: string) => void> = [];
  const cancelled: string[] = [];
  const native: NativeAssistance = {
    availability: () => {
      calls.push('availability');
      return Promise.resolve('available');
    },
    summarize: () => {
      calls.push('summarize');
      // oxlint-disable-next-line promise/avoid-new -- Hold the model until the test answers.
      return new Promise((resolve) => {
        answers.push(resolve);
      });
    },
    rewrite: () => Promise.reject(new Error('unused')),
    suggestReply: () => Promise.reject(new Error('unused')),
    cancel: (request) => {
      cancelled.push(request);
      return Promise.resolve(null);
    },
  };
  return { native, calls, answers, cancelled };
}

const body = 'Please confirm the venue by Friday.';
const message = {};

// The Inbox's reader actions for one already-local message, and the way to the account page.
function Reader() {
  const account = use(AccountContext);
  return (
    <>
      <MessageSummary
        source={message}
        id="venue"
        subject="Venue"
        body={body}
      />
      <MessageTranslation
        source={message}
        id="venue"
        body={body}
      />
      <Action
        label="Account"
        onPress={() => {
          account?.openAccount();
        }}
      />
    </>
  );
}

const press = async (name: string) => {
  await act(async () => {
    await fireEvent.press(screen.getByRole('button', { name }));
  });
};

// A rendered journey through the real registration gate, enablement store and reader, over the
// synthetic registration session; only the Apple model and Translation are substituted.
describe('mail Assistance Enablement on iPhone and iPad', () => {
  it('refuses a Translation language lookup after Off between commit and passive effects', async () => {
    expect.hasAssertions();
    const owner = 'synthetic-product-account';
    const enablement = createMailAssistanceEnablement({
      mailAssistance: () =>
        Promise.resolve({ owner, profiles: [defaultProfile] }),
      setMailAssistance: (account, profiles) =>
        Promise.resolve({ owner: account, profiles }),
    });
    await enablement.load(owner);
    const calls: string[] = [];
    const { assistance, translation: mockTranslation } =
      createMockMailSession('open-read-relaunch');
    const translation: NativeTranslation = {
      ...mockTranslation,
      translationLanguages: () => {
        calls.push('languages');
        return mockTranslation.translationLanguages();
      },
    };
    let off: Promise<void> | undefined = undefined;
    await render(
      <MailAssistanceContext value={enablement}>
        <MailAssistanceGate
          account={owner}
          assistance={assistance}
          translation={translation}>
          <Profiler
            id="translation"
            // Retire enablement after layout setup, before the language-list passive effect.
            onRender={() => {
              off = enablement.setEnabled(owner, defaultProfile, false);
            }}>
            <DraftTranslation
              translator={translation}
              text={body}
              onApply={() => undefined}
              onClose={() => undefined}
            />
          </Profiler>
        </MailAssistanceGate>
      </MailAssistanceContext>,
    );
    await off;
    expect(enablement.getSnapshot()?.profiles).toStrictEqual([]);
    expect(calls).toStrictEqual([]);
  });

  /* oxlint-disable vitest/max-expects -- The journey proves the gate end to end. */
  it('keeps assistance hidden until enabled, ends it when disabled and forgets it on sign-out', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    const enablement = createMailAssistanceEnablement(session.mailAssistance);
    const assistance = scriptedAssistance();
    const translated: string[] = [];
    const { translation: mockTranslation } =
      createMockMailSession('open-read-relaunch');
    const translation: NativeTranslation = {
      ...mockTranslation,
      translationLanguages: () => {
        translated.push('languages');
        return mockTranslation.translationLanguages();
      },
    };
    const signIn = async () => {
      await act(async () => {
        await store.register('google');
        await store.addMailbox(false);
        await store.confirmRecoveryKey(syntheticRecoveryKey.slice(-4));
      });
    };
    await render(
      <RegistrationGate
        store={store}
        preview={false}
        mailAssistance={enablement}
        assistance={assistance.native}
        translation={translation}>
        <Reader />
      </RegistrationGate>,
    );
    await signIn();

    // Off by default: no assistance action is offered and nothing reaches either framework.
    expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).not.toBeOnTheScreen();
    expect(
      screen.queryByRole('button', { name: 'Translate this message' }),
    ).not.toBeOnTheScreen();

    // Turning it on from the account page starts nothing.
    await press('Account');
    expect(screen.getByText('On-device assistance is off.')).toBeVisible();
    await press('Turn on on-device assistance');
    expect(screen.getByText('On-device assistance is on.')).toBeVisible();
    await press('Open Inbox');
    expect(
      screen.getByRole('button', { name: 'Translate this message' }),
    ).toBeVisible();
    expect(assistance.calls).toStrictEqual([]);
    expect(translated).toStrictEqual([]);

    // Off fences queued input before React commits the hidden action.
    await act(async () => {
      const off = enablement.setEnabled(
        'synthetic-product-account',
        defaultProfile,
        false,
      );
      fireEvent.press(
        screen.getByRole('button', { name: 'Summarize this message' }),
      );
      await off;
    });
    expect(assistance.calls).toStrictEqual([]);
    await act(async () => {
      await enablement.setEnabled(
        'synthetic-product-account',
        defaultProfile,
        true,
      );
    });

    await press('Summarize this message');
    expect(assistance.calls).toStrictEqual(['availability', 'summarize']);
    expect(screen.getByText('Summarizing on this device…')).toBeVisible();
    await act(async () => {
      await enablement.setEnabled(
        'synthetic-product-account',
        defaultProfile,
        false,
      );
    });
    expect(assistance.cancelled).toHaveLength(1);
    expect(
      screen.queryByText('Summarizing on this device…'),
    ).not.toBeOnTheScreen();
    await act(async () => {
      assistance.answers[0]?.('A late summary.');
      await Promise.resolve();
    });
    expect(screen.queryByText('A late summary.')).not.toBeOnTheScreen();

    // Turning it on again offers the action without requesting anything.
    await act(async () => {
      await enablement.setEnabled(
        'synthetic-product-account',
        defaultProfile,
        true,
      );
    });
    expect(
      screen.getByRole('button', { name: 'Summarize this message' }),
    ).toBeVisible();
    expect(assistance.calls).toStrictEqual(['availability', 'summarize']);

    // Signing out removes it; the same account signing in again starts with assistance off.
    await press('Account');
    await act(async () => {
      await store.signOut();
    });
    await signIn();
    expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).not.toBeOnTheScreen();
    await press('Account');
    expect(screen.getByText('On-device assistance is off.')).toBeVisible();
  });
});
