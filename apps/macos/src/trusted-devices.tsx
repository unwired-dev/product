import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RevocationFailure,
} from '@private-email/mail-core/registration';

import {
  approvesDevices,
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Alert, Text, TextInput } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

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
      <Label
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('revocation.proposal', { name })}
      </Label>
      <Text
        selectable
        testID="revocation-recovery-key"
        style={[styles.recoveryKey, { color: colors.textPrimary }]}>
        {recoveryKey}
      </Text>
      <Label style={[styles.text, { color: colors.textSecondary }]}>
        {t('revocation.prompt', { name })}
      </Label>
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
        <Label
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t('revocation.mismatch')}
        </Label>
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
  const added = useMemo(
    () => new Intl.DateTimeFormat(settings.locale, { dateStyle: 'medium' }),
    [settings.locale],
  );
  const isCurrent = useConfirmationLifetime();
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
          <Label
            accessibilityRole="alert"
            style={[styles.text, { color: colors.textPrimary }]}>
            {notice}
          </Label>
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
              const owner = store.getSnapshot().snapshot;
              Alert.alert(
                t('revocation.confirmTitle', { name: device.name }),
                t('revocation.confirm', { name: device.name }),
                [
                  { text: t('revocation.cancel'), style: 'cancel' },
                  {
                    text: t('revocation.remove', { name: device.name }),
                    style: 'destructive',
                    onPress: () => {
                      if (
                        isCurrent() &&
                        store.getSnapshot().snapshot === owner
                      ) {
                        void store.revokeTrustedDevice(device.id);
                      }
                    },
                  },
                ],
              );
            },
            { title: t('settings.remove') },
          )}
        </SettingsRow>
      ))}
    </SettingsGroup>
  );
}
