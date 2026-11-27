import type { MailProfile } from '@private-email/mail-core/registration';

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
import { shownDomain } from '@private-email/mail-core/blocked-senders';
import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { radius, typography } from '@private-email/mail-core/theme';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import {
  createContext,
  Fragment,
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
  useWindowDimensions,
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
  // The page ends at the window's bottom and starts below the bar; padding its bottom by the
  // bar's height centres the state on the screen. Its layout height, unlike its window position,
  // holds while the page slides in.
  const { height: screen } = useWindowDimensions();
  const [height, setHeight] = useState(screen);
  return (
    <View
      onLayout={({ nativeEvent: { layout } }) => {
        setHeight(layout.height);
      }}
      style={styles.list}>
      <ScrollView
        contentContainerStyle={[
          styles.unavailable,
          { paddingBottom: Math.max(0, screen - height) },
        ]}>
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

// A row's first line, in the frames' Body: the iOS style on iPhone, the iPad list's on iPad.
const primary = (tone: string) => [
  device === 'ipad'
    ? font({ size: typography.ipadList.body.fontSize })
    : font({ textStyle: 'body' }),
  foregroundStyle(tone),
];

// A row's second line: its block date and count, or a failed unblock.
const detail = (tone: string) => [
  device === 'ipad'
    ? font({ size: typography.ipadList.subheadline.fontSize })
    : font({ textStyle: 'footnote' }),
  foregroundStyle(tone),
];

// A Blocked Domain's second line: an `xn--` name with the characters it shows, else its choices.
const domainDetail = (
  t: ReturnType<typeof useLocalization>['t'],
  {
    domain,
    subdomains,
    exempt,
  }: Readonly<{
    domain: string;
    subdomains: boolean;
    exempt: readonly string[];
  }>,
) => {
  const shown = shownDomain(domain);
  if (shown === undefined) {
    return subdomains
      ? t('blockedSenders.withSubdomainsDetail', { count: exempt.length })
      : t('blockedSenders.domainOnlyDetail', { count: exempt.length });
  }
  const { script, ...shows } = shown;
  return script === undefined
    ? t('blockedSenders.shownAs', shows)
    : t('blockedSenders.shownAs', { ...shows, context: script });
};

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
    domains: Awaited<ReturnType<(typeof blockedSenders)['blockedDomains']>>;
  }>
>;

// A section's header: the Mail Profile's name over its first section, then Domains or Addresses.
function SectionHeader({
  profile,
  title,
}: {
  readonly profile: string | undefined;
  readonly title: string;
}) {
  const colors = usePalette();
  return (
    <VStack
      alignment="leading"
      // The frames set the Domains or Addresses ink 45pt below the name's on iPhone, 40pt on iPad.
      spacing={device === 'ipad' ? 17 : 22}>
      {profile === undefined ? null : (
        <Text
          modifiers={[
            font({ size: 20, weight: 'semibold' }),
            foregroundStyle(colors.textPrimary),
          ]}>
          {profile}
        </Text>
      )}
      <Text
        modifiers={[
          device === 'ipad'
            ? font({
                size: typography.ipadList.subheadline.fontSize,
                weight: 'semibold',
              })
            : font({ textStyle: 'subheadline', weight: 'semibold' }),
          foregroundStyle(colors.textSecondary),
        ]}>
        {title}
      </Text>
    </VStack>
  );
}

// Settings › Blocked Senders: each Mail Profile's Blocked Domains, then its Blocked Senders, newest
// first, each sender with how many arrivals this device moved to Trash and each domain with its
// choices, or an `xn--` name with the characters it shows. The system list's swipe and Edit
// unblock one.
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
  const unblockDomain = async (profile: string, domain: string) => {
    if (!(await store.unblockDomain(profile, domain))) {
      setFailed(`${profile}\n${domain}`);
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
          domains: await store.blockedDomains(profile),
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
  if (
    listed.some(
      ({ senders, domains }) => senders === undefined || domains === undefined,
    )
  ) {
    return (
      <Unavailable
        onRetry={() => {
          retry.current?.();
        }}
      />
    );
  }
  const groups = listed.flatMap(({ profile, senders = [], domains = [] }) =>
    senders.length + domains.length === 0
      ? []
      : [
          {
            profile,
            senders: Arr.sort(senders, newestFirst),
            domains: Arr.sort(domains, newestFirst),
          },
        ],
  );
  const footer = <Text>{t('blockedSenders.footer', { context: device })}</Text>;
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
        {groups.map(({ profile, senders, domains }, index) => {
          const name = profileName(t, profile, profiles);
          const last = index === groups.length - 1;
          return (
            <Fragment key={profile}>
              {domains.length === 0 ? null : (
                <Section
                  header={
                    <SectionHeader
                      profile={name}
                      title={t('blockedSenders.domains')}
                    />
                  }
                  footer={last && senders.length === 0 ? footer : undefined}>
                  <List.ForEach
                    data={domains}
                    keyExtractor={({ domain }) => domain}
                    onDelete={(indices) => {
                      setFailed(undefined);
                      for (const { domain } of indices.flatMap(
                        (each) => domains[each] ?? [],
                      )) {
                        void unblockDomain(profile, domain);
                      }
                    }}>
                    {({ item: block }) => (
                      <VStack
                        alignment="leading"
                        spacing={2}
                        modifiers={[listRowBackground(colors.fillQuiet)]}>
                        <Text modifiers={primary(colors.textPrimary)}>
                          {block.domain}
                        </Text>
                        {failed === `${profile}\n${block.domain}` ? (
                          <Text modifiers={detail(colors.statusWarning)}>
                            {t('blockedSenders.unblockFailed')}
                          </Text>
                        ) : (
                          <Text modifiers={detail(colors.textSecondary)}>
                            {domainDetail(t, block)}
                          </Text>
                        )}
                      </VStack>
                    )}
                  </List.ForEach>
                </Section>
              )}
              {senders.length === 0 ? null : (
                <Section
                  header={
                    <SectionHeader
                      profile={domains.length === 0 ? name : undefined}
                      title={t('blockedSenders.addresses')}
                    />
                  }
                  footer={last ? footer : undefined}>
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
                          <Text modifiers={primary(colors.textPrimary)}>
                            {address}
                          </Text>
                          {failed === `${profile}\n${address}` ? (
                            <Text modifiers={detail(colors.statusWarning)}>
                              {t('blockedSenders.unblockFailed')}
                            </Text>
                          ) : (
                            <Text modifiers={detail(colors.textSecondary)}>
                              {moved === 0
                                ? t('blockedSenders.blockedNone', {
                                    date: blocked,
                                  })
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
              )}
            </Fragment>
          );
        })}
      </List>
    </Host>
  );
}
