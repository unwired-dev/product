import type { BlockedSenders } from '@private-email/mail-core/blocked-senders';
import type { MailProfile } from '@private-email/mail-core/registration';

import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import { createContext, use, useEffect, useMemo, useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from './design.tsx';
import { useLocalization } from './localization.ts';
import { blockedSenders } from './registration.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { usePalette } from './theme.ts';

export const BlockedSendersContext =
  createContext<BlockedSenders>(blockedSenders);

const styles = StyleSheet.create({
  controls: {
    flexDirection: 'row',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
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
  profiles,
}: {
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
  // A block's date tells it from a later block of the same address.
  const [selected, setSelected] =
    useState<
      Readonly<{ profile: string; address: string; blockedAt: number }>
    >();
  const [failed, setFailed] = useState<string>();
  const scopes = useMemo(
    () => [defaultProfile, ...profiles.map(({ id }) => id)],
    [profiles],
  );
  // Reads again after every change, here or from a reader's Block Sender…; only the latest read
  // is shown.
  useEffect(() => {
    let current = 0;
    const load = async () => {
      current += 1;
      const read = current;
      const next = await Promise.all(
        scopes.map(async (profile) => ({
          profile,
          senders: await store.blockedSenders(profile),
        })),
      );
      if (read === current) {
        setListed(next);
        // A selection a read no longer lists stays cleared, even if the address is blocked again.
        setSelected((chosen) =>
          next.some(
            ({ profile, senders }) =>
              profile === chosen?.profile &&
              senders?.some(({ address }) => address === chosen.address),
          )
            ? chosen
            : undefined,
        );
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
  // A selected address unblocked elsewhere is no longer selected, nor when blocked again.
  const chosen = groups.some(
    ({ profile, senders }) =>
      profile === selected?.profile &&
      senders?.some(
        ({ address, blockedAt }) =>
          address === selected.address && blockedAt === selected.blockedAt,
      ),
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
              setSelected({ profile, address, blockedAt });
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
        <Button
          label="−"
          accessibilityLabel={t('blockedSenders.unblock')}
          disabled={chosen?.profile !== profile}
          onPress={() => {
            void unblock();
          }}
        />
      </View>
    </SettingsGroup>
  ));
}
