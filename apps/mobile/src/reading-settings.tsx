import { spacing, typography } from '@private-email/mail-core/theme';
import { StyleSheet, Switch, Text, View } from 'react-native';

import type { SettingsDestination } from './settings.tsx';

import { MenuButton, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { messageZooms, saveReading, useReading } from './reading.ts';
import {
  PopUpChevrons,
  settingsColumns,
  SettingsGroup,
  SettingsRow,
  switchRowHeight,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  popUpTarget: { marginVertical: settingsColumns ? 0 : -spacing.m },
  popUp: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: settingsColumns ? spacing.xs : spacing.m,
  },
  value: settingsColumns ? typography.ipadList.body : textStyles.body,
});

// Settings › Reading: app text follows the system; received formatted mail zooms on this device.
export function ReadingSettings({
  destination,
}: {
  readonly destination: SettingsDestination | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const { zoom, fit } = useReading();
  const context = settingsColumns ? 'ipad' : 'iphone';
  const percent = (value: number) => t('reading.percent', { value });
  if (destination !== 'reading') {
    return null;
  }
  return (
    <>
      <SettingsGroup title={t('reading.appText')}>
        <SettingsRow title={t('reading.textSize')}>
          <Text style={[styles.value, { color: colors.textSecondary }]}>
            {t('reading.followsSystem')}
          </Text>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup
        title={t('reading.received')}
        footer={t('reading.footer', { context })}>
        <SettingsRow title={t('reading.zoom', { context })}>
          <MenuButton
            accessibilityLabel={`${t('reading.zoom', { context })}: ${percent(zoom)}`}
            sections={[
              {
                items: messageZooms.map((each) => ({
                  key: String(each),
                  title: percent(each),
                  symbol: '',
                  checked: each === zoom,
                  run: () => {
                    saveReading({ zoom: each });
                  },
                })),
              },
            ]}
            style={styles.popUpTarget}>
            <View style={styles.popUp}>
              <Text style={[styles.value, { color: colors.textPrimary }]}>
                {percent(zoom)}
              </Text>
              {settingsColumns ? (
                <SFSymbol
                  name="chevron.up.chevron.down"
                  size={12}
                  color={colors.textSecondary}
                />
              ) : (
                <PopUpChevrons />
              )}
            </View>
          </MenuButton>
        </SettingsRow>
        <SettingsRow
          title={t('reading.fit', { context })}
          minHeight={switchRowHeight}>
          <Switch
            accessibilityLabel={t('reading.fit', { context })}
            value={fit}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            onValueChange={(next) => {
              saveReading({ fit: next });
            }}
          />
        </SettingsRow>
      </SettingsGroup>
    </>
  );
}
