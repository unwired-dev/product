import { languages } from '@private-email/localization';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { localization, useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  container: { paddingHorizontal: spacing.xl, gap: spacing.s },
  options: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  option: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.s,
    borderWidth: 1,
    borderRadius: radius.control,
  },
  text: { ...textStyles.subheadline },
});

export function LanguageSelector() {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const options = [{ code: null, name: t('language.system') }, ...languages];

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

  return (
    <View style={styles.container}>
      <Text
        accessibilityRole="header"
        style={[styles.text, { color: colors.textSecondary }]}>
        {t('language.title')}
      </Text>
      <View style={styles.options}>
        {options.map(({ code, name }) => (
          <Pressable
            key={code ?? 'system'}
            testID={`language-${code ?? 'system'}`}
            accessibilityRole="radio"
            accessibilityState={{
              checked: settings.preference === code,
              disabled: saving,
            }}
            disabled={saving}
            onPress={() => {
              void select(code);
            }}
            style={[
              styles.option,
              {
                borderColor:
                  settings.preference === code
                    ? colors.accentInk
                    : colors.separator,
              },
            ]}>
            <Text style={[styles.text, { color: colors.textPrimary }]}>
              {name}
            </Text>
          </Pressable>
        ))}
      </View>
      {failed ? (
        <Text
          accessibilityRole="alert"
          style={[styles.text, { color: colors.textPrimary }]}>
          {t('language.saveFailed')}
        </Text>
      ) : null}
    </View>
  );
}
