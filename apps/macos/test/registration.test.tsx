import { createRegistration } from '@private-email/mail-core/registration';
import { createMockRegistrationSession } from '@private-email/mail-core/testing/registration-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';

import { RegistrationGate } from '../src/registration-gate.tsx';

describe('google registration', () => {
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
    expect(screen.getByText(/other@example.invalid/u)).toBeVisible();
  });

  it('offers interactive sign-in to recover a retained account after interruption', async () => {
    expect.hasAssertions();
    const session = createMockRegistrationSession('registration-success');
    await session.native.signIn();
    let authorizeGmail: (reselect: boolean) => Promise<unknown> = () =>
      Promise.reject(new Error('Synthetic identity needs sign-in'));
    const store = createRegistration({
      ...session.native,
      signIn: () => {
        ({ authorizeGmail } = session.native);
        return session.native.signIn();
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
});
