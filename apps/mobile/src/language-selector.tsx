import { Host, Picker, Text } from '@expo/ui/swift-ui';
import { disabled, pickerStyle, tag, tint } from '@expo/ui/swift-ui/modifiers';
import { languages } from '@private-email/localization';
import { spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { StyleSheet, Text as NativeText, View } from 'react-native';

import { AnnouncedAlert, MenuButton, SFSymbol } from './design.tsx';
import { localization, useLocalization } from './localization.ts';
import {
  settingsColumns,
  SettingsBlock,
  SettingsGroup,
  SettingsRow,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  text: { ...textStyles.subheadline },
  // The iPhone frames' pop-up: the choice in SF Pro Medium at 16.9/20.8pt, set without the system
  // font's own -0.42pt tracking at that size, then a 20.8pt circle holding the up-down chevrons
  // 15.6pt after it, at the row's trailing edge.
  menu: { minHeight: 44, marginVertical: -spacing.m },
  popUp: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 15.6,
  },
  choice: {
    fontSize: 16.9,
    lineHeight: 20.8,
    fontWeight: '500',
    letterSpacing: 0.42,
  },
  accessory: {
    width: 20.8,
    height: 20.8,
    borderRadius: 10.4,
    alignItems: 'center',
    justifyContent: 'center',
  },
});

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
  const shown = pending ?? settings.preference ?? systemDefault;

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

  const choices = [
    { code: systemDefault, name: t('language.systemDefault') },
    ...languages,
  ];
  const nameOf = (code: string) =>
    choices.find((choice) => choice.code === code)?.name ?? code;

  return (
    <SettingsGroup footer={footer}>
      <SettingsRow title={t('language.title')}>
        {settingsColumns ? (
          <Host matchContents>
            <Picker
              testID="language"
              label={t('language.title')}
              selection={shown}
              onSelectionChange={(chosen: string) => {
                void select(chosen);
              }}
              modifiers={[
                pickerStyle('menu'),
                tint(colors.textPrimary),
                disabled(pending !== undefined),
              ]}>
              {choices.map(({ code, name }) => (
                <Text
                  key={code}
                  modifiers={[tag(code)]}>
                  {name}
                </Text>
              ))}
            </Picker>
          </Host>
        ) : (
          // SwiftUI's menu picker ignores a font for its label, so iPhone draws the frames' label
          // on the system menu button.
          <MenuButton
            testID="language"
            style={styles.menu}
            disabled={pending !== undefined}
            accessibilityLabel={t('language.title')}
            accessibilityValue={{ text: nameOf(shown) }}
            sections={[
              {
                items: choices.map(({ code, name }) => ({
                  key: code,
                  title: name,
                  symbol: '',
                  checked: code === shown,
                  run: () => {
                    if (pending === undefined && code !== shown) {
                      void select(code);
                    }
                  },
                })),
              },
            ]}>
            <View style={styles.popUp}>
              <NativeText
                numberOfLines={1}
                style={[styles.choice, { color: colors.textPrimary }]}>
                {nameOf(shown)}
              </NativeText>
              <View
                style={[
                  styles.accessory,
                  { backgroundColor: colors.fillControl },
                ]}>
                <SFSymbol
                  name="chevron.up.chevron.down"
                  size={13}
                  color={colors.textPrimary}
                />
              </View>
            </View>
          </MenuButton>
        )}
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
