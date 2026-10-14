import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RegistrationSnapshot,
  RevocationFailure,
  TrustedDevice,
} from '@private-email/mail-core/registration';

import {
  approvesDevices,
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const confirmationStyles = StyleSheet.create({
  backdrop: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: spacing.xl,
  },
  card: {
    width: '100%',
    maxWidth: 420,
    maxHeight: '80%',
    padding: spacing.xl,
    gap: spacing.m,
    borderRadius: radius.alertTouch,
  },
  body: { flexGrow: 0, flexShrink: 1 },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
  },
});

// The full safety explanation uses AA text on an opaque native modal rather than system gray.
function DeviceConfirmation({
  name,
  onCancel,
  onConfirm,
}: {
  readonly name: string;
  readonly onCancel: () => void;
  readonly onConfirm: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const title = useRef<Text>(null);
  return (
    <Modal
      visible
      transparent
      onRequestClose={onCancel}
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}
      onShow={() => {
        if (title.current !== null) {
          AccessibilityInfo.sendAccessibilityEvent(title.current, 'focus');
        }
      }}>
      <View
        style={[
          confirmationStyles.backdrop,
          { backgroundColor: colors.scrimTouch },
        ]}>
        <Pressable
          accessible={false}
          onPress={onCancel}
          style={StyleSheet.absoluteFill}
        />
        <View
          accessibilityViewIsModal
          onAccessibilityEscape={onCancel}
          testID="device-removal-confirmation"
          style={[
            confirmationStyles.card,
            {
              backgroundColor: colors.surfaceContent,
              boxShadow: colors.menuShadow,
            },
          ]}>
          <ScrollView
            style={confirmationStyles.body}
            contentContainerStyle={{ gap: spacing.m }}>
            <Text
              ref={title}
              accessibilityRole="header"
              style={[
                textStyles.headline,
                { color: colors.textPrimary, textAlign: 'center' },
              ]}>
              {t('revocation.remove', { name })}
            </Text>
            <Text
              style={[textStyles.subheadline, { color: colors.textSecondary }]}>
              {t('revocation.confirm', { name })}
            </Text>
          </ScrollView>
          <Pressable
            accessibilityLabel={t('revocation.remove', { name })}
            accessibilityRole="button"
            onPress={onConfirm}
            style={[
              confirmationStyles.choice,
              { backgroundColor: colors.fillQuiet },
            ]}>
            <Text
              style={[textStyles.body, { color: colors.statusDestructive }]}>
              {t('revocation.remove', { name })}
            </Text>
          </Pressable>
          <Pressable
            accessibilityLabel={t('revocation.cancel')}
            accessibilityRole="button"
            onPress={onCancel}
            style={[
              confirmationStyles.choice,
              { backgroundColor: colors.fillQuiet },
            ]}>
            <Text style={[textStyles.body, { color: colors.textPrimary }]}>
              {t('revocation.cancel')}
            </Text>
          </Pressable>
        </View>
      </View>
    </Modal>
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
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t('revocation.mismatch')}
        </Text>
      ) : null}
      {button(t('revocation.remove', { name }), () =>
        store.confirmRevocation(entry),
      )}
      {button(t('revocation.cancel'), store.cancelRevocation)}
    </SettingsBlock>
  );
}

// Removing another Trusted Device is confirmed here; the native side then asks for a new sign-in
// and prepares the removal, which waits for its replacement Recovery Key to be confirmed.
export function TrustedDevices({
  account,
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
  if (!approvesDevices(account.privateSync) && proposal === undefined) {
    return null;
  }
  // While a removal waits for confirmation, no other one starts.
  const devices =
    account.privateSync === 'ready' && proposal === undefined
      ? trustedDevicesOf(account)
      : [];
  const notice = revocationNotice(t, account, failure === 'failed');
  if (devices.length === 0 && notice === undefined && proposal === undefined) {
    return null;
  }
  return (
    <SettingsGroup
      title={t('revocation.title')}
      footer={devices.length === 0 ? undefined : t('revocation.description')}>
      {notice === undefined ? null : (
        <SettingsBlock>
          <Text
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {notice}
          </Text>
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
      {devices.map((device) => (
        <SettingsRow
          key={device.id}
          title={device.name}
          subtitle={t('revocation.added', {
            date: added.format(device.registeredAt),
          })}>
          {button(
            t('revocation.remove', { name: device.name }),
            async () => {
              setConfirming({ device, owner: store.getSnapshot().snapshot });
            },
            { title: t('settings.remove') },
          )}
        </SettingsRow>
      ))}
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
