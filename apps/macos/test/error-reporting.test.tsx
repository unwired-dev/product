import type {
  ErrorReporting,
  ErrorReportingSnapshot,
} from '@private-email/mail-core/error-reporting';

import { createRegistration } from '@private-email/mail-core/registration';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { Alert } from 'react-native';

import {
  ErrorReportingContext,
  ErrorReportingEntry,
  ErrorReportingSettings,
} from '../src/error-reporting.tsx';
import { RegistrationGate, SettingsGate } from '../src/registration-gate.tsx';
import { useSettingsRequest } from '../src/settings-window.ts';

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
  it('opens the native Settings window before sign-in and exposes the same reporting store', async () => {
    expect.hasAssertions();
    const synthetic = await createRegistrationScenario('registration-declined');
    const registration = createRegistration(synthetic.vault);
    await registration.restoreOnce();
    const { store } = reporting({
      kind: 'ready',
      enabled: false,
      deletion: 'idle',
    });
    const close = jest.fn();
    function Window() {
      const request = useSettingsRequest();
      return (
        <SettingsGate
          store={registration}
          errorReporting={store}
          microsoft={false}
          request={request}
          onInbox={() => undefined}
          onClose={close}
        />
      );
    }
    await render(
      <>
        <RegistrationGate
          store={registration}
          errorReporting={store}
          microsoft={false}
          preview={false}>
          {null}
        </RegistrationGate>
        <Window />
      </>,
    );
    close.mockClear();
    await fireEvent.press(
      await screen.findByRole('button', { name: 'Privacy & Data' }),
    );
    await expect(
      screen.findByText(/Available without signing in/u),
    ).resolves.toBeVisible();
    await fireEvent(screen.getByRole('switch'), 'valueChange', true);
    expect(store.setEnabled).toHaveBeenCalledWith(true);
    await fireEvent.press(
      screen.getByRole('button', { name: 'Back to Welcome' }),
    );
    expect(close).toHaveBeenCalledWith(expect.anything());
  });
});
