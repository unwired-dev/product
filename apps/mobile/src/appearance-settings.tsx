import type { TurboModule } from 'react-native';

import { useState } from 'react';
import {
  Appearance,
  Pressable,
  Settings,
  TurboModuleRegistry,
} from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { settingsColumns, SettingsGroup, SettingsRow } from './settings.tsx';
import { usePalette } from './theme.ts';

// The user defaults key the choice is kept under, on this device only.
const key = 'UnwiredAppearance';
const choices = ['light', 'dark', 'system'] as const;
type Choice = (typeof choices)[number];

function stored(): Choice {
  const value: unknown = Settings.get(key);
  return value === 'light' || value === 'dark' ? value : 'system';
}

// UIKit keeps the status bar's style until the app asks again (native/design).
const statusBar = TurboModuleRegistry.getEnforcing<
  TurboModule & { readonly refresh: () => void }
>('UnwiredStatusBar');

function apply(choice: Choice) {
  Appearance.setColorScheme(choice === 'system' ? 'auto' : choice);
  statusBar.refresh();
}

// Applies the kept choice at launch, before the first screen draws.
export function restoreAppearance() {
  const choice = stored();
  if (choice !== 'system') {
    apply(choice);
  }
}

// Settings › Appearance: Light, Dark or System, kept on this device only.
export function AppearanceSettings() {
  const { t } = useLocalization();
  const colors = usePalette();
  const [choice, setChoice] = useState(stored);

  return (
    <SettingsGroup
      title={t('appearance.title')}
      footer={t('appearance.iosDetail')}>
      {choices.map((each) => (
        <Pressable
          key={each}
          accessibilityLabel={t(`appearance.${each}`)}
          accessibilityRole="radio"
          accessibilityState={{ checked: each === choice }}
          onPress={() => {
            Settings.set({ [key]: each });
            apply(each);
            setChoice(each);
          }}
          style={({ pressed }) =>
            pressed && { backgroundColor: colors.accentSelectionSubtle }
          }>
          <SettingsRow title={t(`appearance.${each}`)}>
            {/* The frames draw the checkmark as the rows' value, at their text size. */}
            {each === choice ? (
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
