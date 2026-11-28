import { messageZooms } from '@private-email/mail-core/message-body';
import { Switch } from 'react-native';

import { PopUp } from './composer-controls.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import {
  setFitWideMessages,
  setMessageZoom,
  useFitWideMessages,
  useMessageZoom,
} from './reading.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

// Settings › Reading: app text follows macOS; received formatted mail zooms, and fits the reader's
// width, on this Mac.
export function ReadingSettings() {
  const { t } = useLocalization();
  const colors = usePalette();
  const zoom = useMessageZoom();
  const fit = useFitWideMessages();
  const percent = (value: number) => t('reading.percent', { value });
  return (
    <>
      <SettingsGroup title={t('reading.appText')}>
        <SettingsRow title={t('reading.textSize')}>
          <Label style={[textStyles.body, { color: colors.textSecondary }]}>
            {t('reading.followsSystem', { context: 'mac' })}
          </Label>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup
        title={t('reading.received')}
        footer={t('reading.footer', { context: 'mac' })}>
        <SettingsRow title={t('reading.zoom', { context: 'mac' })}>
          <PopUp
            accessibilityLabel={t('reading.zoom', { context: 'mac' })}
            variant="inline"
            label={percent(zoom)}
            items={messageZooms.map((each) => ({
              key: String(each),
              title: percent(each),
              checked: each === zoom,
              run: () => {
                setMessageZoom(each);
              },
            }))}
          />
        </SettingsRow>
        <SettingsRow title={t('reading.fitWide', { context: 'mac' })}>
          <Switch
            accessibilityLabel={t('reading.fitWide', { context: 'mac' })}
            value={fit}
            trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
            onValueChange={setFitWideMessages}
          />
        </SettingsRow>
      </SettingsGroup>
    </>
  );
}
