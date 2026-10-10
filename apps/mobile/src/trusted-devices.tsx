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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
        style={[styles.heading, { color: colors.foreground }]}>
        {t('revocation.proposal', { name })}
      </Text>
      <Text
        selectable
        testID="revocation-recovery-key"
        style={[styles.recoveryKey, { color: colors.foreground }]}>
        {recoveryKey}
      </Text>
      <Text style={[styles.text, { color: colors.secondary }]}>
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
        placeholderTextColor={colors.secondary}
        style={[
          styles.input,
          { borderColor: colors.separator, color: colors.foreground },
        ]}
        value={entry}
      />
      {failure === 'mismatch' ? (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
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
  readonly button: (label: string, action: () => Promise<void>) => ReactNode;
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
  if (!approvesDevices(account.privateSync)) {
    return null;
  }
  const proposal = revocationProposal(t, account);
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
        style={[styles.heading, { color: colors.foreground }]}>
        {t('revocation.title')}
      </Text>
      {notice === undefined ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.foreground }]}>
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
        <Text style={[styles.text, { color: colors.secondary }]}>
          {t('revocation.description')}
        </Text>
      )}
      {devices.map((device) => (
        <View
          key={device.id}
          style={styles.device}>
          <Text style={[styles.text, { color: colors.foreground }]}>
            {device.name}
          </Text>
          <Text style={[styles.text, { color: colors.secondary }]}>
            {t('revocation.added', { date: added.format(device.registeredAt) })}
          </Text>
          {confirming === device.id ? (
            <>
              <Text style={[styles.text, { color: colors.foreground }]}>
                {t('revocation.confirm', { name: device.name })}
              </Text>
              {button(
                t('revocation.remove', { name: device.name }),
                async () => {
                  setConfirming(undefined);
                  await store.revokeTrustedDevice(device.id);
                },
              )}
              {button(t('revocation.cancel'), async () => {
                setConfirming(undefined);
              })}
            </>
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
