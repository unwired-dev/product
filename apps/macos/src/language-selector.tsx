import { languages } from '@private-email/localization';
import { spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { StyleSheet, View } from 'react-native';

import { PopUp } from './composer-controls.tsx';
import { Label } from './label.tsx';
import { localization, useLocalization } from './localization.ts';
import { SettingsBlock, SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  welcome: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    marginTop: spacing.xl,
  },
  caption: { ...textStyles.subheadline },
  text: { ...textStyles.body },
});

// The interface language as a pop-up whose AppKit menu checks the saved choice, and the alert
// when saving a choice fails.
function useLanguageChoice() {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const options = [
    { code: null, name: t('language.systemDefault') },
    ...languages,
  ];

  async function select(language: string | null) {
    setSaving(true);
    setFailed(false);
    try {
      await localization.setLanguage(language);
    } catch {
      setFailed(true);
    }
    setSaving(false);
  }

  return {
    popUp: (
      <PopUp
        accessibilityLabel={t('language.title')}
        disabled={saving}
        label={
          options.find(({ code }) => code === settings.preference)?.name ?? ''
        }
        items={options.map(({ code, name }) => ({
          key: code ?? 'system',
          title: name,
          checked: settings.preference === code,
          run: () => {
            void select(code);
          },
        }))}
      />
    ),
    failure: failed ? (
      <Label
        accessibilityRole="alert"
        style={[styles.text, { color: colors.textPrimary }]}>
        {t('language.saveFailed')}
      </Label>
    ) : null,
  };
}

// Settings › Language.
export function LanguageSettings() {
  const { t } = useLocalization();
  const { popUp, failure } = useLanguageChoice();
  return (
    <SettingsGroup
      title={t('language.title')}
      footer={t('language.detail')}>
      <SettingsRow title={t('language.title')}>{popUp}</SettingsRow>
      {failure === null ? null : <SettingsBlock>{failure}</SettingsBlock>}
    </SettingsGroup>
  );
}

// The small language choice at the end of the sign-in page.
export function WelcomeLanguage() {
  const { t } = useLocalization();
  const colors = usePalette();
  const { popUp, failure } = useLanguageChoice();
  return (
    <>
      <View style={styles.welcome}>
        <Label style={[styles.caption, { color: colors.textSecondary }]}>
          {t('language.title')}
        </Label>
        {popUp}
      </View>
      {failure}
    </>
  );
}
