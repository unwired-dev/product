import {
  accountRemovalCopy,
  createRegistration,
  revocationCopy,
} from '@private-email/mail-core/registration';
import {
  createMockRegistrationSession,
  createSyntheticAccount,
  syntheticEnrollmentCode,
  syntheticRecoveryKey,
  syntheticReplacementRecoveryKey,
  syntheticTrustedDevice,
} from '@private-email/mail-core/testing/registration-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { AppState } from 'react-native';

import { RegistrationGate } from '../src/registration-gate.tsx';

// Hosts without another device of the account never enroll, approve or recover one.
const noEnrollment = {
  recoverWithRecoveryKey: () =>
    Promise.reject(new Error('No device to recover')),
  approveEnrollment: () => Promise.reject(new Error('No device to approve')),
  declineEnrollment: () => Promise.reject(new Error('No device to decline')),
  revokeTrustedDevice: () => Promise.reject(new Error('No device to remove')),
  refreshPrivateSync: () => Promise.reject(new Error('No private sync')),
  signOut: () => Promise.reject(new Error('Not signing out')),
  deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
};

describe('product registration', () => {
  it('retains setup after declined consent and connects a reselected Gmail account after remount', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-declined');
    const first = await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Gmail connected' }),
    ).toBeNull();
    await first.unmount();
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Choose another Google mailbox',
        }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('other@example.invalid is connected on this device.'),
    ).toBeVisible();
  });

  it('offers interactive sign-in to recover a retained account after interruption', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await session.native.signIn('google');
    let authorizeGmail: (reselect: boolean) => Promise<unknown> = () =>
      Promise.reject(new Error('Synthetic identity needs sign-in'));
    const store = createRegistration({
      ...session.native,
      signIn: (provider) => {
        ({ authorizeGmail } = session.native);
        return session.native.signIn(provider);
      },
      authorizeGmail: (reselect) => authorizeGmail(reselect),
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Authorize Gmail' }),
      );
    });
    expect(store.getSnapshot().snapshot).toStrictEqual({
      kind: 'mailbox-needed',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'recovery-key',
      recoveryKey: syntheticRecoveryKey,
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Sign in again with Google',
        }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    expect(store.getSnapshot().snapshot).toMatchObject({
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
    });
  });

  it('continues Apple sign-in into separate Gmail authorization and keeps the relay address as contact information', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-declined');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(/Signing in with Apple does not give access to mail/u),
    ).toBeVisible();
    expect(
      screen.getByText(
        'Signed in with Apple. Contact email: relay@privaterelay.example.invalid.',
      ),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Choose another Google mailbox',
        }),
      );
    });
    // The connected mailbox comes from the Gmail grant, never the Apple address.
    await expect(
      screen.findByText('other@example.invalid is connected on this device.'),
    ).resolves.toBeVisible();
  });

  it('links Google from account settings and keeps both sign-in methods after remount', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-link');
    const first = await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Apple' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    // The Gmail grant is a Mailbox Connection, not a Linked Sign-In.
    expect(
      screen.getByText(/Only Apple opens this Product Account/u),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Link Google sign-in' }),
      );
    });
    const linked = 'Sign in with Apple or Google to open this Product Account.';
    await expect(screen.findByText(linked)).resolves.toBeVisible();
    await first.unmount();
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(screen.findByText(linked)).resolves.toBeVisible();
    expect(
      screen.queryByRole('button', { name: /^Link .* sign-in$/u }),
    ).toBeNull();
  });

  it('explains that an Apple identity owned by another Product Account is not linked', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const store = createRegistration(session.native);
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(
      screen.getByText(/First verify Google, then sign in with Apple\./u),
    ).toBeVisible();
    const before = store.getSnapshot().snapshot;
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Link Apple sign-in' }),
      );
    });
    await expect(
      screen.findByRole('alert', {
        name: /That Apple sign-in already belongs to another Product Account/u,
      }),
    ).resolves.toBeVisible();
    expect(store.getSnapshot().snapshot).toStrictEqual(before);
  });

  it('recovers an unverifiable Apple account through a Google link made on another device without new Gmail consent', async () => {
    expect.hasAssertions();
    const account = {
      productAccountId: 'synthetic-apple-product-account',
      signInProvider: 'apple',
    } as const;
    const store = createRegistration({
      // This device's saved receipt predates the link.
      restore: () =>
        Promise.resolve({
          kind: 'mailbox-needed',
          ...account,
          reason: 'unavailable',
        }),
      signIn: (provider) =>
        Promise.resolve({
          kind: 'connected',
          ...account,
          signInProvider: provider,
          alternateSignIn: 'apple',
          providerSubject: 'synthetic-google-subject',
          address: 'alex@example.invalid',
        }),
      authorizeGmail: () =>
        Promise.reject(new Error('Gmail consent must not restart')),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () =>
        Promise.reject(new Error('No Recovery Key to confirm')),
      ...noEnrollment,
    });
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', {
          name: 'Sign in with Google instead',
        }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(store.getSnapshot().snapshot).toMatchObject({
      ...account,
      signInProvider: 'google',
    });
  });

  it('presents the Recovery Key until its final group is confirmed, then shows the encrypted mailbox list', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    const first = await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    const entry = screen.getByLabelText('Last four characters');
    await act(async () => {
      await fireEvent.changeText(entry, '0000');
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    expect(screen.getByRole('alert')).toHaveTextContent(
      /does not match the end of your Recovery Key/u,
    );
    // Remounting still presents the same key; no replacement is generated.
    await first.unmount();
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(
      screen.findByText(syntheticRecoveryKey),
    ).resolves.toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        // Separators and case are ignored, as in native confirmation.
        [...syntheticRecoveryKey.slice(-4).toLowerCase()].join(' '),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves both devices' sides of an approval. */
  it('unlocks a new device only after a trusted device approves the code it shows', async () => {
    expect.hasAssertions();
    const account = createSyntheticAccount();
    const trusted = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    const added = createRegistration(
      createMockRegistrationSession('registration-enrollment', account).native,
    );
    const show = (store: typeof trusted) =>
      render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    // The first device creates the account keys and synchronizes its mailbox.
    let view = await show(trusted);
    await press('Sign in with Google');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // Signing in on another device reaches the account but none of its private data.
    view = await show(added);
    await press('Sign in with Google');
    await expect(
      screen.findByRole('header', { name: 'Approve this device' }),
    ).resolves.toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toHaveTextContent(
      syntheticEnrollmentCode,
    );
    expect(screen.queryByText(/Encrypted mailbox list/u)).toBeNull();
    expect(screen.queryByLabelText('Last four characters')).toBeNull();
    await view.unmount();

    // The trusted device approves only with that code; a mistyped one changes nothing.
    view = await show(trusted);
    await press('Check for a new device');
    await expect(
      screen.findByRole('header', { name: 'Approve a new device' }),
    ).resolves.toBeVisible();
    expect(screen.getByText(/Your iPad asked to unlock/u)).toBeVisible();
    const entry = screen.getByLabelText('Code from the new device');
    await act(async () => {
      await fireEvent.changeText(entry, 'H4KP-9QWE-3TRM-7XB3');
    });
    await press('Approve device');
    expect(screen.getByRole('alert')).toHaveTextContent(/code is not valid/u);
    await act(async () => {
      await fireEvent.changeText(
        entry,
        syntheticEnrollmentCode.toLowerCase().replaceAll('-', ' '),
      );
    });
    await press('Approve device');
    expect(
      screen.queryByRole('header', { name: 'Approve a new device' }),
    ).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    await view.unmount();

    // The approved device reads the synchronized mailbox list; Gmail still needs its own grant.
    await show(added);
    await press('Check for approval');
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('Encrypted mailbox list: alex@example.invalid.'),
    ).toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
    expect(
      screen.getByRole('header', { name: 'Connect your Gmail' }),
    ).toBeVisible();
    expect(
      screen.getByRole('button', { name: 'Authorize Gmail' }),
    ).toBeVisible();
  });

  it('unlocks a new device with the Recovery Key after a wrong key changes nothing, and offers no reset', async () => {
    expect.hasAssertions();
    const account = createSyntheticAccount();
    const lost = createRegistration(
      createMockRegistrationSession('registration-success', account).native,
    );
    const added = createRegistration(
      createMockRegistrationSession('registration-enrollment', account).native,
    );
    const show = (store: typeof lost) =>
      render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    // The device that created the account keys and saved a mailbox is later lost.
    let view = await show(lost);
    await press('Sign in with Google');
    await expect(
      screen.findByText('Encrypted mailbox list: alex@example.invalid.'),
    ).resolves.toBeVisible();
    await view.unmount();

    // A new device offers the Recovery Key beside approval, and explains that losing both
    // leaves the encrypted data locked; nothing offers to reset it.
    view = await show(added);
    await press('Sign in with Google');
    await expect(
      screen.findByRole('header', { name: 'Use your Recovery Key' }),
    ).resolves.toBeVisible();
    expect(screen.getByTestId('enrollment-code')).toBeVisible();
    expect(
      screen.getByText(/encrypted product data cannot be recovered/u),
    ).toBeVisible();
    expect(screen.queryByRole('button', { name: /reset/iu })).toBeNull();
    const entry = screen.getByLabelText('Recovery Key');
    await act(async () => {
      await fireEvent.changeText(entry, syntheticEnrollmentCode);
    });
    await press('Unlock with Recovery Key');
    expect(screen.getByRole('alert')).toHaveTextContent(
      /does not unlock this Product Account/u,
    );
    expect(
      screen.getByRole('header', { name: 'Approve this device' }),
    ).toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        entry,
        syntheticRecoveryKey.toLowerCase().replaceAll('-', ' '),
      );
    });
    await press('Unlock with Recovery Key');

    // The device reads the synchronized mailbox list; Gmail still needs its own grant.
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText('Encrypted mailbox list: alex@example.invalid.'),
    ).toBeVisible();
    expect(screen.queryByTestId('enrollment-code')).toBeNull();
    expect(screen.queryByLabelText('Recovery Key')).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
    expect(
      screen.getByRole('button', { name: 'Authorize Gmail' }),
    ).toBeVisible();
    await view.unmount();
    await show(added);
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */

  it('replaces a request that is no longer available and clears the code typed for it', async () => {
    expect.hasAssertions();
    const trusted = {
      kind: 'connected',
      productAccountId: 'synthetic-product-account',
      signInProvider: 'google',
      privateSync: 'ready',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
    } as const;
    let refreshes = 0;
    const store = createRegistration({
      restore: () => Promise.resolve(trusted),
      signIn: () => Promise.reject(new Error('Not signing in')),
      authorizeGmail: () => Promise.reject(new Error('Not authorizing')),
      link: () => Promise.reject(new Error('Not linking')),
      confirmRecoveryKey: () =>
        Promise.reject(new Error('No Recovery Key to confirm')),
      recoverWithRecoveryKey: () =>
        Promise.reject(new Error('No device to recover')),
      // The first request was handled by another trusted device meanwhile.
      approveEnrollment: () =>
        Promise.reject(
          Object.assign(new Error('Request unavailable'), {
            code: 'enrollment-unavailable',
          }),
        ),
      declineEnrollment: () => Promise.reject(new Error('Not declining')),
      revokeTrustedDevice: () => Promise.reject(new Error('Not removing')),
      signOut: () => Promise.reject(new Error('Not signing out')),
      deleteProductAccount: () => Promise.reject(new Error('Not deleting')),
      refreshPrivateSync: () =>
        Promise.resolve({
          ...trusted,
          enrollmentRequest: `synthetic-request-${(refreshes += 1)}`,
          enrollmentDevice: 'iPad',
        }),
    });
    await store.restoreOnce();
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    const press = async (name: string) => {
      await act(async () => {
        await fireEvent.press(await screen.findByRole('button', { name }));
      });
    };
    await press('Check for a new device');
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Code from the new device'),
        syntheticEnrollmentCode,
      );
    });
    await press('Approve device');
    expect(screen.getByRole('alert')).toHaveTextContent(/no longer available/u);
    await press('Check for a new device');
    expect(screen.getByLabelText('Code from the new device')).toHaveProp(
      'value',
      '',
    );
  });

  it('shows a locked state instead of onboarding after a locked launch and restores the account once active', async () => {
    expect.hasAssertions();
    const listenersBeforeRender = jest.mocked(AppState.addEventListener).mock
      .calls.length;
    const session = createMockRegistrationSession('registration-success');
    await session.native.signIn('google');
    await session.native.authorizeGmail(false);
    let restore = (): Promise<unknown> =>
      Promise.reject(Object.assign(new Error('locked'), { code: 'locked' }));
    await render(
      <RegistrationGate
        store={createRegistration({
          ...session.native,
          restore: () => restore(),
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(
      screen.findByRole('header', { name: 'Unlock your device' }),
    ).resolves.toBeVisible();
    expect([
      screen.queryByText('Welcome to Unwired Mail'),
      screen.queryByRole('button'),
      screen.queryByRole('alert'),
    ]).toStrictEqual([null, null, null]);
    ({ restore } = session.native);
    // The React Native Jest preset records AppState listeners on its mock.
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Gmail connected' }),
    ).resolves.toBeVisible();
    restore = () =>
      Promise.resolve({
        kind: 'mailbox-needed',
        productAccountId: 'synthetic-product-account',
        signInProvider: 'google',
        reason: 'unavailable',
      });
    await act(async () => {
      for (const [, activate] of jest
        .mocked(AppState.addEventListener)
        .mock.calls.slice(listenersBeforeRender)) {
        activate('active');
      }
      await Promise.resolve();
    });
    await expect(
      screen.findByRole('header', { name: 'Connect your Gmail' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('header', { name: 'Gmail connected' }),
    ).toBeNull();
  });

  it('offers sign-in again when the connected mailbox is not yet saved to private sync', async () => {
    expect.hasAssertions();
    const connected = {
      kind: 'connected',
      productAccountId: 'synthetic-apple-product-account',
      signInProvider: 'apple',
      privateSync: 'ready',
      privateSyncPending: 'mailbox',
      providerSubject: 'synthetic-google-subject',
      address: 'alex@example.invalid',
    } as const;
    const { privateSyncPending: _pending, ...saved } = connected;
    await render(
      <RegistrationGate
        store={createRegistration({
          restore: () => Promise.resolve(connected),
          // Signing in again with Apple saves the descriptor and keeps the mailbox.
          signIn: () => Promise.resolve(saved),
          authorizeGmail: () =>
            Promise.reject(new Error('Gmail consent must not restart')),
          link: () => Promise.reject(new Error('Not linking')),
          confirmRecoveryKey: () =>
            Promise.reject(new Error('No Recovery Key to confirm')),
          ...noEnrollment,
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await expect(
      screen.findByText(/not saved to private sync yet/u),
    ).resolves.toBeVisible();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Sign in again with Apple' }),
      );
    });
    expect(screen.queryByText(/not saved to private sync yet/u)).toBeNull();
    expect(screen.queryByRole('alert')).toBeNull();
  });

  /* oxlint-disable vitest/max-expects -- One journey proves the explanation, cancellation and removal. */
  it('removes another trusted device only after confirmation and shows the replacement Recovery Key', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-revocation');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(screen.queryByRole('button', { name: 'Remove iPad' })).toBeNull();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: revocationCopy.title }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(
        revocationCopy.added(syntheticTrustedDevice.registeredAt),
      ),
    ).toBeVisible();
    const remove = revocationCopy.remove(syntheticTrustedDevice.name);
    // The first press only explains what removal does and cannot do.
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: remove }));
    });
    const confirmation = revocationCopy.confirm(syntheticTrustedDevice.name);
    expect(screen.getByText(confirmation)).toBeVisible();
    expect(screen.getByText(confirmation)).toHaveTextContent(
      /cannot be erased remotely/u,
    );
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: revocationCopy.cancel }),
      );
    });
    expect(screen.queryByText(confirmation)).toBeNull();
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: remove }));
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', { name: remove }));
    });
    await expect(
      screen.findByText(revocationCopy.removed),
    ).resolves.toBeVisible();
    expect(screen.queryByText(syntheticTrustedDevice.name)).toBeNull();
    // The rotated keys come with a new Recovery Key, confirmed like the first one.
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
    expect(screen.getByText(syntheticReplacementRecoveryKey)).toBeVisible();
    expect(screen.getByLabelText('Last four characters')).toHaveProp(
      'value',
      '',
    );
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        syntheticReplacementRecoveryKey.slice(-4),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: 'Private sync is on' }),
    ).resolves.toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */

  it('explains on the next activation that this device was removed and its account data deleted', async () => {
    expect.hasAssertions();
    const store = createRegistration(
      createMockRegistrationSession('registration-revoked').native,
    );
    await render(
      <RegistrationGate
        store={store}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByText('Signed in with Google.'),
    ).resolves.toBeVisible();
    await act(async () => {
      await store.resume();
    });
    await expect(
      screen.findByRole('header', { name: 'This device was removed' }),
    ).resolves.toBeVisible();
    expect(screen.getByText(/cannot be erased remotely/u)).toBeVisible();
    expect(screen.queryByText('Signed in with Google.')).toBeNull();
    expect(
      screen.getByRole('button', { name: 'Sign in with Google' }),
    ).toBeVisible();
  });

  /* oxlint-disable vitest/max-expects -- Each journey proves the explanation, cancellation and outcome. */
  it('signs this device out only after confirmation and keeps nothing of the account', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await render(
      <RegistrationGate
        store={createRegistration(session.native)}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await expect(
      screen.findByRole('header', { name: accountRemovalCopy.title }),
    ).resolves.toBeVisible();
    await act(async () => {
      await fireEvent.changeText(
        screen.getByLabelText('Last four characters'),
        syntheticRecoveryKey.slice(-4),
      );
    });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Confirm Recovery Key' }),
      );
    });
    const signOut = { name: accountRemovalCopy.signOut };
    // The first press explains what sign-out removes; cancelling keeps the account.
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    expect(screen.getByText(accountRemovalCopy.signOutConfirm)).toBeVisible();
    expect(
      screen.queryByRole('button', { name: accountRemovalCopy.delete }),
    ).toBeNull();
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: accountRemovalCopy.cancel }),
      );
    });
    expect(screen.queryByText(accountRemovalCopy.signOutConfirm)).toBeNull();
    expect(screen.getByText('Signed in with Google.')).toBeVisible();
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', signOut));
    });
    await expect(
      screen.findByRole('header', { name: 'Welcome to Unwired Mail' }),
    ).resolves.toBeVisible();
    expect(screen.queryByText('Signed in with Google.')).toBeNull();
    expect(screen.queryByText(syntheticRecoveryKey)).toBeNull();
  });

  it.each([
    {
      removalPending: 'sign-out' as const,
      title: 'Finish signing out',
      action: accountRemovalCopy.signOut,
      result: 'Welcome to Unwired Mail',
    },
    {
      removalPending: 'deletion' as const,
      title: 'Confirm account deletion',
      action: accountRemovalCopy.deletePermanently,
      result: 'Product Account deleted',
    },
  ])(
    'resumes a pending $removalPending after relaunch without offering mailbox or sign-in work',
    async ({ removalPending, title, action, result }) => {
      expect.hasAssertions();
      const session = createMockRegistrationSession('registration-success');
      const store = createRegistration({
        ...session.native,
        restore: () =>
          Promise.resolve({
            kind: 'mailbox-needed',
            productAccountId: 'synthetic-product-account',
            signInProvider: 'google',
            privateSync: 'unavailable',
            reason: 'unavailable',
            removalPending,
          }),
        signOut: () => Promise.resolve({ kind: 'signed-out' }),
        deleteProductAccount: () =>
          Promise.resolve({ kind: 'signed-out', notice: 'deleted' }),
      });
      await render(
        <RegistrationGate
          store={store}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await expect(
        screen.findByRole('header', {
          name: title,
        }),
      ).resolves.toBeVisible();
      expect(
        screen.queryByRole('button', { name: 'Authorize Gmail' }),
      ).toBeNull();
      expect(
        screen.queryByRole('button', { name: 'Sign in again with Google' }),
      ).toBeNull();
      expect(
        screen.queryByRole('button', { name: accountRemovalCopy.cancel }),
      ).toBeNull();
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: action,
          }),
        );
      });
      await expect(
        screen.findByRole('header', {
          name: result,
        }),
      ).resolves.toBeVisible();
    },
  );

  it('deletes the Product Account only after explicit confirmation, keeping it when deletion fails', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    let deletion: () => Promise<unknown> = () =>
      Promise.reject(new Error('Synthetic deletion offline'));
    await render(
      <RegistrationGate
        store={createRegistration({
          ...session.native,
          deleteProductAccount: () => deletion(),
        })}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Sign in with Google' }),
      );
    });
    await act(async () => {
      await fireEvent.press(
        await screen.findByRole('button', { name: accountRemovalCopy.delete }),
      );
    });
    expect(screen.getByText(accountRemovalCopy.deleteConfirm)).toBeVisible();
    const permanently = { name: accountRemovalCopy.deletePermanently };
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', permanently));
    });
    await expect(
      screen.findByRole('alert', { name: accountRemovalCopy.deletion }),
    ).resolves.toBeVisible();
    expect(screen.getByText('Signed in with Google.')).toBeVisible();
    deletion = session.native.deleteProductAccount;
    await act(async () => {
      await fireEvent.press(screen.getByRole('button', permanently));
    });
    await expect(
      screen.findByRole('header', { name: 'Product Account deleted' }),
    ).resolves.toBeVisible();
    expect(
      screen.getByText(/Your mail in Gmail is not affected/u),
    ).toBeVisible();
    // A deleted account cannot be reopened.
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Sign in with Google' }),
      );
    });
    expect(
      screen.getByRole('header', { name: 'Product Account deleted' }),
    ).toBeVisible();
  });

  /* oxlint-enable vitest/max-expects */
});
