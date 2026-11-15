import type { PreviewLines } from '@private-email/mail-core/inbox-preferences';

import { defaultProfile } from '@private-email/mail-core/registration';
import { createContext, use, useEffect, useSyncExternalStore } from 'react';

import { PopUp } from './composer-controls.tsx';
import { useLocalization } from './localization.ts';
import { inboxPreferences } from './registration.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';

export const InboxPreferencesContext = createContext(inboxPreferences);
const choices: readonly PreviewLines[] = [0, 1, 2, 3];

// How many preview lines `profile`'s Inbox rows show, which its other Trusted Devices share. A
// Profile without a choice follows the default Profile's; one line by default.
export function usePreviewLines(profile: string) {
  const store = use(InboxPreferencesContext);
  return useSyncExternalStore(
    store.subscribe,
    () =>
      store.previewLines(profile) ?? store.previewLines(defaultProfile) ?? 1,
  );
}

// Settings › Appearance › Message list. The Settings window has no Mail Profile, so a choice
// applies to every Profile in `profiles`.
export function PreviewLinesSettings({
  profiles,
}: {
  readonly profiles: readonly string[];
}) {
  const { t } = useLocalization();
  const store = use(InboxPreferencesContext);
  const lines = usePreviewLines(defaultProfile);
  // Settings can open before the Inbox, which otherwise reads the kept choice.
  useEffect(() => {
    void store.load();
  }, [store]);
  const title = (count: PreviewLines) =>
    count === 0 ? t('previewLines.none') : t('previewLines.lines', { count });

  return (
    <SettingsGroup
      title={t('previewLines.group')}
      footer={t('previewLines.footer')}>
      <SettingsRow title={t('previewLines.title')}>
        <PopUp
          accessibilityLabel={t('previewLines.title')}
          variant="inline"
          label={title(lines)}
          items={choices.map((count) => ({
            key: String(count),
            title: title(count),
            checked: count === lines,
            run: () => {
              void store.setPreviewLines(profiles, count);
            },
          }))}
        />
      </SettingsRow>
    </SettingsGroup>
  );
}
