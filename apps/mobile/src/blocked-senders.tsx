import type { MailProfile } from '@private-email/mail-core/registration';

import { Host, List, Section, Text, VStack } from '@expo/ui/swift-ui';
import {
  environment,
  font,
  foregroundStyle,
  listRowBackground,
  listStyle,
  scrollContentBackground,
} from '@expo/ui/swift-ui/modifiers';
import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import { createContext, use, useEffect, useMemo, useState } from 'react';
import { Platform, StyleSheet } from 'react-native';

import { useLocalization } from './localization.ts';
import { blockedSenders } from './registration.ts';
import { SettingsGroup } from './settings.tsx';
import { usePalette } from './theme.ts';

export const BlockedSendersContext =
  createContext<typeof blockedSenders>(blockedSenders);

const device = Platform.OS === 'ios' && Platform.isPad ? 'ipad' : 'iphone';

const styles = StyleSheet.create({ list: { flex: 1 } });

// A row's second line: its block date and count, or a failed unblock.
const detail = (tone: string) => [
  font({ textStyle: 'subheadline' }),
  foregroundStyle(tone),
];

const newestFirst = Order.flip(
  Order.mapInput(
    Order.Number,
    ({ blockedAt }: { blockedAt: number }) => blockedAt,
  ),
);

type Listed = ReadonlyArray<
  Readonly<{
    profile: string;
    senders: Awaited<ReturnType<(typeof blockedSenders)['blockedSenders']>>;
  }>
>;

// Settings › Blocked Senders: each Mail Profile's Blocked Senders, newest first, with how many
// arrivals this device moved to Trash, in the system list, whose swipe and Edit unblock one.
export function BlockedSenderSettings({
  profiles,
  editing,
}: {
  readonly profiles: readonly MailProfile[];
  readonly editing: boolean;
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
  // The address whose unblock storage refused, until the next attempt.
  const [failed, setFailed] = useState<string>();
  const unblock = async (profile: string, address: string) => {
    if (!(await store.unblock(profile, address))) {
      setFailed(`${profile}\n${address}`);
    }
  };
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
  const groups = listed.flatMap(({ profile, senders = [] }) =>
    senders.length === 0
      ? []
      : [{ profile, senders: Arr.sort(senders, newestFirst) }],
  );
  if (groups.length === 0) {
    return <SettingsGroup footer={t('blockedSenders.none')} />;
  }
  return (
    <Host style={styles.list}>
      <List
        modifiers={[
          listStyle('insetGrouped'),
          scrollContentBackground('hidden'),
          environment('editMode', editing ? 'active' : 'inactive'),
        ]}>
        {groups.map(({ profile, senders }, index) => (
          <Section
            key={profile}
            title={profileName(t, profile, profiles)}
            footer={
              index === groups.length - 1 ? (
                <Text>{t('blockedSenders.footer', { context: device })}</Text>
              ) : undefined
            }>
            <List.ForEach
              data={senders}
              keyExtractor={({ address }) => address}
              onDelete={(indices) => {
                setFailed(undefined);
                for (const { address } of indices.flatMap(
                  (each) => senders[each] ?? [],
                )) {
                  void unblock(profile, address);
                }
              }}>
              {({ item: { address, blockedAt, moved } }) => {
                const blocked = date.format(blockedAt);
                return (
                  <VStack
                    alignment="leading"
                    spacing={2}
                    modifiers={[listRowBackground(colors.fillQuiet)]}>
                    <Text>{address}</Text>
                    {failed === `${profile}\n${address}` ? (
                      <Text modifiers={detail(colors.statusWarning)}>
                        {t('blockedSenders.unblockFailed')}
                      </Text>
                    ) : (
                      <Text modifiers={detail(colors.textSecondary)}>
                        {moved === 0
                          ? t('blockedSenders.blockedNone', { date: blocked })
                          : t('blockedSenders.blocked', {
                              date: blocked,
                              moved,
                            })}
                      </Text>
                    )}
                  </VStack>
                );
              }}
            </List.ForEach>
          </Section>
        ))}
      </List>
    </Host>
  );
}
