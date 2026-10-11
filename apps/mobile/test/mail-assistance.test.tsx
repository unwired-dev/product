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
  MailAssistanceSettings,
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
const settingsButton = (label: string, action: () => Promise<void>) => (
  <Action
    label={label}
    onPress={() => {
      void action();
    }}
  />
);

// Real enablement and availability stores, with only the native model boundary substituted.
describe('account settings availability', () => {
  const outcomes = [
    [
      'available',
      'Apple Intelligence is available for summaries, rewrites and reply suggestions.',
    ],
    ['device-ineligible', 'This device does not support Apple Intelligence.'],
    ['assistance-disabled', 'Turn on Apple Intelligence in system settings.'],
    [
      'model-not-ready',
      'Apple Intelligence is still getting ready. Try again later.',
    ],
    [
      'unsupported-locale',
      'Apple Intelligence is not available in this device’s language yet.',
    ],
  ];

  it.each(outcomes)(
    'explains %s only after an explicit check without generating mail',
    async (outcome, copy) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
      const registration = createRegistration(session.native);
      await registration.register('google');
      const enablement = createMailAssistanceEnablement(session.mailAssistance);
      await enablement.load('signed-in');
      const assistance = scriptedAssistance();
      const native: NativeAssistance = {
        ...assistance.native,
        availability: () => {
          assistance.calls.push('availability');
          return Promise.resolve(outcome);
        },
        rewrite: () => {
          assistance.calls.push('rewrite');
          return Promise.resolve('Unexpected rewrite');
        },
        suggestReply: () => {
          assistance.calls.push('reply');
          return Promise.resolve('Unexpected reply');
        },
      };
      await render(
        <MailAssistanceContext value={enablement}>
          <MailAssistanceSettings
            account="synthetic-product-account"
            assistance={native}
            button={settingsButton}
          />
        </MailAssistanceContext>,
      );
      await press('Turn on on-device assistance');
      expect(assistance.calls).toStrictEqual([]);
      await press('Check Apple Intelligence availability');
      expect(screen.getByText(copy)).toBeVisible();
      expect(assistance.calls).toStrictEqual(['availability']);
    },
  );

  it('reports an unsaved Off choice and retries it without reopening assistance', async () => {
    expect.hasAssertions();
    const owner = 'synthetic-account';
    let profiles: readonly string[] = [defaultProfile];
    const failure = Object.assign(new Error('locked'), { code: 'locked' });
    const enablement = createMailAssistanceEnablement({
      mailAssistance: () => Promise.resolve({ owner, profiles }),
      setMailAssistance: jest
        .fn((account, next: readonly string[]) => {
          profiles = next;
          return Promise.resolve({ owner: account, profiles });
        })
        .mockRejectedValueOnce(failure),
    });
    await enablement.load(owner);
    const assistance = scriptedAssistance();
    const { translation } = createMockMailSession('open-read-relaunch');
    await render(
      <MailAssistanceContext value={enablement}>
        <MailAssistanceSettings
          account={owner}
          assistance={assistance.native}
          button={settingsButton}
        />
        <MailAssistanceGate
          account={owner}
          assistance={assistance.native}
          translation={translation}>
          <Reader />
        </MailAssistanceGate>
      </MailAssistanceContext>,
    );
    await press('Turn off on-device assistance');
    expect(
      screen.getByText(
        "This device's assistance choice could not be saved. Try again before leaving this page.",
      ),
    ).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).not.toBeOnTheScreen();
    await press('Try saving assistance choice again');
    await act(async () => {
      await enablement.load('reopened');
    });
    expect(screen.getByText('On-device assistance is off.')).toBeVisible();
    expect(
      screen.queryByRole('button', {
        name: 'Try saving assistance choice again',
      }),
    ).not.toBeOnTheScreen();
    expect(assistance.calls).toStrictEqual([]);
  });

  it('forgets pending checks across Off, another account and unmount, and refuses queued input', async () => {
    expect.hasAssertions();
    let owner = 'first-account';
    const enablement = createMailAssistanceEnablement({
      mailAssistance: () =>
        Promise.resolve({ owner, profiles: [defaultProfile] }),
      setMailAssistance: (account, profiles) =>
        Promise.resolve({ owner: account, profiles }),
    });
    await enablement.load(owner);
    const assistance = scriptedAssistance();
    const answers: Array<(result: string) => void> = [];
    const native: NativeAssistance = {
      ...assistance.native,
      availability: () => {
        assistance.calls.push('availability');
        // oxlint-disable-next-line promise/avoid-new -- Release availability after its owner is retired.
        return new Promise((resolve) => {
          answers.push(resolve);
        });
      },
    };
    const settings = () => (
      <MailAssistanceContext value={enablement}>
        <MailAssistanceSettings
          account={owner}
          assistance={native}
          button={settingsButton}
        />
      </MailAssistanceContext>
    );
    const view = await render(settings());
    await press('Check Apple Intelligence availability');
    expect(
      screen.getByText('Checking Apple Intelligence availability…'),
    ).toBeVisible();
    await act(async () => {
      const off = enablement.setEnabled(owner, defaultProfile, false);
      fireEvent.press(
        screen.getByRole('button', {
          name: 'Check Apple Intelligence availability',
        }),
      );
      await off;
    });
    await press('Turn on on-device assistance');
    await act(async () => {
      answers[0]?.('available');
    });
    expect(
      screen.queryByText(
        'Apple Intelligence is available for summaries, rewrites and reply suggestions.',
      ),
    ).not.toBeOnTheScreen();
    expect(assistance.calls).toStrictEqual(['availability']);
    await press('Check Apple Intelligence availability');
    owner = 'second-account';
    await act(async () => {
      await enablement.load(owner);
    });
    await view.rerender(settings());
    await act(async () => {
      answers[1]?.('device-ineligible');
    });
    expect(
      screen.queryByText('This device does not support Apple Intelligence.'),
    ).not.toBeOnTheScreen();
    await press('Check Apple Intelligence availability');
    await view.unmount();
    await act(async () => {
      answers[2]?.('model-not-ready');
    });
    await render(settings());
    expect(
      screen.queryByText(
        'Apple Intelligence is still getting ready. Try again later.',
      ),
    ).not.toBeOnTheScreen();
  });

  it.each(['malformed', 'rejected'])(
    'fails closed on a %s native availability result and can retry',
    async (outcome) => {
      expect.hasAssertions();
      const owner = 'synthetic-account';
      const enablement = createMailAssistanceEnablement({
        mailAssistance: () =>
          Promise.resolve({ owner, profiles: [defaultProfile] }),
        setMailAssistance: (account, profiles) =>
          Promise.resolve({ owner: account, profiles }),
      });
      await enablement.load(owner);
      const assistance = scriptedAssistance();
      const initial: Record<string, () => Promise<unknown>> = {
        malformed: () => Promise.resolve({ unexpected: 'available' }),
        rejected: () => Promise.reject(new Error('synthetic failure')),
      };
      const availability = jest.fn(initial[outcome]);
      const native: NativeAssistance = {
        ...assistance.native,
        availability,
      };
      const log = jest.spyOn(console, 'error').mockReturnValue(undefined);
      try {
        await render(
          <MailAssistanceContext value={enablement}>
            <MailAssistanceSettings
              account={owner}
              assistance={native}
              button={settingsButton}
            />
          </MailAssistanceContext>,
        );
        await press('Check Apple Intelligence availability');
        expect(
          screen.getByText(
            'Apple Intelligence availability could not be checked. Try again.',
          ),
        ).toBeVisible();
        availability.mockResolvedValue('available');
        await press('Check Apple Intelligence availability');
        expect(
          screen.getByText(
            'Apple Intelligence is available for summaries, rewrites and reply suggestions.',
          ),
        ).toBeVisible();
        expect(assistance.calls).toStrictEqual([]);
      } finally {
        log.mockRestore();
      }
    },
  );
});

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
        await store.addMailbox('gmail', false);
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
    expect(
      screen.queryByRole('button', {
        name: 'Check Apple Intelligence availability',
      }),
    ).not.toBeOnTheScreen();
    await press('Turn on on-device assistance');
    expect(screen.getByText('On-device assistance is on.')).toBeVisible();
    expect(assistance.calls).toStrictEqual([]);
    await press('Check Apple Intelligence availability');
    expect(
      screen.getByText(
        'Apple Intelligence is available for summaries, rewrites and reply suggestions.',
      ),
    ).toBeVisible();
    expect(assistance.calls).toStrictEqual(['availability']);
    assistance.calls.length = 0;
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
