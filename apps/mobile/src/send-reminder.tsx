import type { SendReminder } from '@private-email/mail-core/send-reminders';
import type { ReactElement } from 'react';

import {
  BottomSheet,
  Group,
  Host,
  Popover,
  RNHostView,
  Button as SwiftUIButton,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  presentationDetents,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  reminderCity,
  reminderDay,
  reminderTimes,
} from '@private-email/mail-core/send-reminders';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, ContextMenu, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useNow } from './mailbox-state.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  banner: {
    gap: spacing.s,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  choices: { gap: spacing.m, padding: spacing.l },
  popover: { width: 320 },
  header: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { ...textStyles.headline },
  sheetTitle: { ...textStyles.headline, textAlign: 'center' },
  group: { borderRadius: radius.card, borderCurve: 'continuous' },
  row: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  rowText: { flex: 1 },
  zone: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  buttons: { flexDirection: 'row', justifyContent: 'flex-end', gap: spacing.s },
});

// `at` as `options`, with their time zone, name it in the person's language.
const formatAt = (
  locale: string,
  at: number,
  options: Intl.DateTimeFormatOptions,
) => new Intl.DateTimeFormat(locale, options).format(at);

// The reminder choices from now in the device's time zone, under the note that a reminder never
// sends. In the iPad popover a choice is selected and Set Reminder sets it; on iPhone a row sets it.
function ReminderChoices({
  popover,
  onRemind,
  onClose,
}: {
  readonly popover: boolean;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onClose: () => void;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  // oxlint-disable-next-line react/hook-use-state -- One presentation keeps the times it opened with.
  const [{ timeZone, times }] = useState(() => {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    return { timeZone: zone, times: reminderTimes(Date.now(), zone) };
  });
  const [selected, setSelected] = useState(times.at(-1)?.dueAt);
  const time = (at: number) =>
    formatAt(settings.locale, at, {
      timeZone,
      hour: 'numeric',
      minute: '2-digit',
    });
  const zoneName =
    new Intl.DateTimeFormat(settings.locale, { timeZone, timeZoneName: 'long' })
      .formatToParts(selected)
      .find(({ type }) => type === 'timeZoneName')?.value ?? timeZone;
  const choose = (dueAt: number) => {
    onClose();
    onRemind(dueAt, timeZone);
  };
  const rows = times.map(({ time: choice, dueAt }) => {
    const title = t(`drafts.reminder.${choice}`);
    const today = choice === 'thisEvening';
    // iPad names the day and date beneath the choice; iPhone shows the time beside it.
    let when = time(dueAt);
    if (popover && today) {
      when = t('drafts.reminder.todayAt', { time: when });
    } else if (popover) {
      when = t('drafts.reminder.dateAt', {
        date: formatAt(settings.locale, dueAt, {
          timeZone,
          weekday: 'short',
          day: 'numeric',
          month: 'short',
        }),
        time: when,
      });
    } else if (!today) {
      when = t('drafts.reminder.dayAt', {
        day: formatAt(settings.locale, dueAt, { timeZone, weekday: 'short' }),
        time: when,
      });
    }
    const checked = selected === dueAt;
    let symbol = 'clock';
    if (popover) {
      symbol = checked ? 'largecircle.fill.circle' : 'circle';
    }
    return (
      <Pressable
        key={choice}
        accessibilityLabel={`${title}, ${when}`}
        accessibilityRole={popover ? 'radio' : 'button'}
        accessibilityState={popover ? { checked } : undefined}
        onPress={() => {
          if (popover) {
            setSelected(dueAt);
          } else {
            choose(dueAt);
          }
        }}
        style={({ pressed }) => [
          styles.row,
          {
            backgroundColor:
              pressed || (popover && checked)
                ? colors.accentSelectionSubtle
                : 'transparent',
          },
        ]}>
        <SFSymbol
          name={symbol}
          color={colors.textPrimary}
        />
        <View style={styles.rowText}>
          <Text style={[textStyles.body, { color: colors.textPrimary }]}>
            {title}
          </Text>
          {popover ? (
            <Text
              style={[textStyles.footnote, { color: colors.textSecondary }]}>
              {when}
            </Text>
          ) : null}
        </View>
        {popover ? null : (
          <Text style={[textStyles.body, { color: colors.textSecondary }]}>
            {when}
          </Text>
        )}
      </Pressable>
    );
  });
  return (
    <View style={[styles.choices, popover && styles.popover]}>
      <View style={styles.header}>
        {popover ? (
          <SFSymbol
            name="bell"
            color={colors.textPrimary}
          />
        ) : null}
        <Text
          accessibilityRole="header"
          style={[
            popover ? styles.title : styles.sheetTitle,
            styles.rowText,
            { color: colors.textPrimary },
          ]}>
          {t('drafts.reminder.title')}
        </Text>
      </View>
      <Text style={[textStyles.footnote, { color: colors.textSecondary }]}>
        {t('drafts.reminder.explanation')}
      </Text>
      <View
        style={[
          styles.group,
          popover ? null : { backgroundColor: colors.surfaceContent },
        ]}>
        {rows}
      </View>
      <View style={styles.zone}>
        <SFSymbol
          name="clock"
          size={12}
          color={colors.textSecondary}
        />
        <Text style={[textStyles.footnote, { color: colors.textSecondary }]}>
          {t('drafts.reminder.zone', {
            zone: zoneName,
            city: reminderCity(timeZone),
          })}
        </Text>
      </View>
      {popover ? (
        <View style={styles.buttons}>
          <Host matchContents>
            <SwiftUIButton
              label={t('common.cancel')}
              onPress={onClose}
              modifiers={[
                buttonStyle('bordered'),
                buttonBorderShape('capsule'),
              ]}
            />
          </Host>
          <Host matchContents>
            <SwiftUIButton
              label={t('drafts.reminder.set')}
              onPress={() => {
                if (selected !== undefined) {
                  choose(selected);
                }
              }}
              modifiers={[
                buttonStyle('borderedProminent'),
                buttonBorderShape('capsule'),
                tint(colors.accentFill),
              ]}
            />
          </Host>
        </View>
      ) : null}
    </View>
  );
}

// Presents the reminder choices while `open`: a popover from `trigger` on iPad, a sheet on iPhone.
function ReminderPicker({
  open,
  popover,
  trigger,
  onRemind,
  onClose,
}: {
  readonly open: boolean;
  readonly popover: boolean;
  readonly trigger: ReactElement;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onClose: () => void;
}) {
  const dismiss = (presented: boolean) => {
    if (!presented) {
      onClose();
    }
  };
  // Each presentation offers the times from when it opened.
  const choices = open ? (
    <ReminderChoices
      popover={popover}
      onRemind={onRemind}
      onClose={onClose}
    />
  ) : null;
  return popover ? (
    <Host matchContents>
      <Popover
        arrowEdge="top"
        isPresented={open}
        onIsPresentedChange={dismiss}>
        <Popover.Trigger>
          <RNHostView matchContents>{trigger}</RNHostView>
        </Popover.Trigger>
        <Popover.Content>
          <RNHostView matchContents>{choices ?? <View />}</RNHostView>
        </Popover.Content>
      </Popover>
    </Host>
  ) : (
    <>
      {trigger}
      <Host matchContents>
        <BottomSheet
          isPresented={open}
          onIsPresentedChange={dismiss}>
          <Group modifiers={[presentationDetents(['medium'])]}>
            <RNHostView>{choices ?? <View />}</RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
  );
}

// Send's menu, which a long press opens: Remind Me to Send… opens the reminder choices from Send.
// A tap still sends.
export function SendMenu({
  popover,
  disabled,
  onRemind,
  children,
}: {
  readonly popover: boolean;
  readonly disabled: boolean;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  // The Send button.
  readonly children: ReactElement;
}) {
  const { t } = useLocalization();
  const [open, setOpen] = useState(false);
  return (
    <ReminderPicker
      open={open}
      popover={popover}
      onRemind={onRemind}
      onClose={() => {
        setOpen(false);
      }}
      trigger={
        <ContextMenu
          previewRadius={popover ? radius.control : 22}
          sections={[
            {
              items: [
                {
                  key: 'remind',
                  title: t('drafts.reminder.remindMeToSend'),
                  subtitle: t('drafts.reminder.detail'),
                  symbol: 'bell',
                  disabled,
                  run: () => {
                    setOpen(true);
                  },
                },
              ],
            },
          ]}>
          {children}
        </ContextMenu>
      }
    />
  );
}

// The Draft's own banner: when its reminder is due, with Change and Remove Reminder.
export function ReminderBanner({
  reminder,
  popover,
  disabled,
  onRemind,
  onRemove,
}: {
  readonly reminder: SendReminder;
  readonly popover: boolean;
  readonly disabled: boolean;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onRemove: () => void;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  const [open, setOpen] = useState(false);
  const { dueAt, timeZone } = reminder;
  const when = {
    time: formatAt(settings.locale, dueAt, {
      timeZone,
      hour: '2-digit',
      minute: '2-digit',
    }),
    city: reminderCity(timeZone),
  };
  const day = reminderDay(reminder, useNow());
  let message = t('drafts.reminder.on', {
    ...when,
    date: formatAt(settings.locale, dueAt, {
      timeZone,
      weekday: 'short',
      day: 'numeric',
      month: 'short',
    }),
  });
  if (day === 0) {
    message = t('drafts.reminder.today', when);
  } else if (day === 1) {
    message = t('drafts.reminder.tomorrow', when);
  }
  return (
    <View style={[styles.banner, { backgroundColor: colors.fillQuiet }]}>
      <View accessible>
        <Text style={[textStyles.subheadline, { color: colors.textPrimary }]}>
          {message}
        </Text>
        <Text style={[textStyles.footnote, { color: colors.textSecondary }]}>
          {t('drafts.reminder.note')}
        </Text>
      </View>
      <View style={styles.actions}>
        <ReminderPicker
          open={open}
          popover={popover}
          onRemind={onRemind}
          onClose={() => {
            setOpen(false);
          }}
          trigger={
            <Button
              size="compact"
              disabled={disabled}
              label={t('drafts.reminder.change')}
              onPress={() => {
                setOpen(true);
              }}
            />
          }
        />
        <Button
          size="compact"
          disabled={disabled}
          label={t('drafts.reminder.remove')}
          onPress={onRemove}
        />
      </View>
    </View>
  );
}
