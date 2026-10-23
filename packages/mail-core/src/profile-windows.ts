import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';

import type { NativePreferences } from './commands.ts';
import type { MenuSection } from './context-menu.ts';
import type {
  MailboxConnection,
  MailProfile,
} from './registration-snapshot.ts';
import type { ProfileFailure } from './registration.ts';

import { savedPreference, savePreference } from './commands.ts';
import { runLogged } from './diagnostics.ts';
import { mailboxSidebar, profileMailboxes } from './mailbox-views.ts';
import { readingProfile } from './mailboxes.ts';
import { defaultProfile } from './registration-snapshot.ts';

// A window's Mail Profile: a targeted deep link's, then the Profile the window restores, then the
// device's Startup Profile, then the Default Profile. A restored or Startup Profile this device no
// longer lists is skipped, and is kept for when it is listed again; a link is never skipped.
export const windowProfile = ({
  link,
  restored,
  startup,
  profiles,
}: Readonly<{
  link?: unknown;
  restored?: string | undefined;
  startup?: string | undefined;
  profiles: readonly MailProfile[];
}>) => {
  if (link !== undefined) {
    return readingProfile(link);
  }
  const listed = (profile: string | undefined): profile is string =>
    profile === defaultProfile || profiles.some(({ id }) => id === profile);
  if (listed(restored)) {
    return restored;
  }
  return listed(startup) ? startup : defaultProfile;
};

// The name the Profile Switcher and Profile Menu show; the Default Profile is the Primary Profile.
export const profileName = (
  t: Translate,
  profile: string,
  profiles: readonly MailProfile[],
) =>
  profile === defaultProfile
    ? t('profiles.primary')
    : (profiles.find(({ id }) => id === profile)?.name ?? '');

// The switcher's monogram: the first letters of the name's first two words.
export const profileMonogram = (name: string) =>
  name
    .trim()
    .split(/\s+/u)
    .slice(0, 2)
    .map((word) => [...word][0] ?? '')
    .join('')
    .toLocaleUpperCase();

type Listed = Parameters<typeof mailboxSidebar>[0]['mailboxes'][number] &
  Readonly<{ profile: string }>;

// A Mail Profile's connections by provider, or that it has none.
export const profileConnections = (
  t: Translate,
  connections: readonly MailboxConnection[],
  profile: string,
) => {
  const owned = profileMailboxes(connections, profile);
  return owned.length === 0
    ? t('profiles.noMailboxes')
    : owned
        .map(({ provider }) => t(`mailProviders.${provider}`))
        .reduce((names, provider) =>
          t('profiles.connections', { connections: names, provider }),
        );
};

// The question asked before removing a Mail Profile, naming the mailboxes removed with it.
export const profileRemoval = (
  t: Translate,
  name: string,
  owned: readonly MailboxConnection[],
) => {
  const [only] = owned;
  if (only === undefined) {
    return {
      title: t('profiles.removeQuestion', { name }),
      message: t('profiles.removeEmpty', { name }),
    };
  }
  return {
    title: t('profiles.removeQuestionMailboxes', { name }),
    message: t('profiles.removeMailboxes', {
      count: owned.length,
      addresses: owned.map(({ address }) => address).join(', '),
      provider:
        only.provider === 'imap'
          ? t('profiles.mailServer')
          : t(`mailProviders.${only.provider}`),
    }),
  };
};

// Why a Mail Profile change did not complete.
export const profileRefusalText = (
  t: Translate,
  change: 'new' | 'rename' | 'move' | 'remove',
  failure: ProfileFailure,
) => {
  if (failure === 'upgrade-required') {
    return {
      title: t('profiles.upgradeTitle'),
      message: t(
        change === 'new' ? 'profiles.upgradeMessage' : 'profiles.upgradeRetry',
      ),
    };
  }
  return {
    title: t(`profiles.${change}Title`),
    message: t(
      failure === 'failed' ? `profiles.${change}Failed` : 'profiles.changed',
    ),
  };
};

// The Profile Menu: every Mail Profile with its connections and unread mail, the window's own
// checked, then New Mail Profile… and Manage Mail Profiles…. Choosing a Profile switches only the
// window that asked.
export const profileMenu = (
  t: Translate,
  {
    profiles,
    connections,
    mailboxes,
    current,
    onSwitch,
    onCreate,
    onManage,
  }: Readonly<{
    profiles: readonly MailProfile[];
    connections: readonly MailboxConnection[];
    mailboxes: readonly Listed[];
    current: string;
    onSwitch: (profile: string) => void;
    onCreate: () => void;
    // Opens Settings › Mail Profiles.
    onManage: () => void;
  }>,
): readonly MenuSection[] => [
  {
    items: [defaultProfile, ...profiles.map(({ id }) => id)].map((id) => {
      const { unread } = mailboxSidebar({
        mailboxes: profileMailboxes(mailboxes, id),
        connections,
        profile: id,
        view: {},
      });
      return {
        key: `profile\n${id}`,
        title: profileName(t, id, profiles),
        symbol: '',
        subtitle: t(
          profileMailboxes(connections, id).some(
            ({ state }) => state === 'authorization',
          )
            ? 'profiles.detail_authorization'
            : 'profiles.detail',
          {
            connections: profileConnections(t, connections, id),
            count: unread,
          },
        ),
        checked: id === current,
        // The window's own Profile changes nothing, so an open composer and reader stay.
        run: () => {
          if (id !== current) {
            onSwitch(id);
          }
        },
      };
    }),
  },
  {
    items: [
      {
        key: 'profile\nnew',
        title: t('profiles.new'),
        symbol: 'plus',
        run: onCreate,
      },
      {
        key: 'profile\nmanage',
        title: t('profiles.manage'),
        symbol: 'gearshape',
        run: onManage,
      },
    ],
  },
];

// The device-local choices behind each window's Profile, never synchronized: the Profile the
// iPhone and iPad window last showed, and each Product Account's Startup Profile for new windows.
const restoredKey = 'window-profile';
const startupKey = (account: string) => `startup-profile:${account}`;

export type ProfileChoices = Readonly<{
  restored: string | undefined;
  startup: string | undefined;
}>;

/**
 * The saved window Profile choices by Product Account, undefined until loaded.
 * A store for the host.
 *
 * @param {NativePreferences} native The device's saved preferences.
 * @returns {object} The choices, their loading and the window's restored
 *   Profile.
 */
export const createProfileChoices = (native: NativePreferences) => {
  const choices = new Map<string, ProfileChoices>();
  const listeners = new Set<() => void>();
  const publish = (account: string, next: ProfileChoices) => {
    choices.set(account, next);
    for (const listener of listeners) {
      listener();
    }
  };
  const save =
    (choice: keyof ProfileChoices) => (account: string, profile: string) => {
      const current = choices.get(account);
      if (current === undefined || current[choice] === profile) {
        return Promise.resolve();
      }
      publish(account, { ...current, [choice]: profile });
      return runLogged(
        savePreference(
          native,
          choice === 'startup' ? startupKey(account) : restoredKey,
          profile,
        ),
      );
    };
  return {
    getSnapshot: (account: string) => choices.get(account),
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Each window reads the saved choices when it opens; an unreadable one reads as none, so the
    // window falls back to the next.
    load: (account: string) =>
      runLogged(
        Effect.all([
          savedPreference(native, restoredKey),
          savedPreference(native, startupKey(account)),
        ]).pipe(
          Effect.tap(([restored, startup]) =>
            Effect.sync(() => {
              publish(account, { restored, startup });
            }),
          ),
          Effect.asVoid,
        ),
      ),
    // The window's last active Profile, which the next launch restores.
    restore: save('restored'),
    // The Startup Profile, chosen in Settings, which new windows open.
    chooseStartup: save('startup'),
  };
};

export type ProfileChoicesStore = ReturnType<typeof createProfileChoices>;
