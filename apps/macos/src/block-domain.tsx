import {
  addressesAtDomain,
  parentDomain,
} from '@private-email/mail-core/blocked-senders';
import { spacing } from '@private-email/mail-core/theme';
import { use, useLayoutEffect, useRef, useState } from 'react';
import { StyleSheet, Switch, View } from 'react-native';

import { BlockedSendersContext } from './blocked-senders.tsx';
import { useContactAddresses } from './contacts.ts';
import { Button, SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { windowHost } from './settings-window-client.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

// The M2 frames' Standard sheet: 24pt inside, 12pt between its parts, the buttons 6pt lower.
const styles = StyleSheet.create({
  sheet: { gap: spacing.m, padding: spacing.xxl },
  title: textStyles.title3Emphasized,
  from: textStyles.body,
  failed: textStyles.subheadline,
  failedTitle: { fontWeight: '600' },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
    paddingTop: 6,
  },
});

// The sender Block Domain… offers to block and the Mail Profile of the window it opens on.
export type DomainSender = Readonly<{
  // The sender's name as the message shows it, empty when it has none.
  sender: string;
  address: string;
  // The address's exact domain, as `offeredDomain` gives it.
  domain: string;
  profile: string;
}>;

// The Block Domain sheet's content, in its own React root: the domain with its subdomains or
// alone, the rule that choice makes, Contacts at this domain as an exemption when the person has
// readable contacts there, then Cancel and Block. Block stores the domain with those choices for
// the window's Mail Profile and ends the sheet; a refused write says so and keeps it open. AppKit
// sizes the sheet to it.
export function BlockDomainSheet({
  window,
  sender,
}: {
  readonly window: string;
  readonly sender: DomainSender;
}) {
  const store = use(BlockedSendersContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const { domain } = sender;
  const [subdomains, setSubdomains] = useState(true);
  const [exempting, setExempting] = useState(true);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const mounted = useRef(true);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  // Contacts already readable; blocking never asks for Contacts access, and waits for the read so
  // the exemption is not lost.
  const read = useContactAddresses(true, false);
  const contacts = addressesAtDomain(
    domain,
    subdomains,
    read.addresses.map(({ address }) => address),
  );
  const parent = parentDomain(domain);
  let keeps = t('blockedSenders.ruleKeeps', { context: 'only' });
  if (subdomains) {
    keeps =
      parent === undefined
        ? t('blockedSenders.ruleKeeps')
        : t('blockedSenders.ruleKeepsParent', { parent });
  }
  const close = () => {
    windowHost()?.closeSheet(window);
  };
  const block = async () => {
    setSaving(true);
    setFailed(false);
    const stored = await store.blockDomain(sender.profile, domain, {
      subdomains,
      exempt: exempting ? contacts : [],
    });
    if (!mounted.current) {
      return;
    }
    if (stored) {
      close();
    } else {
      setSaving(false);
      setFailed(true);
    }
  };
  const choices = [
    { value: true, label: t('blockedSenders.withSubdomains', { domain }) },
    { value: false, label: t('blockedSenders.domainOnly', { domain }) },
  ];
  return (
    <View
      // Without a surface of its own, the sheet stays white in Dark (#1923).
      style={[styles.sheet, { backgroundColor: colors.surfaceContent }]}
      onLayout={({ nativeEvent }) => {
        windowHost()?.fitSheet(window, nativeEvent.layout.height);
      }}>
      <Label
        accessibilityRole="header"
        style={[styles.title, { color: colors.textPrimary }]}>
        {t('blockedSenders.blockDomainTitle', { domain })}
      </Label>
      <Label style={[styles.from, { color: colors.textSecondary }]}>
        {sender.sender === '' || sender.sender === sender.address
          ? t('blockedSenders.fromAddress', { address: sender.address })
          : t('blockedSenders.from', {
              sender: sender.sender,
              address: sender.address,
            })}
      </Label>
      <SettingsGroup>
        {choices.map(({ value, label }) => (
          <SettingsRowButton
            key={label}
            accessibilityRole="radio"
            accessibilityLabel={label}
            accessibilityState={{ checked: subdomains === value }}
            disabled={saving}
            onPress={() => {
              setSubdomains(value);
            }}>
            <SettingsRow title={label}>
              {subdomains === value ? (
                <SFSymbol
                  name="checkmark"
                  size={11}
                  color={colors.textSecondary}
                />
              ) : null}
            </SettingsRow>
          </SettingsRowButton>
        ))}
      </SettingsGroup>
      <SettingsGroup title={t('blockedSenders.rule')}>
        <SettingsRow
          title={
            subdomains
              ? t('blockedSenders.ruleSubdomains', { domain })
              : t('blockedSenders.ruleOnly', { domain })
          }
          subtitle={keeps}
        />
      </SettingsGroup>
      {contacts.length === 0 ? null : (
        <SettingsGroup title={t('blockedSenders.exemptions')}>
          <SettingsRow
            title={t('blockedSenders.exemptContacts', { context: 'mac' })}
            subtitle={contacts.join(', ')}>
            <Switch
              accessibilityLabel={t('blockedSenders.exemptContacts', {
                context: 'mac',
              })}
              disabled={saving}
              value={exempting}
              trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
              onValueChange={setExempting}
            />
          </SettingsRow>
        </SettingsGroup>
      )}
      <SettingsGroup footer={t('blockedSenders.blockDomainFooter')} />
      {failed ? (
        <View
          accessible
          accessibilityRole="alert">
          <Label
            style={[
              styles.failed,
              styles.failedTitle,
              { color: colors.statusWarning },
            ]}>
            {t('blockedSenders.blockDomainFailed', { domain })}
          </Label>
          <Label style={[styles.failed, { color: colors.textSecondary }]}>
            {t('blockedSenders.blockDomainTryAgain')}
          </Label>
        </View>
      ) : null}
      <View style={styles.actions}>
        <Button
          label={t('common.cancel')}
          isCancel
          disabled={saving}
          onPress={close}
        />
        <Button
          label={t('blockedSenders.blockDomainAction', { domain })}
          disabled={saving || !read.settled}
          onPress={() => {
            void block();
          }}
        />
      </View>
    </View>
  );
}
