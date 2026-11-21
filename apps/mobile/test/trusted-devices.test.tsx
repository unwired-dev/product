import { createMessageDateFormats, english } from '@private-email/localization';
import { createRegistration } from '@private-email/mail-core/registration';
import { createRegistrationScenario } from '@private-email/mail-core/testing/registration-scenarios';
import { fireEvent, render, screen } from '@testing-library/react-native';

import { Action } from '../src/action.tsx';
import { localization } from '../src/localization.ts';
import { TrustedDevices } from '../src/trusted-devices.tsx';

const settingsButton = (label: string, action: () => Promise<void>) => (
  <Action
    label={label}
    onPress={() => {
      void action();
    }}
  />
);

describe('trusted devices', () => {
  const now = new Date(2026, 10, 21, 9, 30).getTime();

  it('shows the device in hand, a device that reported its activity and one that has not, each read by VoiceOver as one element', async () => {
    expect.hasAssertions();
    jest.useFakeTimers({
      doNotFake: [
        'setTimeout',
        'clearTimeout',
        'setInterval',
        'clearInterval',
        'setImmediate',
        'clearImmediate',
        'queueMicrotask',
        'nextTick',
      ],
    });
    jest.setSystemTime(now);
    const synthetic = await createRegistrationScenario('registration-success');
    const store = createRegistration(synthetic.vault);
    await store.restore();
    const today = new Date(2026, 10, 21, 9, 12);
    const earlier = new Date(2026, 10, 13, 8, 0);
    const registeredAt = Date.UTC(2026, 8, 1);
    await render(
      <TrustedDevices
        account={{
          privateSync: 'ready',
          trustedDevices: JSON.stringify([
            {
              id: 'mac',
              name: 'Mara’s MacBook Pro',
              registeredAt,
              kind: 'mac',
              activeAt: today.getTime(),
            },
            {
              id: 'iphone',
              name: 'Mara’s iPhone',
              registeredAt,
              current: true,
              kind: 'iphone',
            },
            {
              id: 'ipad',
              name: 'iPad Air',
              registeredAt,
              kind: 'ipad',
              activeAt: earlier.getTime(),
            },
            { id: 'old', name: 'Old iPhone', registeredAt },
          ]),
        }}
        approves
        button={settingsButton}
        failure={undefined}
        store={store}
      />,
    );
    const { locale, timeZone } = localization.getSnapshot();
    const dates = createMessageDateFormats(locale, timeZone);
    const added = new Intl.DateTimeFormat(locale, {
      dateStyle: 'medium',
    }).format(registeredAt);
    expect(screen.getByText(english('revocation.footer'))).toBeVisible();
    for (const label of [
      `Mac, Mara’s MacBook Pro, ${english('revocation.lastActiveToday', {
        time: dates.time.format(today),
      })}`,
      `iPhone, Mara’s iPhone, Current Device, ${english('revocation.thisIphone')}`,
      `iPad, iPad Air, ${english('revocation.lastActive', {
        date: dates.header(english, earlier, now),
      })}`,
      `Old iPhone, ${english('revocation.added', { date: added })}`,
    ]) {
      expect(screen.getByLabelText(label)).toBeVisible();
    }
    // Only the other devices can be removed, by their button or the row's VoiceOver action.
    expect(
      screen.getByRole('button', { name: 'Remove Mara’s MacBook Pro' }),
    ).toBeVisible();
    expect(
      screen.queryByRole('button', { name: 'Remove Mara’s iPhone' }),
    ).toBeNull();
    expect(
      screen.getByLabelText(/^iPhone, Mara’s iPhone/u).props,
    ).not.toHaveProperty('accessibilityActions', expect.anything());
    await fireEvent(
      screen.getByLabelText(/^Mac, Mara’s MacBook Pro/u),
      'accessibilityAction',
      { nativeEvent: { actionName: 'activate' } },
    );
    expect(screen.getByTestId('device-removal-confirmation')).toBeOnTheScreen();
    jest.useRealTimers();
  });
});
