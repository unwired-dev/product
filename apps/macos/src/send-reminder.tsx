import type { SendReminder } from '@private-email/mail-core/send-reminders';

import {
  reminderCity,
  reminderDay,
  reminderTimes,
} from '@private-email/mail-core/send-reminders';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useRef } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button, ContextMenu, showMenu, useNow } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  banner: {
    gap: spacing.s,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  actions: { flexDirection: 'row', gap: spacing.s },
});

// `at` as `options`, with their time zone, name it in the person's language.
const formatAt = (
  locale: string,
  at: number,
  options: Intl.DateTimeFormatOptions,
) => new Intl.DateTimeFormat(locale, options).format(at);

// Opens the reminder menu from an anchor: its times from now in the Mac's time zone, then the note
// that a reminder never sends. Choosing a time calls `onRemind`.
function useReminderMenu(onRemind: (dueAt: number, timeZone: string) => void) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  return (anchor: View | null) => {
    const { timeZone } = Intl.DateTimeFormat().resolvedOptions();
    const time = (at: number) =>
      formatAt(settings.locale, at, {
        timeZone,
        hour: 'numeric',
        minute: '2-digit',
      });
    return showMenu(
      anchor,
      [
        {
          items: reminderTimes(Date.now(), timeZone).map(
            ({ time: choice, dueAt }) => ({
              key: choice,
              title: t(`drafts.reminder.${choice}`),
              subtitle:
                choice === 'thisEvening'
                  ? t('drafts.reminder.todayAt', { time: time(dueAt) })
                  : t('drafts.reminder.dayAt', {
                      day: formatAt(settings.locale, dueAt, {
                        timeZone,
                        weekday: 'short',
                      }),
                      time: time(dueAt),
                    }),
              symbol: '',
              run: () => {
                onRemind(dueAt, timeZone);
              },
            }),
          ),
        },
        {
          items: [
            {
              key: 'note',
              title: t('drafts.reminder.note'),
              symbol: '',
              disabled: true,
              run: () => undefined,
            },
          ],
        },
      ],
      colors.statusDestructive,
    );
  };
}

// Send: a click sends, and a right click opens the Send menu, whose Remind Me to Send… opens the
// reminder menu from Send.
export function SendMenu({
  disabled,
  onSend,
  onRemind,
}: {
  readonly disabled: boolean;
  readonly onSend: () => void;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
}) {
  const { t } = useLocalization();
  const anchor = useRef<View>(null);
  const openReminders = useReminderMenu(onRemind);
  return (
    <ContextMenu
      sections={[
        {
          items: [
            {
              key: 'send',
              title: t('drafts.send'),
              symbol: '',
              disabled,
              run: onSend,
            },
          ],
        },
        {
          items: [
            {
              key: 'remind',
              title: t('drafts.reminder.remindMeToSend'),
              symbol: '',
              disabled,
              run: () => openReminders(anchor.current),
            },
          ],
        },
      ]}>
      <View
        ref={anchor}
        collapsable={false}>
        <Button
          disabled={disabled}
          label={t('drafts.send')}
          fill="accent"
          onPress={onSend}
        />
      </View>
    </ContextMenu>
  );
}

// The Draft's own banner: when its reminder is due, with Change and Remove Reminder.
export function ReminderBanner({
  reminder,
  disabled,
  onRemind,
  onRemove,
}: {
  readonly reminder: SendReminder;
  readonly disabled: boolean;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onRemove: () => void;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  const change = useRef<View>(null);
  const openReminders = useReminderMenu(onRemind);
  const { dueAt, timeZone } = reminder;
  const when = {
    time: formatAt(settings.locale, dueAt, {
      timeZone,
      hour: '2-digit',
      minute: '2-digit',
    }),
    city: reminderCity(timeZone),
  };
  const now = useNow();
  const day = reminderDay(reminder, now);
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
  const note = t('drafts.reminder.note');
  return (
    <View style={[styles.banner, { backgroundColor: colors.fillQuiet }]}>
      {/* React Native macOS exposes plain Text to accessibility only through an accessible parent. */}
      <View
        accessible
        accessibilityLabel={`${message} ${note}`}
        accessibilityRole="text">
        <Text
          style={[textStyles.bodyEmphasized, { color: colors.textPrimary }]}>
          {message}
        </Text>
        <Text style={[textStyles.body, { color: colors.textSecondary }]}>
          {note}
        </Text>
      </View>
      <View style={styles.actions}>
        <View
          ref={change}
          collapsable={false}>
          <Button
            disabled={disabled}
            label={t('drafts.reminder.change')}
            onPress={() => {
              void openReminders(change.current);
            }}
          />
        </View>
        <Button
          disabled={disabled}
          label={t('drafts.reminder.remove')}
          onPress={onRemove}
        />
      </View>
    </View>
  );
}
