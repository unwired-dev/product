import { createRegistration } from '@private-email/mail-core/registration';
import {
  createMockRegistrationSession,
  createSyntheticAccount,
  syntheticEnrollmentCode,
  syntheticRecoveryKey,
} from '@private-email/mail-core/testing/registration-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { RegistrationGate } from '../src/registration-gate.tsx';

// Hosts without another device of the account never enroll or approve one.
const noEnrollment = {
  approveEnrollment: () => Promise.reject(new Error('No device to approve')),
  declineEnrollment: () => Promise.reject(new Error('No device to decline')),
  refreshPrivateSync: () => Promise.reject(new Error('No private sync')),
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

  /* oxlint-enable vitest/max-expects */

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
});
