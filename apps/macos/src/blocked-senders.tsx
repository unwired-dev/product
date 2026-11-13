import type { BlockedSenders } from '@private-email/mail-core/blocked-senders';
import type {
  MailboxConnection,
  MailProfile,
} from '@private-email/mail-core/registration';

import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { radius } from '@private-email/mail-core/theme';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import { createContext, use, useEffect, useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useLocalization } from './localization.ts';
import { blockedSenders } from './registration.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

export const BlockedSendersContext =
  createContext<BlockedSenders>(blockedSenders);

const styles = StyleSheet.create({
  controls: {
    flexDirection: 'row',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  remove: {
    width: 24,
    height: 20,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
  },
  removeLabel: { fontSize: 15, fontWeight: '500' },
});

const newestFirst = Order.flip(
  Order.mapInput(
    Order.Number,
    ({ blockedAt }: { blockedAt: number }) => blockedAt,
  ),
);

type Listed = ReadonlyArray<
  Readonly<{
    profile: string;
    senders: Awaited<ReturnType<BlockedSenders['blockedSenders']>>;
  }>
>;

// Settings › Blocked Senders: each Mail Profile's Blocked Senders, newest first, with how many
// arrivals this device moved to Trash; − unblocks the selected one.
export function BlockedSenderSettings({
  mailboxes,
  profiles,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly profiles: readonly MailProfile[];
}) {
  const store = use(BlockedSendersContext);
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const date = useMemo(
    () =>
      new Intl.DateTimeFormat(settings.locale, {
        day: 'numeric',
        month: 'short',
      }),
    [settings.locale],
  );
  const [listed, setListed] = useState<Listed>();
  const [selected, setSelected] =
    useState<Readonly<{ profile: string; address: string }>>();
  const [failed, setFailed] = useState<string>();
  // Each Profile and its connections, whose receipts its counts include.
  const scopes = useMemo(
    () =>
      [defaultProfile, ...profiles.map(({ id }) => id)].map((profile) => ({
        profile,
        connections: mailboxes
          .filter((mailbox) => mailbox.profile === profile)
          .map(({ id }) => id),
      })),
    [mailboxes, profiles],
  );
  // Reads again after every change, here or from a reader's Block Sender…; only the latest read
  // is shown.
  useEffect(() => {
    let current = 0;
    const load = async () => {
      current += 1;
      const read = current;
      const next = await Promise.all(
        scopes.map(async ({ profile, connections }) => ({
          profile,
          senders: await store.blockedSenders(profile, connections),
        })),
      );
      if (read === current) {
        setListed(next);
      }
    };
    void load();
    const unsubscribe = store.subscribe(() => {
      void load();
    });
    return () => {
      current = -1;
      unsubscribe();
    };
  }, [store, scopes]);
  if (listed === undefined) {
    return null;
  }
  if (listed.some(({ senders }) => senders === undefined)) {
    return <SettingsGroup footer={t('blockedSenders.unavailable')} />;
  }
  const groups = listed.filter(({ senders }) => (senders?.length ?? 0) > 0);
  // A selected address unblocked elsewhere is no longer selected.
  const chosen = groups.some(
    ({ profile, senders }) =>
      profile === selected?.profile &&
      senders?.some(({ address }) => address === selected.address),
  )
    ? selected
    : undefined;
  if (groups.length === 0) {
    return <SettingsGroup footer={t('blockedSenders.none')} />;
  }
  const unblock = async () => {
    if (chosen === undefined) {
      return;
    }
    setFailed(undefined);
    if (await store.unblock(chosen.profile, chosen.address)) {
      setSelected(undefined);
    } else {
      setFailed(`${chosen.profile}\n${chosen.address}`);
    }
  };
  return groups.map(({ profile, senders = [] }, index) => (
    <SettingsGroup
      key={profile}
      title={profileName(t, profile, profiles)}
      footer={
        index === groups.length - 1 ? t('blockedSenders.footer') : undefined
      }>
      {Arr.sort(senders, newestFirst).map(({ address, blockedAt, moved }) => {
        const isChosen =
          chosen?.profile === profile && chosen.address === address;
        const unblockFailed = failed === `${profile}\n${address}`;
        const blocked = date.format(blockedAt);
        const counted =
          moved === 0
            ? t('blockedSenders.blockedNone', { date: blocked })
            : t('blockedSenders.blocked', { date: blocked, moved });
        return (
          <SettingsRowButton
            key={address}
            accessibilityRole="button"
            accessibilityLabel={address}
            accessibilityState={{ selected: isChosen }}
            onPress={() => {
              setSelected({ profile, address });
            }}>
            <SettingsRow
              title={address}
              subtitle={
                unblockFailed ? t('blockedSenders.unblockFailed') : counted
              }
              subtitleTone={unblockFailed ? 'warning' : undefined}
            />
          </SettingsRowButton>
        );
      })}
      <View style={[styles.controls, { borderTopColor: colors.separator }]}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={t('blockedSenders.unblock')}
          disabled={chosen?.profile !== profile}
          onPress={() => {
            void unblock();
          }}
          style={({ pressed }) => [
            styles.remove,
            pressed && { backgroundColor: colors.accentSelectionSubtle },
            chosen?.profile !== profile && { opacity: 0.4 },
          ]}>
          <Text
            style={[
              textStyles.body,
              styles.removeLabel,
              { color: colors.textPrimary },
            ]}>
            −
          </Text>
        </Pressable>
      </View>
    </SettingsGroup>
  ));
}
