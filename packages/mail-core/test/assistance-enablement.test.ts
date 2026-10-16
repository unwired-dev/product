import type { NativeMailAssistance } from '../src/assistance-enablement.ts';

import {
  createMailAssistanceEnablement,
  mailAssistanceEnabled,
} from '../src/assistance-enablement.ts';
import { createRegistration, defaultProfile } from '../src/registration.ts';
import { createMockMailSession } from '../src/testing/mock-session.ts';
import { createRegistrationScenario } from '../src/testing/registration-scenarios.ts';

const account = 'account-synthetic-product-subject';

// A connected synthetic Product Account whose Recovery Key is confirmed, so it can sign out.
async function signedIn(
  scenario?: Awaited<ReturnType<typeof createRegistrationScenario>>,
) {
  const synthetic =
    scenario ?? (await createRegistrationScenario('registration-success'));
  const registration = createRegistration(synthetic.vault);
  await registration.register('google');
  await registration.addMailbox();
  const { snapshot } = registration.getSnapshot();
  const recoveryKey =
    'recoveryKey' in snapshot ? (snapshot.recoveryKey ?? '') : '';
  await registration.confirmRecoveryKey(recoveryKey.slice(-4));
  return { ...synthetic, registration, recoveryKey };
}

describe('mail Assistance Enablement', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one enablement lifecycle end to end. */
  it('defaults off per Product Account and Profile, persists, and is removed by sign-out', async () => {
    expect.hasAssertions();
    const session = await signedIn();
    const store = createMailAssistanceEnablement(session.mailAssistance);
    const enabled = (owner = account, profile = defaultProfile) =>
      mailAssistanceEnabled(store.getSnapshot(), owner, profile);
    // Nothing is enabled before this device's enablement is read, nor after it is read.
    expect(enabled()).toBe(false);
    await store.load('first');
    expect(store.getSnapshot()).toStrictEqual({ owner: account, profiles: [] });
    expect(enabled()).toBe(false);

    await store.setEnabled(account, defaultProfile, true);
    expect(enabled()).toBe(true);
    expect(enabled('another-product-account')).toBe(false);
    expect(enabled(account, 'another-profile')).toBe(false);
    // A relaunch reads it back from device storage.
    const relaunched = createMailAssistanceEnablement(session.mailAssistance);
    await relaunched.load('first');
    expect(
      mailAssistanceEnabled(relaunched.getSnapshot(), account, defaultProfile),
    ).toBe(true);

    // Turning it off applies before storage confirms it, so in-flight assistance ends at once.
    const off = store.setEnabled(account, defaultProfile, false);
    expect(enabled()).toBe(false);
    await off;
    await relaunched.setEnabled(account, defaultProfile, true);

    // Sign-out purges it; the same account signing in again starts with assistance off.
    await session.registration.signOut();
    await store.load('signed-out');
    expect(store.getSnapshot()).toStrictEqual({ owner: null, profiles: [] });
    await store.setEnabled(account, defaultProfile, true);
    expect(store.getSnapshot()).toStrictEqual({ owner: null, profiles: [] });
    // This installation signs in again as a new device, which the Recovery Key admits.
    await session.registration.register('google');
    await session.registration.recoverWithRecoveryKey(session.recoveryKey);
    const loading = store.load('again');
    expect(store.getSnapshot()).toBeUndefined();
    await loading;
    expect(store.getSnapshot()).toStrictEqual({ owner: account, profiles: [] });
    expect(enabled()).toBe(false);
  });

  it('keeps assistance off for a stale or unreadable read and a removed account', async () => {
    expect.hasAssertions();
    const session = await signedIn();
    const enable = createMailAssistanceEnablement(session.mailAssistance);
    await enable.load('first');
    await enable.setEnabled(account, defaultProfile, true);

    // A read that settles after the registration scope changed is never shown.
    const answers: Array<(value: unknown) => void> = [];
    const delayed: NativeMailAssistance = {
      ...session.mailAssistance,
      mailAssistance: () =>
        // oxlint-disable-next-line promise/avoid-new -- Hold each read across a scope change.
        new Promise((resolve) => {
          answers.push(resolve);
        }),
    };
    const store = createMailAssistanceEnablement(delayed);
    const stale = store.load('removing');
    const current = store.load('signed-out');
    answers[0]?.({ owner: account, profiles: [defaultProfile] });
    await stale;
    expect(store.getSnapshot()).toBeUndefined();
    await vi.waitFor(() => {
      expect(answers).toHaveLength(2);
    });
    answers[1]?.({ owner: null, profiles: [] });
    await current;
    expect(
      mailAssistanceEnabled(store.getSnapshot(), account, defaultProfile),
    ).toBe(false);

    // Malformed native results and failed reads fail closed.
    for (const reply of [
      Promise.resolve({ owner: account, profiles: 'default' }),
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' })),
    ]) {
      const failing = createMailAssistanceEnablement({
        ...session.mailAssistance,
        mailAssistance: () => reply,
      });
      await failing.load('first');
      expect(failing.getSnapshot()).toBeUndefined();
    }

    // Deleting the account removes its enablement from this device too.
    await session.registration.deleteProductAccount();
    await enable.load('deleted');
    expect(enable.getSnapshot()).toStrictEqual({ owner: null, profiles: [] });
  });

  it('lets Mock Mail Sessions select enabled and disabled outcomes', async () => {
    expect.hasAssertions();
    for (const [scenario, profiles] of [
      ['open-read-relaunch', [defaultProfile]],
      ['assistance-disabled', []],
    ] as const) {
      const session = createMockMailSession(scenario);
      const store = createMailAssistanceEnablement(session.mailAssistance);
      await store.load(scenario);
      expect(store.getSnapshot()).toStrictEqual({
        owner: 'mock-product-account',
        profiles,
      });
    }
  });

  it('rejects a read from an earlier admission of the same account', async () => {
    expect.hasAssertions();
    const answers: Array<(value: unknown) => void> = [];
    const store = createMailAssistanceEnablement({
      mailAssistance: () =>
        // oxlint-disable-next-line promise/avoid-new -- Hold reads across sign-out and re-entry.
        new Promise((resolve) => {
          answers.push(resolve);
        }),
      setMailAssistance: () => Promise.reject(new Error('unused')),
    });
    const first = store.load(account);
    const signedOut = store.load('signed-out');
    const reentered = store.load(account);
    answers[0]?.({ owner: account, profiles: [defaultProfile] });
    await first;
    expect(store.getSnapshot()).toBeUndefined();
    await vi.waitFor(() => {
      expect(answers).toHaveLength(2);
    });
    answers[1]?.({ owner: null, profiles: [] });
    await signedOut;
    await vi.waitFor(() => {
      expect(answers).toHaveLength(3);
    });
    answers[2]?.({ owner: account, profiles: [] });
    await reentered;
    expect(store.getSnapshot()).toStrictEqual({ owner: account, profiles: [] });
  });

  it('turns off immediately behind a pending save and rejects queued account changes', async () => {
    expect.hasAssertions();
    let owner = account;
    const answers: Array<() => void> = [];
    const written: string[] = [];
    const store = createMailAssistanceEnablement({
      mailAssistance: () =>
        Promise.resolve({ owner, profiles: [defaultProfile] }),
      setMailAssistance: (savedOwner, profiles) => {
        written.push(savedOwner);
        // oxlint-disable-next-line promise/avoid-new -- Hold a native save while Off and account changes arrive.
        return new Promise((resolve) => {
          answers.push(() => resolve({ owner: savedOwner, profiles }));
        });
      },
    });
    await store.load(account);
    const saving = store.setEnabled(account, defaultProfile, true);
    const off = store.setEnabled(account, defaultProfile, false);
    expect(
      mailAssistanceEnabled(store.getSnapshot(), account, defaultProfile),
    ).toBe(false);
    answers[0]?.();
    await saving;
    expect(
      mailAssistanceEnabled(store.getSnapshot(), account, defaultProfile),
    ).toBe(false);
    const queued = store.setEnabled(account, defaultProfile, true);
    owner = 'another-account';
    const changed = store.load(owner);
    answers[1]?.();
    await off;
    await queued;
    await changed;
    // A retained control for the earlier account cannot change the replacement account either.
    await store.setEnabled(account, defaultProfile, true);
    expect(written).toStrictEqual([account, account]);
  });

  it('discards failed-save status and retry ownership when the account changes', async () => {
    expect.hasAssertions();
    let owner = account;
    const failures: Array<(failure: unknown) => void> = [];
    const store = createMailAssistanceEnablement({
      mailAssistance: () =>
        Promise.resolve({ owner, profiles: [defaultProfile] }),
      setMailAssistance: () =>
        // oxlint-disable-next-line promise/avoid-new -- Reject a native save after replacement account load begins.
        new Promise((_resolve, reject) => {
          failures.push(reject);
        }),
    });
    await store.load(owner);
    const off = store.setEnabled(owner, defaultProfile, false);
    expect(store.getSaveState()).toBe('saving');
    owner = 'replacement-account';
    const replacement = store.load(owner);
    failures[0]?.({ code: 'locked' });
    await off;
    await replacement;
    expect(store.getSaveState()).toBe('idle');
    await store.retrySave(account);
    expect(store.getSnapshot()).toStrictEqual({
      owner,
      profiles: [defaultProfile],
    });
    const replacementOff = store.setEnabled(owner, defaultProfile, false);
    failures[1]?.({ code: 'locked' });
    await replacementOff;
    expect(store.getSaveState()).toBe('failed');
    await store.retrySave(account);
    expect(store.getSnapshot()).toStrictEqual({ owner, profiles: [] });
    expect(failures).toHaveLength(2);
  });
});
