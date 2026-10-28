import type {
  PrivateSync as PrivateSyncState,
  Registration,
  RevocationFailure,
} from '@private-email/mail-core/registration';

import {
  recoveryKeyEntry,
  revocationNotice,
  revocationProposal,
  trustedDevicesOf,
} from '@private-email/mail-core/registration';
import { useMemo, useState } from 'react';
import { Text, TextInput } from 'react-native';

import type { SettingsButton } from './settings.tsx';

import { AnnouncedAlert, useConfirmation } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { registrationStyles as styles } from './registration-styles.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

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
  const added = useMemo(
    () => new Intl.DateTimeFormat(settings.locale, { dateStyle: 'medium' }),
    [settings.locale],
  );
  const { anchor, confirm } = useConfirmation();
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
      ref={anchor}
      title={t('revocation.title')}
      footer={devices.length === 0 ? undefined : t('revocation.description')}>
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
              if (
                (await confirm({
                  title: t('revocation.confirmTitle', { name: device.name }),
                  detail: t('revocation.confirm', { name: device.name }),
                  cancel: t('revocation.cancel'),
                  action: t('revocation.remove', { name: device.name }),
                })) &&
                store.getSnapshot().snapshot === owner
              ) {
                await store.revokeTrustedDevice(device.id);
              }
            },
            { title: t('settings.remove') },
          )}
        </SettingsRow>
      ))}
    </SettingsGroup>
  );
}
