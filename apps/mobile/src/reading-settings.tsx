import { messageZooms } from '@private-email/mail-core/message-body';
import {
  ipadListScale,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { StyleSheet, Switch, Text, View } from 'react-native';

import type { SettingsDestination } from './settings.tsx';

import { MenuButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  setFitWideMessages,
  setMessageZoom,
  useFitWideMessages,
  useMessageZoom,
} from './reading.ts';
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
    gap: settingsColumns ? spacing.m * ipadListScale : spacing.m,
  },
  value: settingsColumns ? typography.ipadList.body : textStyles.body,
});

// Settings › Reading: app text follows the system; received formatted mail zooms, and wide mail
// fits the screen, on this device.
export function ReadingSettings({
  destination,
}: {
  readonly destination: SettingsDestination | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const zoom = useMessageZoom();
  const fit = useFitWideMessages();
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
                    setMessageZoom(each);
                  },
                })),
              },
            ]}
            style={styles.popUpTarget}>
            <View style={styles.popUp}>
              <Text style={[styles.value, { color: colors.textPrimary }]}>
                {percent(zoom)}
              </Text>
              <PopUpChevrons scaled={settingsColumns} />
            </View>
          </MenuButton>
        </SettingsRow>
        <SettingsRow
          title={t('reading.fitWide', { context })}
          minHeight={switchRowHeight}>
          <Switch
            accessibilityLabel={t('reading.fitWide', { context })}
            value={fit}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            onValueChange={setFitWideMessages}
          />
        </SettingsRow>
      </SettingsGroup>
    </>
  );
}
