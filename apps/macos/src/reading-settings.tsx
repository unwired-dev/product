import type { MailProfile } from '@private-email/mail-core/registration';

import { messageZooms } from '@private-email/mail-core/message-body';

import { PopUp } from './composer-controls.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { MarkReadSettings } from './mark-read.tsx';
import { setMessageZoom, useMessageZoom } from './reading.ts';
import { SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

// Settings › Reading: app text follows macOS; received formatted mail zooms on this Mac; each of
// `profiles` chooses when opening a message marks it read.
export function ReadingSettings({
  profiles,
}: {
  // The Mail Profiles besides the Default Profile.
  readonly profiles: readonly MailProfile[];
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const zoom = useMessageZoom();
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
      </SettingsGroup>
      <MarkReadSettings profiles={profiles} />
    </>
  );
}
