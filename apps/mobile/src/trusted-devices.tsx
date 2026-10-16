import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RegistrationSnapshot,
  RevocationFailure,
  TrustedDevice,
} from '@private-email/mail-core/registration';

import {
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const ipad = Platform.OS === 'ios' && Platform.isPad;

const confirmationStyles = StyleSheet.create({
  backdrop: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: spacing.xl,
  },
  card: {
    width: '100%',
    maxWidth: ipad ? 345 : 310,
    maxHeight: '80%',
    padding: ipad ? 23 : 22,
    gap: ipad ? 11.5 : spacing.s,
    borderRadius: ipad ? radius.alertMac * 1.15 : radius.alertTouch,
  },
  body: { flexGrow: 0, flexShrink: 1 },
  iconTile: {
    alignSelf: 'center',
    alignItems: 'center',
    justifyContent: 'center',
    width: ipad ? 64.4 : 52,
    height: ipad ? 64.4 : 52,
    borderRadius: ipad ? 16.1 : 14,
  },
  title: {
    ...(ipad ? typography.ipadList.title3Emphasized : textStyles.headline),
    textAlign: 'center',
  },
  description: {
    ...(ipad ? typography.ipadList.body : textStyles.subheadline),
    textAlign: 'center',
  },
  choices: { gap: ipad ? 9.2 : spacing.s, paddingTop: ipad ? 6.9 : spacing.s },
  choice: {
    minHeight: ipad ? 44 : 48,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: ipad ? radius.control * 1.15 : 24,
  },
  choiceText: ipad ? typography.ipadList.body : textStyles.headline,
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
          { backgroundColor: ipad ? colors.scrimMac : colors.scrimTouch },
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
            contentContainerStyle={{ gap: ipad ? 11.5 : spacing.s }}>
            <View
              style={[
                confirmationStyles.iconTile,
                { backgroundColor: colors.fillQuiet },
              ]}>
              <SFSymbol
                name="laptopcomputer.and.iphone"
                size={28}
                color={colors.accentInk}
              />
            </View>
            <Text
              ref={title}
              accessibilityRole="header"
              style={[confirmationStyles.title, { color: colors.textPrimary }]}>
              {t('revocation.confirmTitle', { name })}
            </Text>
            <Text
              style={[
                confirmationStyles.description,
                { color: colors.textSecondary },
              ]}>
              {t('revocation.confirm', { name })}
            </Text>
          </ScrollView>
          <View style={confirmationStyles.choices}>
            <Pressable
              accessibilityLabel={t('revocation.remove', { name })}
              accessibilityRole="button"
              onPress={onConfirm}
              style={[
                confirmationStyles.choice,
                { backgroundColor: colors.fillQuiet },
              ]}>
              <Text
                style={[
                  confirmationStyles.choiceText,
                  { color: colors.statusDestructive },
                ]}>
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
              <Text
                style={[
                  confirmationStyles.choiceText,
                  { color: ipad ? colors.textPrimary : colors.accentInk },
                ]}>
                {t('revocation.cancel')}
              </Text>
            </Pressable>
          </View>
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
