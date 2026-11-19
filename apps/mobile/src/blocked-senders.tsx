import type { MailProfile } from '@private-email/mail-core/registration';
import type { ViewInstance } from 'react-native';

import { Button, Host, List, Section, Text, VStack } from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  environment,
  font,
  foregroundStyle,
  listRowBackground,
  listStyle,
  scrollContentBackground,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { radius } from '@private-email/mail-core/theme';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import {
  createContext,
  use,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  Platform,
  ScrollView,
  Text as Label,
  StyleSheet,
  View,
} from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { blockedSenders } from './registration.ts';
import { SettingsGroup } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

export const BlockedSendersContext =
  createContext<typeof blockedSenders>(blockedSenders);

const device = Platform.OS === 'ios' && Platform.isPad ? 'ipad' : 'iphone';

const styles = StyleSheet.create({
  list: { flex: 1 },
  // The Profile Locked recipe, centred on the screen below the opaque bar: tile, title, message
  // and one button. It scrolls when the largest text sizes outgrow the page.
  unavailable: {
    flexGrow: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
    paddingHorizontal: 32,
  },
  tile: {
    width: 68,
    height: 68,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.touchCard,
    borderCurve: 'continuous',
    marginBottom: 14,
  },
  message: { maxWidth: 300, textAlign: 'center', marginBottom: 14 },
});

// Blocked Senders storage could not read: nothing to show, so the page says so and reads again.
function Unavailable({ onRetry }: { readonly onRetry: () => void }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const page = useRef<ViewInstance>(null);
  // The page starts below the bar; padding its bottom by as much centres the state on the screen.
  const [above, setAbove] = useState(0);
  return (
    <View
      ref={page}
      onLayout={() => {
        page.current?.measureInWindow((_x, y) => {
          setAbove(y);
        });
      }}
      style={styles.list}>
      <ScrollView
        contentContainerStyle={[styles.unavailable, { paddingBottom: above }]}>
        <View style={[styles.tile, { backgroundColor: colors.fillQuiet }]}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            size={36}
            color={colors.textPrimary}
          />
        </View>
        <Label
          accessibilityRole="header"
          style={[
            textStyles.title3Emphasized,
            { color: colors.textPrimary, textAlign: 'center' },
          ]}>
          {t('blockedSenders.loadFailed')}
        </Label>
        <Label
          style={[
            textStyles.subheadline,
            styles.message,
            { color: colors.textSecondary },
          ]}>
          {t('blockedSenders.loadFailedDetail')}
        </Label>
        <Host matchContents>
          <Button
            modifiers={[
              buttonStyle('borderedProminent'),
              buttonBorderShape('capsule'),
              controlSize('large'),
              tint(colors.accentFill),
            ]}
            onPress={onRetry}>
            <Text
              modifiers={[
                font({ textStyle: 'headline' }),
                foregroundStyle(colors.accentOnFill),
              ]}>
              {t('common.retry')}
            </Text>
          </Button>
        </Host>
      </ScrollView>
    </View>
  );
}

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
  // Try Again reads again, as a change does.
  const retry = useRef<() => void>(undefined);
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
    retry.current = () => {
      void load();
    };
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
    return (
      <Unavailable
        onRetry={() => {
          retry.current?.();
        }}
      />
    );
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
