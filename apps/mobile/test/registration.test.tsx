import { createRegistration } from '@private-email/mail-core/registration';
import {
  createMockRegistrationSession,
  syntheticRecoveryKey,
} from '@private-email/mail-core/testing/registration-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { RegistrationGate } from '../src/registration-gate.tsx';

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

  it('asks an existing Product Account to unlock this device without creating a Recovery Key', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-enrollment');
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
      screen.findByRole('header', {
        name: 'Unlock private data on this device',
      }),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('header', { name: 'Gmail connected' }),
    ).toBeVisible();
    expect(screen.queryByLabelText('Last four characters')).toBeNull();
    expect(screen.queryByText(/Encrypted mailbox list/u)).toBeNull();
  });
});
