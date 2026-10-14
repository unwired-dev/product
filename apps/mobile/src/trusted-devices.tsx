import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RevocationFailure,
  TrustedDevice,
} from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import {
  approvesDevices,
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { useMemo, useState } from 'react';
import { Text, TextInput, View } from 'react-native';

import { useLocalization } from './localization.ts';
import { TrustCard } from './onboarding.tsx';
import { registrationStyles as styles } from './registration-styles.ts';
import { usePalette } from './theme.ts';

// A prepared removal happens only after its replacement Recovery Key is confirmed as saved.
function RevocationProposal({
  button,
  failure,
  name,
  recoveryKey,
  store,
}: {
  readonly button: (
    label: string,
    action: () => Promise<void>,
    fill?: 'destructive',
  ) => ReactNode;
  readonly failure: RevocationFailure | undefined;
  readonly name: string;
  readonly recoveryKey: string;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [entry, setEntry] = useState('');
  return (
    <View style={styles.device}>
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
    </View>
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
  readonly button: (
    label: string,
    action: () => Promise<void>,
    fill?: 'destructive',
  ) => ReactNode;
  readonly failure: RevocationFailure | undefined;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const added = useMemo(
    () => new Intl.DateTimeFormat(settings.locale, { dateStyle: 'medium' }),
    [settings.locale],
  );
  const [confirming, setConfirming] = useState<TrustedDevice['id']>();
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
    <>
      <Text
        accessibilityRole="header"
        style={[styles.heading, { color: colors.textPrimary }]}>
        {t('revocation.title')}
      </Text>
      {notice === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {notice}
        </Text>
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
      {devices.length === 0 ? null : (
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {t('revocation.description')}
        </Text>
      )}
      {devices.map((device) => (
        <View
          key={device.id}
          style={styles.device}>
          <Text style={[styles.text, { color: colors.textPrimary }]}>
            {device.name}
          </Text>
          <Text style={[styles.text, { color: colors.textSecondary }]}>
            {t('revocation.added', { date: added.format(device.registeredAt) })}
          </Text>
          {confirming === device.id ? (
            <TrustCard
              icon="laptopcomputer.and.iphone"
              title={t('revocation.confirmTitle', { name: device.name })}
              description={t('revocation.confirm', { name: device.name })}>
              {button(
                t('revocation.remove', { name: device.name }),
                async () => {
                  setConfirming(undefined);
                  await store.revokeTrustedDevice(device.id);
                },
                'destructive',
              )}
              {button(t('revocation.cancel'), async () => {
                setConfirming(undefined);
              })}
            </TrustCard>
          ) : (
            button(t('revocation.remove', { name: device.name }), async () => {
              setConfirming(device.id);
            })
          )}
        </View>
      ))}
    </>
  );
}
