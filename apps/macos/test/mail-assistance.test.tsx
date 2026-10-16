import type { NativeAssistance } from '@private-email/mail-core/assistance';
import type { NativeTranslation } from '@private-email/mail-core/translation';

import { createMailAssistanceEnablement } from '@private-email/mail-core/assistance-enablement';
import { singleMailbox } from '@private-email/mail-core/mailboxes';
import { createPersistentInbox } from '@private-email/mail-core/persistent-inbox';
import {
  createRegistration,
  defaultProfile,
} from '@private-email/mail-core/registration';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { makeMockInboxStorage } from '@private-email/mail-core/testing/mock-storage';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { Profiler, use } from 'react';

import { Action } from '../src/action.tsx';
import {
  MailAssistanceContext,
  MailAssistanceGate,
  MailAssistanceSettings,
} from '../src/mail-assistance.tsx';
import { InboxProvider, ProfileScope } from '../src/mailbox.tsx';
import { MessageDetail } from '../src/message-detail.tsx';
import { MessageSummary } from '../src/message-summary.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';
import { DraftTranslation, MessageTranslation } from '../src/translation.tsx';
import { started } from './started.ts';

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

// Turns this device's Mail Assistance switch on or off.
const assist = async (on: boolean) => {
  await act(async () => {
    await fireEvent(
      screen.getByRole('switch', { name: 'Mail Assistance' }),
      'valueChange',
      on,
    );
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
      const synthetic = await createRegistrationScenario(
        'registration-success',
      );
      const registration = createRegistration(synthetic.vault);
      await registration.register('google');
      const enablement = createMailAssistanceEnablement(
        synthetic.mailAssistance,
      );
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
            account="account-synthetic-product-subject"
            assistance={native}
            button={settingsButton}
          />
        </MailAssistanceContext>,
      );
      await assist(true);
      expect(assistance.calls).toStrictEqual([]);
      await press('Check Apple Intelligence availability');
      expect(screen.getByText(copy)).toBeVisible();
      expect(assistance.calls).toStrictEqual(['availability']);
    },
  );

  /* oxlint-disable vitest/max-expects -- One reader journey protects consent, revocation and Profile replacement. */
  it('uses the reader’s Profile consent and cancels when that consent is revoked', async () => {
    expect.hasAssertions();
    const owner = 'synthetic-product-account';
    const enablement = createMailAssistanceEnablement({
      mailAssistance: () =>
        Promise.resolve({ owner, profiles: [defaultProfile] }),
      setMailAssistance: (account, profiles) =>
        Promise.resolve({ owner: account, profiles }),
    });
    await enablement.load(owner);
    const assistance = scriptedAssistance();
    const session = createMockMailSession('open-read-relaunch');
    const fixture = createPersistentInbox(
      makeMockInboxStorage(),
      session.mail.list,
    );
    await fixture.load();
    const original = singleMailbox(fixture, 'work-mailbox');
    const snapshot = original
      .getSnapshot()
      .map((mailbox) => ({ ...mailbox, profile: 'work' }));
    const mailboxes = { ...original, getSnapshot: () => snapshot };
    const { translation } = session;
    const view = (profile: string) => (
      <MailAssistanceContext value={enablement}>
        <MailAssistanceGate
          account={owner}
          assistance={assistance.native}
          translation={translation}>
          <ProfileScope profile={profile}>
            <InboxProvider mailboxes={mailboxes}>
              <MessageDetail
                mailbox="work-mailbox"
                id="weekend-walk"
              />
            </InboxProvider>
          </ProfileScope>
        </MailAssistanceGate>
      </MailAssistanceContext>
    );
    const app = await render(view('work'));
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).toBeNull();
    await act(async () => {
      await enablement.setEnabled(owner, 'work', true);
      await enablement.setEnabled(owner, defaultProfile, false);
    });
    await press('Summarize this message');
    await act(async () => {
      await enablement.setEnabled(owner, 'work', false);
    });
    expect(assistance.cancelled).toHaveLength(1);
    await act(() => assistance.answers[0]?.('Retired Work preview'));
    expect(screen.queryByText('Retired Work preview')).toBeNull();
    await act(async () => {
      await enablement.setEnabled(owner, 'work', true);
      await enablement.setEnabled(owner, defaultProfile, true);
    });
    await press('Summarize this message');
    await app.rerender(view(defaultProfile));
    expect(assistance.cancelled).toHaveLength(2);
    await act(() => assistance.answers[1]?.('Retired Profile preview'));
    expect(screen.queryByText('Retired Profile preview')).toBeNull();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).toBeNull();
  });

  /* oxlint-enable vitest/max-expects */

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
    await assist(false);
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
    await assist(true);
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

describe('mail Assistance Enablement on Mac', () => {
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
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    const enablement = createMailAssistanceEnablement(synthetic.mailAssistance);
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
    await render(
      <RegistrationGate
        store={started(store)}
        preview={false}
        mailAssistance={enablement}
        assistance={assistance.native}
        translation={translation}>
        <Reader />
      </RegistrationGate>,
    );
    let recoveryKey = '';
    await act(async () => {
      await store.register('google');
      await store.addMailbox('gmail', false);
      recoveryKey = String(synthetic.device.productSync.vault?.recoveryKey);
      await store.confirmRecoveryKey(recoveryKey.slice(-4));
    });

    // Off by default: no assistance action is offered and nothing reaches either framework.
    expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).not.toBeOnTheScreen();
    expect(
      screen.queryByRole('button', { name: 'Translate this message' }),
    ).not.toBeOnTheScreen();

    // Turning it on from the account page's Privacy & Data starts nothing.
    await press('Account');
    await press('Privacy & Data');
    expect(screen.getByText('On-device assistance is off.')).toBeVisible();
    expect(
      screen.queryByRole('button', {
        name: 'Check Apple Intelligence availability',
      }),
    ).not.toBeOnTheScreen();
    await assist(true);
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
        'account-synthetic-product-subject',
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
        'account-synthetic-product-subject',
        defaultProfile,
        true,
      );
    });

    await press('Summarize this message');
    expect(assistance.calls).toStrictEqual(['availability', 'summarize']);
    expect(screen.getByText('Summarizing on this device…')).toBeVisible();
    await act(async () => {
      await enablement.setEnabled(
        'account-synthetic-product-subject',
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
        'account-synthetic-product-subject',
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
    // This installation signs in again as a new device, which the Recovery Key admits.
    await act(async () => {
      await store.register('google');
      await store.recoverWithRecoveryKey(recoveryKey);
      await store.addMailbox('gmail', false);
    });
    expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Summarize this message' }),
    ).not.toBeOnTheScreen();
    await press('Account');
    await press('Privacy & Data');
    expect(screen.getByText('On-device assistance is off.')).toBeVisible();
  });
});
