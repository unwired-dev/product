import type { Sections } from '@private-email/mail-core/mailboxes';

import { createContext, use, useEffect, useSyncExternalStore } from 'react';
import { Pressable } from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { inboxPreferences } from './registration.ts';
import { settingsColumns, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

export const InboxPreferencesContext = createContext(inboxPreferences);
const choices = ['comfortable', 'compact'] as const;

// `profile`'s Thread-list density, which its other Trusted Devices share.
export function useListDensity(profile: string) {
  const store = use(InboxPreferencesContext);
  return useSyncExternalStore(store.subscribe, () =>
    store.listDensity(profile),
  );
}

const noSections: Sections = {};

// `profile`'s Mailbox Connection sections: which it hides and its folders' order, which its other
// Trusted Devices share; undefined until they are read and while they cannot be.
export function useReadSections(profile: string) {
  const store = use(InboxPreferencesContext);
  return useSyncExternalStore(store.subscribe, () => store.sections(profile));
}

// Whether the Inbox preferences failed their last read, so `useReadSections` stays undefined until a
// read succeeds.
export function usePreferencesUnreadable() {
  const store = use(InboxPreferencesContext);
  return useSyncExternalStore(store.subscribe, store.unreadable);
}

// `profile`'s sections as `useReadSections` gives them; until they are read, every connection shows.
export function useSections(profile: string) {
  return useReadSections(profile) ?? noSections;
}

// Settings › Appearance › List density: Comfortable or Compact for the window's Mail Profile.
export function ListDensitySettings({ profile }: { readonly profile: string }) {
  const { t } = useLocalization();
  const colors = usePalette();
  const store = use(InboxPreferencesContext);
  const density = useListDensity(profile);
  // Settings can open before the Inbox, which otherwise reads the kept choice.
  useEffect(() => {
    void store.load();
  }, [store]);

  return (
    <SettingsGroup
      title={t('listDensity.title')}
      footer={t('listDensity.footer')}>
      {choices.map((each) => (
        <Pressable
          key={each}
          accessibilityLabel={t(`listDensity.${each}`)}
          accessibilityRole="radio"
          accessibilityState={{ checked: each === density }}
          onPress={() => {
            void store.setListDensity(profile, each);
          }}
          style={({ pressed }) =>
            pressed && { backgroundColor: colors.accentSelectionSubtle }
          }>
          <SettingsRow title={t(`listDensity.${each}`)}>
            {each === density ? (
              <SFSymbol
                name="checkmark"
                size={settingsColumns ? 15 : 17}
                color={colors.textSecondary}
              />
            ) : null}
          </SettingsRow>
        </Pressable>
      ))}
    </SettingsGroup>
  );
}
