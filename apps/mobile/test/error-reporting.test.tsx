import assert from 'node:assert/strict';

import type {
  ErrorReporting,
  ErrorReportingSnapshot,
} from '@private-email/mail-core/error-reporting';

import { createRegistration } from '@private-email/mail-core/registration';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { useContext } from 'react';
import { Alert, Pressable, Text } from 'react-native';

import {
  ErrorReportingContext,
  ErrorReportingEntry,
  ErrorReportingSettings,
} from '../src/error-reporting.tsx';
import { AccountContext, RegistrationGate } from '../src/registration-gate.tsx';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- The test host supplies the native safe-area boundary.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));

function reporting(initial: ErrorReportingSnapshot) {
  let snapshot = initial;
  const listeners = new Set<() => void>();
  const update = (value: ErrorReportingSnapshot) => {
    snapshot = value;
    for (const listener of listeners) {
      listener();
    }
  };
  const store: ErrorReporting = {
    getSnapshot: () => snapshot,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    load: jest.fn(async () => undefined),
    refresh: jest.fn(async () => undefined),
    setEnabled: jest.fn(async (enabled) => {
      update({ kind: 'ready', enabled, deletion: 'idle' });
    }),
    deleteReports: jest.fn(async () => {
      update({ kind: 'deleting', phase: 'pending' });
    }),
    retryDeletion: jest.fn(async () => {
      update({ kind: 'ready', enabled: false, deletion: 'complete' });
    }),
    capture: jest.fn(),
    breadcrumb: jest.fn(),
    dispose: jest.fn(),
  };
  return { store, update };
}

describe('error reporting controls', () => {
  it('privacy entry follows reporting consent without showing an unknown state as off', async () => {
    expect.hasAssertions();
    const { store, update } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'idle',
    });
    await render(
      <ErrorReportingContext.Provider value={store}>
        <ErrorReportingEntry onPress={() => undefined} />
      </ErrorReportingContext.Provider>,
    );
    expect(screen.getByText('Off')).toBeVisible();
    await act(async () => {
      update({ kind: 'ready', enabled: true, deletion: 'idle' });
    });
    expect({
      visible: screen.getByText('On').props.children,
      accessible: screen.getByRole('button', { name: 'Error Reporting' }).props
        .accessibilityValue.text,
    }).toStrictEqual({ visible: 'On', accessible: 'On' });
    await act(async () => {
      update({ kind: 'deleting', phase: 'pending' });
    });
    expect(screen.getByText('Off')).toBeVisible();
    await act(async () => {
      update({ kind: 'loading' });
    });
    expect(screen.queryByText('Off')).toBeNull();
    await act(async () => {
      update({ kind: 'unavailable' });
    });
    expect(screen.queryByText('Off')).toBeNull();
  });

  it('explicit opt-in is available without signing in', async () => {
    expect.hasAssertions();
    const { store } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'idle',
    });
    await render(
      <ErrorReportingSettings
        store={store}
        signedOut
      />,
    );
    await expect(
      screen.findByText(/Available without signing in/u),
    ).resolves.toBeVisible();
    await fireEvent(
      screen.getByRole('switch', { name: 'Share error reports' }),
      'valueChange',
      true,
    );
    expect(
      screen.getByText(/After a reinstall or cleared app data/u),
    ).toBeVisible();
    expect(store.setEnabled).toHaveBeenCalledWith(true);
    expect(screen.getByRole('switch').props.value).toBe(true);
  });

  it('native deletion confirmation keeps reporting off until verified', async () => {
    expect.hasAssertions();
    const { store } = reporting({
      kind: 'ready',
      enabled: true,
      deletion: 'idle',
    });
    const alert = jest.spyOn(Alert, 'alert').mockReturnValue(undefined);
    await render(<ErrorReportingSettings store={store} />);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Delete my error reports' }),
    );
    expect(store.deleteReports).not.toHaveBeenCalled();
    const buttons = alert.mock.calls[0]?.[2];
    const confirm = buttons?.find((button) => button.style === 'destructive');
    expect(confirm?.text).toBe('Delete Reports');
    await act(async () => {
      confirm?.onPress?.();
    });
    expect({
      status: screen.getByText('Deletion requested').props.children,
      disabled: screen.getByRole('switch').props.disabled,
    }).toStrictEqual({ status: 'Deletion requested', disabled: true });
    await act(async () => {
      await fireEvent.press(
        screen.getByRole('button', { name: 'Check deletion status' }),
      );
    });
    expect({
      status: screen.getByText('Your error reports were deleted').props
        .children,
      enabled: screen.getByRole('switch').props.value,
      disabled: screen.getByRole('switch').props.disabled,
    }).toStrictEqual({
      status: 'Your error reports were deleted',
      enabled: false,
      disabled: false,
    });
    alert.mockRestore();
  });

  it.each([
    { phase: 'offline', action: 'Retry deletion' },
    { phase: 'failed', action: 'Retry' },
  ] as const)(
    'deletion %s retains off and offers retry',
    async ({ phase, action }) => {
      expect.hasAssertions();
      const { store } = reporting({ kind: 'deleting', phase });
      await render(<ErrorReportingSettings store={store} />);
      expect(screen.getByRole('switch').props.disabled).toBe(true);
      expect(screen.getByRole('switch').props).toMatchObject({ value: false });
      await act(async () => {
        await fireEvent.press(
          screen.getByRole('button', {
            name: action,
          }),
        );
      });
      expect(store.retryDeletion).toHaveBeenCalledWith();
    },
  );

  it('missing deletion access explains the limit and disables deletion', async () => {
    expect.hasAssertions();
    const { store } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'missing',
    });
    await render(<ErrorReportingSettings store={store} />);
    await expect(
      screen.findByText(/Signing in won’t restore access/u),
    ).resolves.toBeVisible();
    const deletion = screen.getByRole('button', {
      name: 'Delete my error reports',
    });
    expect(deletion.props.accessibilityState.disabled).toBe(true);
    await fireEvent.press(deletion);
    expect(store.deleteReports).not.toHaveBeenCalled();
    expect(screen.getByRole('switch').props).toMatchObject({ disabled: false });
  });
});

describe('installation privacy access', () => {
  it.each([
    {
      destination: 'Welcome',
      enter: async () => undefined,
      back: 'Continue',
    },
    {
      destination: 'Sign In',
      enter: () =>
        fireEvent.press(screen.getByRole('button', { name: 'Continue' })),
      back: 'Sign in with Google',
    },
  ])(
    'uses Back to return from signed-out privacy to the retained $destination page',
    async ({ enter, back }) => {
      expect.hasAssertions();
      const synthetic = await createRegistrationScenario('registration-declined');
      const registration = createRegistration(synthetic.vault);
      await registration.restoreOnce();
      const { store } = reporting({
        kind: 'ready',
        enabled: false,
        deletion: 'idle',
      });
      await render(
        <RegistrationGate
          store={registration}
          errorReporting={store}
          microsoft={false}
          preview={false}>
          {null}
        </RegistrationGate>,
      );
      await enter();
      await fireEvent.press(
        await screen.findByRole('button', { name: 'Privacy & Data' }),
      );
      await expect(
        screen.findByText(/Available without signing in/u),
      ).resolves.toBeVisible();
      expect(screen.getByTestId('reporting-privacy-screen')).toBeVisible();
      expect(
        screen
          .getAllByRole('header', {
            name: /^(?:Privacy & Data|Error Reporting)$/u,
          })
          .map((header) => header.props.children),
      ).toStrictEqual(['Privacy & Data', 'Error Reporting']);
      expect(
        screen.queryByRole('button', { name: 'Sign in with Google' }),
      ).toBeNull();
      await fireEvent.press(screen.getByRole('button', { name: 'Back' }));
      await expect(
        screen.findByRole('button', { name: back }),
      ).resolves.toBeVisible();
    },
  );
});

function OpenPrivacy() {
  const account = useContext(AccountContext);
  assert.ok(account);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel="Open device privacy"
      onPress={() => {
        account.openAccount('privacy');
      }}>
      <Text>Open device privacy</Text>
    </Pressable>
  );
}

async function connectedRegistration() {
  const synthetic = await createRegistrationScenario('registration-success');
  const registration = createRegistration(synthetic.vault);
  await registration.register('google');
  await registration.addMailbox();
  const saved = registration.getSnapshot().snapshot;
  assert.ok(saved.kind !== 'signed-out' && saved.recoveryKey !== undefined);
  await registration.confirmRecoveryKey(
    saved.recoveryKey.replaceAll('-', '').slice(-4),
  );
  return registration;
}

describe('reporting settings navigation', () => {
  it('pushes reporting from Privacy & Data and returns to the retained privacy page', async () => {
    expect.hasAssertions();
    const registration = await connectedRegistration();
    const { store } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'idle',
    });
    await render(
      <RegistrationGate
        store={registration}
        errorReporting={store}
        microsoft={false}
        preview={false}>
        <OpenPrivacy />
      </RegistrationGate>,
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Open device privacy' }),
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Error Reporting' }),
    );
    await expect(
      screen.findByTestId('error-reporting-detail'),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('switch', { name: 'Share error reports' }).props,
    ).toMatchObject({ value: false });
    await fireEvent.press(
      screen.getByRole('button', { name: 'Back to Settings' }),
    );
    await expect(
      screen.findByRole('button', { name: 'Error Reporting' }),
    ).resolves.toBeVisible();
    expect(
      screen.queryByRole('switch', { name: 'Share error reports' }),
    ).toBeNull();
  });
});

describe('privacy after account removal', () => {
  it('retains installation reporting controls from the account-deleted sign-in page', async () => {
    expect.hasAssertions();
    const registration = await connectedRegistration();
    await registration.deleteProductAccount();
    const { store } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'idle',
    });
    await render(
      <RegistrationGate
        store={registration}
        errorReporting={store}
        microsoft={false}
        preview={false}>
        {null}
      </RegistrationGate>,
    );
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Privacy & Data' }),
    );
    await expect(
      screen.findByText(
        /Available without signing in or after account removal/u,
      ),
    ).resolves.toBeVisible();
    expect(
      screen.getByRole('switch', { name: 'Share error reports' }).props,
    ).toMatchObject({ value: false, disabled: false });
    expect(
      screen.getByRole('button', { name: 'Delete my error reports' }).props
        .accessibilityState,
    ).toMatchObject({ disabled: false });
  });
});
