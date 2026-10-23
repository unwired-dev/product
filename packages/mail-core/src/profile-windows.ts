import type { Translate } from '@private-email/localization';

import * as Effect from 'effect/Effect';

import type { NativePreferences } from './commands.ts';
import type { MenuSection } from './context-menu.ts';
import type {
  MailboxConnection,
  MailProfile,
} from './registration-snapshot.ts';

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

// The Profile Menu: every Mail Profile with its connections and unread mail, the window's own
// checked, then New Mail Profile…. Choosing a Profile switches only the window that asked.
export const profileMenu = (
  t: Translate,
  {
    profiles,
    connections,
    mailboxes,
    current,
    onSwitch,
    onCreate,
  }: Readonly<{
    profiles: readonly MailProfile[];
    connections: readonly MailboxConnection[];
    mailboxes: readonly Listed[];
    current: string;
    onSwitch: (profile: string) => void;
    onCreate: () => void;
  }>,
): readonly MenuSection[] => [
  {
    items: [defaultProfile, ...profiles.map(({ id }) => id)].map((id) => {
      const owned = profileMailboxes(connections, id);
      const { unread } = mailboxSidebar({
        mailboxes: profileMailboxes(mailboxes, id),
        connections,
        profile: id,
        view: {},
      });
      const connectionNames =
        owned.length === 0
          ? t('profiles.noMailboxes')
          : owned
              .map(({ provider }) => t(`mailProviders.${provider}`))
              .reduce((names, provider) =>
                t('profiles.connections', { connections: names, provider }),
              );
      return {
        key: `profile\n${id}`,
        title: profileName(t, id, profiles),
        symbol: '',
        subtitle: t(
          owned.some(({ state }) => state === 'authorization')
            ? 'profiles.detail_authorization'
            : 'profiles.detail',
          { connections: connectionNames, count: unread },
        ),
        checked: id === current,
        run: () => {
          onSwitch(id);
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
    ],
  },
];

// The device-local choices behind each window's Profile, never synchronized: the Profile the
// iPhone and iPad window last showed, and the Startup Profile a new window opens.
const restoredKey = 'window-profile';
const startupKey = 'startup-profile';

export type ProfileChoices = Readonly<{
  restored: string | undefined;
  startup: string | undefined;
}>;

/**
 * The saved window Profile choices, undefined until loaded. A store for the
 * host.
 *
 * @param {NativePreferences} native The device's saved preferences.
 * @returns {object} The choices, their loading and the window's restored
 *   Profile.
 */
export const createProfileChoices = (native: NativePreferences) => {
  let choices: ProfileChoices | undefined = undefined;
  const listeners = new Set<() => void>();
  const publish = (next: ProfileChoices) => {
    choices = next;
    for (const listener of listeners) {
      listener();
    }
  };
  return {
    getSnapshot: () => choices,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Each window reads the saved choices when it opens; an unreadable one reads as none, so the
    // window falls back to the next.
    load: () =>
      runLogged(
        Effect.all([
          savedPreference(native, restoredKey),
          savedPreference(native, startupKey),
        ]).pipe(
          Effect.tap(([restored, startup]) =>
            Effect.sync(() => {
              publish({ restored, startup });
            }),
          ),
          Effect.asVoid,
        ),
      ),
    // The window's last active Profile, which the next launch restores.
    restore: (profile: string) => {
      if (choices === undefined || choices.restored === profile) {
        return Promise.resolve();
      }
      publish({ ...choices, restored: profile });
      return runLogged(savePreference(native, restoredKey, profile));
    },
  };
};

export type ProfileChoicesStore = ReturnType<typeof createProfileChoices>;
