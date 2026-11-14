import { useState } from 'react';
import { Appearance, Settings } from 'react-native';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { usePalette } from './theme.ts';

// The user defaults key AppDelegate reads at launch, so windows open in the chosen appearance.
const key = 'UnwiredAppearance';
const choices = ['light', 'dark', 'system'] as const;
type Choice = (typeof choices)[number];

function stored(): Choice {
  const value: unknown = Settings.get(key);
  return value === 'light' || value === 'dark' ? value : 'system';
}

// Settings › Appearance: Light, Dark or System, kept on this Mac only.
export function AppearanceSettings() {
  const { t } = useLocalization();
  const colors = usePalette();
  const [choice, setChoice] = useState(stored);

  function choose(next: Choice) {
    Settings.set({ [key]: next });
    Appearance.setColorScheme(next === 'system' ? null : next);
    setChoice(next);
  }

  return (
    <SettingsGroup
      title={t('appearance.title')}
      footer={t('appearance.detail')}>
      {choices.map((each) => (
        <SettingsRowButton
          key={each}
          accessibilityLabel={t(`appearance.${each}`)}
          accessibilityRole="radio"
          accessibilityState={{ checked: each === choice }}
          onPress={() => {
            choose(each);
          }}>
          <SettingsRow title={t(`appearance.${each}`)}>
            {each === choice ? (
              <SFSymbol
                name="checkmark"
                size={13}
                color={colors.textSecondary}
              />
            ) : null}
          </SettingsRow>
        </SettingsRowButton>
      ))}
    </SettingsGroup>
  );
}
