import { Host, Picker, Text } from '@expo/ui/swift-ui';
import { disabled, pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { languages } from '@private-email/localization';
import { useState } from 'react';
import { StyleSheet } from 'react-native';

import { AnnouncedAlert } from './design.tsx';
import { localization, useLocalization } from './localization.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({ text: { ...textStyles.subheadline } });

// SwiftUI tags cannot be null, so System Default's null preference takes a UI-only tag.
const systemDefault = 'system';

// The interface language as a row whose native menu checks the saved choice; Settings adds its
// explanation below.
export function LanguageSelector({
  footer,
}: {
  readonly footer?: string | undefined;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  // The choice being saved. Clearing it after a refused save changes the selection back, which
  // is the only way the native picker drops the choice it already shows.
  const [pending, setPending] = useState<string>();
  const [failed, setFailed] = useState(false);

  async function select(selection: string) {
    setPending(selection);
    setFailed(false);
    try {
      await localization.setLanguage(
        selection === systemDefault ? null : selection,
      );
    } catch {
      setFailed(true);
    }
    setPending(undefined);
  }

  return (
    <SettingsGroup footer={footer}>
      <SettingsRow title={t('language.title')}>
        <Host matchContents>
          <Picker
            testID="language"
            label={t('language.title')}
            selection={pending ?? settings.preference ?? systemDefault}
            onSelectionChange={(selection: string) => {
              void select(selection);
            }}
            modifiers={[pickerStyle('menu'), disabled(pending !== undefined)]}>
            <Text modifiers={[tag(systemDefault)]}>
              {t('language.systemDefault')}
            </Text>
            {languages.map(({ code, name }) => (
              <Text
                key={code}
                modifiers={[tag(code)]}>
                {name}
              </Text>
            ))}
          </Picker>
        </Host>
      </SettingsRow>
      {failed ? (
        <SettingsBlock>
          <AnnouncedAlert style={[styles.text, { color: colors.textPrimary }]}>
            {t('language.saveFailed')}
          </AnnouncedAlert>
        </SettingsBlock>
      ) : null}
    </SettingsGroup>
  );
}
