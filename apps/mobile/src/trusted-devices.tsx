import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RegistrationSnapshot,
  RevocationFailure,
  TrustedDevice,
} from '@private-email/mail-core/registration';

import {
  Alert,
  Button,
  Host,
  Spacer,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import { frame } from '@expo/ui/swift-ui/modifiers';
import {
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Text, TextInput } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { AnnouncedAlert } from './design.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization, useMessageDateFormats } from './localization.ts';
import { useNow } from './mailbox-state.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

// The system alert owns presentation, focus and Escape; Cancel's role makes it the dismissal choice.
function DeviceConfirmation({
  name,
  onCancel,
  onConfirm,
}: {
  readonly name: string;
  readonly onCancel: () => void;
  readonly onConfirm: () => void;
}) {
  const { t } = useLocalization();
  return (
    <Host matchContents>
      <Alert
        testID="device-removal-confirmation"
        title={t('revocation.confirmTitle', { name })}
        isPresented>
        {/* SwiftUI drops an alert attached to an empty view, so it anchors on a zero-size spacer. */}
        <Alert.Trigger>
          <Spacer modifiers={[frame({ width: 0, height: 0 })]} />
        </Alert.Trigger>
        <Alert.Actions>
          <Button
            // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
            role="destructive"
            label={t('revocation.remove', { name })}
            onPress={onConfirm}
          />
          <Button
            // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
            role="cancel"
            label={t('revocation.cancel')}
            onPress={onCancel}
          />
        </Alert.Actions>
        <Alert.Message>
          {/* iPhone says it in two sentences; iPad keeps the full explanation its frames draw. */}
          <SwiftUIText>
            {t(ipad ? 'revocation.confirm' : 'revocation.confirmPhone', {
              name,
            })}
          </SwiftUIText>
        </Alert.Message>
      </Alert>
    </Host>
  );
}

// A native confirmation callback may arrive after its account view closes.
function useConfirmationLifetime() {
  const mounted = useRef(false);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  return useCallback(() => mounted.current, []);
}

// A prepared removal happens only after its replacement Recovery Key is confirmed as saved.
function RevocationProposal({
  button,
  failure,
  name,
  recoveryKey,
  store,
}: {
  readonly button: SettingsButton;
  readonly failure: RevocationFailure | undefined;
  readonly name: string;
  readonly recoveryKey: string;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  return (
    <SettingsBlock>
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('revocation.proposal', { name })}
      </Text>
      <Text
        selectable
        testID="revocation-recovery-key"
        style={[styles.recoveryKey, { color: colors.textPrimary }]}>
        {recoveryKey}
      </Text>
      <Text style={[styles.text, { color: colors.textSecondary }]}>
        {t('revocation.prompt', { name })}
      </Text>
      <TextInput
        accessibilityLabel={t('revocation.label')}
        autoCapitalize="characters"
        autoComplete="off"
        autoCorrect={false}
        onChangeText={(text) => {
          setEntry(recoveryKeyEntry(text));
        }}
        placeholder={t('revocation.label')}
        placeholderTextColor={colors.textSecondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.textPrimary },
        ]}
        value={entry}
      />
      {failure === 'mismatch' ? (
        <AnnouncedAlert style={[styles.text, { color: colors.textPrimary }]}>
          {t('revocation.mismatch')}
        </AnnouncedAlert>
      ) : null}
      {button(t('revocation.remove', { name }), () =>
        store.confirmRevocation(entry),
      )}
      {button(t('revocation.cancel'), store.cancelRevocation)}
    </SettingsBlock>
  );
}

// Each kind's symbol; a device that has not reported its kind shows a neutral one.
const symbols = {
  iphone: 'iphone',
  ipad: 'ipad',
  mac: 'laptopcomputer',
} as const;

// Removing another Trusted Device is confirmed here; the native side then asks for a new sign-in
// and prepares the removal, which waits for its replacement Recovery Key to be confirmed.
export function TrustedDevices({
  account,
  approves,
  button,
  failure,
  store,
}: {
  readonly account: Readonly<{
    privateSync?: PrivateSyncState;
    trustedDevices?: string;
    revocationDevice?: string;
    revocationRecoveryKey?: string;
    revocationNotice?: 'removed' | 'renewed' | 'unconfirmed' | 'superseded';
  }>;
  // Only a device holding the account keys approves or removes devices.
  readonly approves: boolean;
  readonly button: SettingsButton;
  readonly failure: RevocationFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const [confirming, setConfirming] = useState<
    Readonly<{
      device: TrustedDevice;
      owner: RegistrationSnapshot;
    }>
  >();
  const added = useMemo(
    () => new Intl.DateTimeFormat(settings.locale, { dateStyle: 'medium' }),
    [settings.locale],
  );
  const dates = useMessageDateFormats();
  const now = useNow();
  // The device in hand says so; another shows when it was last active, with its exact time, or when
  // it was added until it reports.
  const detail = (device: TrustedDevice) => {
    if (device.current === true) {
      return t(
        device.kind === 'ipad'
          ? 'revocation.thisIpad'
          : 'revocation.thisIphone',
      );
    }
    if (device.activeAt === undefined) {
      return t('revocation.added', {
        date: added.format(device.registeredAt),
      });
    }
    const at = new Date(device.activeAt);
    const day = dates.day(at.toISOString(), now);
    if (day === 'today' || day === 'yesterday') {
      return t(
        day === 'today'
          ? 'revocation.lastActiveToday'
          : 'revocation.lastActiveYesterday',
        { time: dates.time.format(at) },
      );
    }
    return t('revocation.lastActive', { date: dates.header(t, at, now) });
  };
  const isCurrent = useConfirmationLifetime();
  // A changed snapshot retires an open confirmation, so an identical later one cannot reopen it.
  if (
    confirming !== undefined &&
    confirming.owner !== store.getSnapshot().snapshot
  ) {
    setConfirming(undefined);
  }
  const proposal = revocationProposal(t, account);
  // A retained proposal stays confirmable after this device loses its encryption key, when it
  // can no longer approve devices but may still need to repeat the exact removal it sent.
  if (!approves && proposal === undefined) {
    return null;
  }
  // While a removal waits for confirmation, no other one starts.
  const devices =
    account.privateSync === 'ready' && proposal === undefined
      ? trustedDevicesOf(account)
      : [];
  const notice = revocationNotice(t, account, failure);
  if (devices.length === 0 && notice === undefined && proposal === undefined) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('revocation.title')}
      footer={devices.length === 0 ? undefined : t('revocation.footer')}>
      {notice === undefined ? null : (
        <SettingsBlock>
          <AnnouncedAlert style={[styles.text, { color: colors.textPrimary }]}>
            {notice}
          </AnnouncedAlert>
        </SettingsBlock>
      )}
      {proposal === undefined ? null : (
        <RevocationProposal
          // An entry typed for one proposed key never carries over to a renewed one.
          key={proposal.recoveryKey}
          button={button}
          failure={failure}
          name={proposal.name}
          recoveryKey={proposal.recoveryKey}
          store={store}
        />
      )}
      {devices.map((device) => {
        const subtitle = detail(device);
        const remove = t('revocation.remove', { name: device.name });
        // Like the button, which is disabled while registration is busy.
        const confirm = () => {
          const { snapshot, busy } = store.getSnapshot();
          if (!busy) {
            setConfirming({ device, owner: snapshot });
          }
        };
        return (
          <SettingsRow
            key={device.id}
            icon={
              device.kind === undefined
                ? 'laptopcomputer.and.iphone'
                : symbols[device.kind]
            }
            iconTone="primary"
            title={device.name}
            subtitle={subtitle}
            value={
              device.current === true
                ? t('revocation.currentDevice')
                : undefined
            }
            // VoiceOver reads the kind, name, Current Device and second line as one element.
            accessibilityLabel={[
              device.kind === undefined
                ? undefined
                : t('revocation.kind', { context: device.kind }),
              device.name,
              device.current === true
                ? t('revocation.currentDevice')
                : undefined,
              subtitle,
            ]
              .filter((part) => part !== undefined)
              .join(', ')}
            accessibilityAction={
              device.current === true || store.getSnapshot().busy
                ? undefined
                : { label: remove, onActivate: confirm }
            }>
            {device.current === true
              ? undefined
              : button(
                  remove,
                  async () => {
                    confirm();
                  },
                  { title: t('settings.remove') },
                )}
          </SettingsRow>
        );
      })}
      {confirming === undefined ||
      store.getSnapshot().snapshot !== confirming.owner ? null : (
        <DeviceConfirmation
          name={confirming.device.name}
          onCancel={() => {
            setConfirming(undefined);
          }}
          onConfirm={() => {
            if (
              isCurrent() &&
              store.getSnapshot().snapshot === confirming.owner
            ) {
              setConfirming(undefined);
              void store.revokeTrustedDevice(confirming.device.id);
            }
          }}
        />
      )}
    </SettingsGroup>
  );
}
