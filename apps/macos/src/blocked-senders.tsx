import type { BlockedSenders } from '@private-email/mail-core/blocked-senders';
import type { MailProfile } from '@private-email/mail-core/registration';

import { shownDomain } from '@private-email/mail-core/blocked-senders';
import { profileName } from '@private-email/mail-core/profile-windows';
import { defaultProfile } from '@private-email/mail-core/registration';
import { spacing } from '@private-email/mail-core/theme';
import * as Arr from 'effect/Array';
import * as Order from 'effect/Order';
import {
  createContext,
  Fragment,
  use,
  useEffect,
  useMemo,
  useState,
} from 'react';
import { StyleSheet, View } from 'react-native';

import { Button } from './design.tsx';
import { Label } from './label.tsx';
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
  // The M3 frames' Profile Header: the group header's inset in 13pt bold.
  profile: { paddingTop: 10, paddingHorizontal: spacing.m },
  profileName: { ...textStyles.body, fontWeight: '700', lineHeight: 14 },
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
    domains: Awaited<ReturnType<BlockedSenders['blockedDomains']>>;
  }>
>;

// A listed block: a Blocked Domain or a Blocked Sender's address, in a Mail Profile. Its date
// tells it from a later block of the same name.
type Listing = Readonly<{
  profile: string;
  kind: 'domain' | 'address';
  name: string;
  blockedAt: number;
}>;

const isListing = (listed: Listed, chosen: Listing | undefined) =>
  listed.some(
    ({ profile, senders, domains }) =>
      profile === chosen?.profile &&
      (chosen.kind === 'domain'
        ? domains?.some(
            ({ domain, blockedAt }) =>
              domain === chosen.name && blockedAt === chosen.blockedAt,
          )
        : senders?.some(
            ({ address, blockedAt }) =>
              address === chosen.name && blockedAt === chosen.blockedAt,
          )),
  );

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

// Settings › Blocked Senders: under each Mail Profile's name, its Blocked Domains with their
// choices, then its Blocked Senders with how many arrivals this device moved to Trash, each newest
// first; − unblocks the selected one.
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
  const [selected, setSelected] = useState<Listing>();
  const [failed, setFailed] = useState<string>();
  const scopes = useMemo(
    () => [defaultProfile, ...profiles.map(({ id }) => id)],
    [profiles],
  );
  // Reads again after every change, here or from a reader's Block Sender… or Block Domain…; only
  // the latest read is shown.
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
        // A selection a read no longer lists stays cleared, even if it is blocked again; a read
        // that failed confirms nothing.
        setSelected((chosen) =>
          next.some(
            ({ profile, senders, domains }) =>
              profile === chosen?.profile &&
              (senders === undefined || domains === undefined),
          ) || isListing(next, chosen)
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
  if (
    listed.some(
      ({ senders, domains }) => senders === undefined || domains === undefined,
    )
  ) {
    return <SettingsGroup footer={t('blockedSenders.unavailable')} />;
  }
  const groups = listed.filter(
    ({ senders, domains }) =>
      (senders?.length ?? 0) + (domains?.length ?? 0) > 0,
  );
  // A selected block unblocked elsewhere is no longer selected, nor when blocked again.
  const chosen = isListing(groups, selected) ? selected : undefined;
  if (groups.length === 0) {
    return <SettingsGroup footer={t('blockedSenders.none')} />;
  }
  const unblock = async () => {
    if (chosen === undefined) {
      return;
    }
    setFailed(undefined);
    if (
      await (chosen.kind === 'domain'
        ? store.unblockDomain(chosen.profile, chosen.name)
        : store.unblock(chosen.profile, chosen.name))
    ) {
      setSelected(undefined);
    } else {
      setFailed(`${chosen.profile}\n${chosen.kind}\n${chosen.name}`);
    }
  };
  // One kind of block in a Mail Profile, with − to unblock the selected one.
  const section = ({
    profile,
    kind,
    rows,
    footer,
  }: Readonly<{
    profile: string;
    kind: Listing['kind'];
    rows: ReadonlyArray<
      Readonly<{ name: string; blockedAt: number; detail: string }>
    >;
    footer: string | undefined;
  }>) =>
    rows.length === 0 ? null : (
      <SettingsGroup
        title={t(
          kind === 'domain'
            ? 'blockedSenders.domains'
            : 'blockedSenders.addresses',
        )}
        footer={footer}>
        {rows.map(({ name, blockedAt, detail }) => {
          const unblockFailed = failed === `${profile}\n${kind}\n${name}`;
          return (
            <SettingsRowButton
              key={name}
              accessibilityRole="button"
              accessibilityLabel={name}
              accessibilityState={{
                selected:
                  chosen?.profile === profile &&
                  chosen.kind === kind &&
                  chosen.name === name,
              }}
              onPress={() => {
                setSelected({ profile, kind, name, blockedAt });
              }}>
              <SettingsRow
                title={name}
                subtitle={
                  unblockFailed ? t('blockedSenders.unblockFailed') : detail
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
            disabled={chosen?.profile !== profile || chosen.kind !== kind}
            onPress={() => {
              void unblock();
            }}
          />
        </View>
      </SettingsGroup>
    );
  return groups.map(({ profile, senders = [], domains = [] }, index) => {
    const footer =
      index === groups.length - 1 ? t('blockedSenders.footer') : undefined;
    return (
      <Fragment key={profile}>
        <View style={styles.profile}>
          <Label
            accessibilityRole="header"
            style={[styles.profileName, { color: colors.textPrimary }]}>
            {profileName(t, profile, profiles)}
          </Label>
        </View>
        {section({
          profile,
          kind: 'domain',
          rows: Arr.sort(domains, newestFirst).map((block) => ({
            name: block.domain,
            blockedAt: block.blockedAt,
            detail: domainDetail(t, block),
          })),
          footer: senders.length === 0 ? footer : undefined,
        })}
        {section({
          profile,
          kind: 'address',
          rows: Arr.sort(senders, newestFirst).map(
            ({ address, blockedAt, moved }) => {
              const blocked = date.format(blockedAt);
              return {
                name: address,
                blockedAt,
                detail:
                  moved === 0
                    ? t('blockedSenders.blockedNone', { date: blocked })
                    : t('blockedSenders.blocked', { date: blocked, moved }),
              };
            },
          ),
          footer,
        })}
      </Fragment>
    );
  });
}
