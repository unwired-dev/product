import type { SendReminder } from '@private-email/mail-core/send-reminders';
import type { ViewProps } from 'react-native';

import {
  reminderCity,
  reminderDay,
  reminderTimes,
} from '@private-email/mail-core/send-reminders';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useRef, useState } from 'react';
import { requireNativeComponent, StyleSheet, Text, View } from 'react-native';

import {
  AnnouncedAlert,
  Button,
  ContextMenu,
  Popover,
  SFSymbol,
  showMenu,
  useNow,
} from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

// AppKit's date picker: the graphical calendar choosing `value`'s day, or the time field and stepper
// choosing its hour and minute, on the clocks of `timeZone`. The calendar dims days before
// `minimum`'s; an earlier `value` shows, and takes a new time on, `minimum`'s day.
const DatePicker = requireNativeComponent<
  ViewProps & {
    readonly calendar: boolean;
    readonly value: number;
    readonly minimum?: number;
    readonly timeZone: string;
    readonly label?: string;
    readonly hint?: string;
    readonly onChange: (event: {
      readonly nativeEvent: { readonly value: number };
    }) => void;
  }
>('UnwiredDatePicker');

const styles = StyleSheet.create({
  banner: {
    gap: spacing.s,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  actions: { flexDirection: 'row', gap: spacing.s },
  // The #2831 popover: 14pt above its parts, 16pt beside and below them, 12pt between them.
  picker: {
    width: 280,
    gap: 12,
    paddingTop: 14,
    paddingHorizontal: spacing.l,
    paddingBottom: spacing.l,
  },
  line: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { fontWeight: '700' },
  // AppKit's calendar and time field keep their own size.
  calendar: { width: 139, height: 148, alignSelf: 'center' },
  timeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  timeLabel: { alignSelf: 'center' },
  // The time field keeps AppKit's width, which depends on the region, at this view's trailing edge.
  time: { width: 120, height: 24 },
  // The bell's slot, the header 8pt beside it.
  bell: { width: 13 },
  note: { flexDirection: 'row', alignItems: 'flex-start', gap: 6 },
  noteIcon: { width: 12, height: 14 },
  noteText: { flex: 1 },
  separator: { height: StyleSheet.hairlineWidth },
  buttons: { flexDirection: 'row', justifyContent: 'flex-end', gap: spacing.s },
});

// `at` as `options`, with their time zone, name it in the person's language.
const formatAt = (
  locale: string,
  at: number,
  options: Intl.DateTimeFormatOptions,
) => new Intl.DateTimeFormat(locale, options).format(at);

// Opens the reminder menu from an anchor: its times from now in the Mac's time zone and Choose Date
// and Time…, then the note that a reminder never sends. Choosing a time calls `onRemind`, and
// Choose Date and Time… `onChoose`.
function useReminderMenu(
  onRemind: (dueAt: number, timeZone: string) => void,
  onChoose: () => void,
) {
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
          items: [
            ...reminderTimes(Date.now(), timeZone).map(
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
            {
              key: 'choose',
              title: t('drafts.reminder.chooseDateAndTime'),
              symbol: '',
              run: onChoose,
            },
          ],
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

// Choose Date and Time…'s popover below its anchor, or above it unless `below`: AppKit's calendar and time field in the Mac's
// time zone, starting at `reminder`, otherwise tomorrow at Tomorrow Morning's time. Days before today
// are dimmed; a time that has passed says so and dims Set Reminder, which checks again when pressed.
// Set Reminder calls `onRemind` and closes; Cancel, Escape or a click outside keeps the reminder.
// `onClose` follows AppKit's close.
function ReminderPicker({
  below,
  reminder,
  onRemind,
  onClose,
}: {
  readonly below: boolean;
  readonly reminder: SendReminder | undefined;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onClose: () => void;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  const [shown, setShown] = useState(true);
  const { timeZone } = new Intl.DateTimeFormat().resolvedOptions();
  const [value, setValue] = useState(
    () =>
      reminder?.dueAt ??
      reminderTimes(Date.now(), timeZone).at(-1)?.dueAt ??
      Date.now(),
  );
  // When Set Reminder last found the time passed, so it says so before the minute turns.
  const [checked, setChecked] = useState(0);
  const now = Math.max(useNow(), checked);
  const passed = value <= now;
  const set = () => {
    const pressed = Date.now();
    if (value <= pressed) {
      setChecked(pressed);
      return;
    }
    setShown(false);
    onRemind(value, timeZone);
  };
  // The zone's long name is what naming it adds to the date: Hermes on Apple splits formatToParts at
  // every space, so its timeZoneName part is only the name's first word (#2147).
  const zoneName =
    formatAt(settings.locale, value, { timeZone, timeZoneName: 'long' })
      .replace(formatAt(settings.locale, value, { timeZone }), '')
      .replaceAll(/^[\s,،]+|[\s,،]+$/gu, '') || timeZone;
  const pastMessage = t('drafts.reminder.timePassed');
  const change = ({
    nativeEvent,
  }: {
    readonly nativeEvent: { readonly value: number };
  }) => {
    setValue(nativeEvent.value);
  };
  const primary = { color: colors.textPrimary };
  const secondary = { color: colors.textSecondary };
  return (
    <Popover
      below={below}
      title={t('drafts.reminder.title')}
      shown={shown}
      onClose={onClose}>
      <View style={styles.picker}>
        <View style={styles.line}>
          <SFSymbol
            name="bell"
            size={16}
            color={colors.textPrimary}
            style={styles.bell}
          />
          <Label
            accessibilityRole="header"
            style={[textStyles.bodyEmphasized, styles.title, primary]}>
            {t('drafts.reminder.title')}
          </Label>
        </View>
        <DatePicker
          calendar
          value={value}
          minimum={now}
          timeZone={timeZone}
          onChange={change}
          style={styles.calendar}
        />
        <View style={styles.timeRow}>
          <Label style={[textStyles.body, styles.timeLabel, primary]}>
            {t('drafts.reminder.time')}
          </Label>
          <DatePicker
            calendar={false}
            value={value}
            minimum={now}
            timeZone={timeZone}
            label={t('drafts.reminder.time')}
            hint={passed ? pastMessage : ''}
            onChange={change}
            style={styles.time}
          />
        </View>
        {passed ? (
          <View style={styles.note}>
            <SFSymbol
              name="exclamationmark.triangle.fill"
              size={14}
              color={colors.statusDestructive}
              style={styles.noteIcon}
            />
            <View style={styles.noteText}>
              <AnnouncedAlert
                style={[
                  textStyles.subheadline,
                  { color: colors.statusDestructive },
                ]}>
                {pastMessage}
              </AnnouncedAlert>
            </View>
          </View>
        ) : null}
        <View
          style={[styles.separator, { backgroundColor: colors.separator }]}
        />
        <View style={styles.note}>
          <SFSymbol
            name="clock"
            size={14}
            color={colors.textSecondary}
            style={styles.noteIcon}
          />
          <View style={styles.noteText}>
            <Label style={[textStyles.subheadline, secondary]}>
              {t('drafts.reminder.zone', {
                zone: zoneName,
                city: reminderCity(timeZone),
              })}
            </Label>
          </View>
        </View>
        <View style={styles.buttons}>
          <Button
            label={t('common.cancel')}
            onPress={() => {
              setShown(false);
            }}
          />
          <Button
            label={t('drafts.reminder.set')}
            fill="accent"
            isDefault
            disabled={passed}
            onPress={set}
          />
        </View>
      </View>
    </Popover>
  );
}

// Choose Date and Time…'s popovers from one anchor: each opening is its own popover, so the last
// one's close, arriving late, cannot close the next.
function useReminderPicker(
  below: boolean,
  reminder: SendReminder | undefined,
  onRemind: (dueAt: number, timeZone: string) => void,
) {
  const [opened, setOpened] = useState<number>();
  const open = () => {
    setOpened((last) => (last ?? 0) + 1);
  };
  const popover =
    opened === undefined ? null : (
      <ReminderPicker
        key={opened}
        below={below}
        reminder={reminder}
        onRemind={onRemind}
        onClose={() => {
          setOpened((last) => (last === opened ? undefined : last));
        }}
      />
    );
  return { open, popover };
}

// Send: a click sends, and a right click opens the Send menu. Its Send Now sends without the Undo
// Send Window, and Remind Me to Send… opens the reminder menu from Send. A Draft that cannot be
// sent yet can still get a reminder. Choose Date and Time… opens below Send when `below`, as in the
// toolbar, otherwise above it.
export function SendMenu({
  below,
  disabled,
  sendable,
  waiting,
  reminder,
  onSend,
  onSendNow,
  onRemind,
}: {
  readonly below: boolean;
  readonly disabled: boolean;
  readonly sendable: boolean;
  // The file Send Now waits for while it is still being added.
  readonly waiting: string | undefined;
  // The Draft's stored reminder, where Choose Date and Time… starts.
  readonly reminder: SendReminder | undefined;
  readonly onSend: () => void;
  readonly onSendNow: () => void;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
}) {
  const { t } = useLocalization();
  const anchor = useRef<View>(null);
  const picker = useReminderPicker(below, reminder, onRemind);
  const openReminders = useReminderMenu(onRemind, picker.open);
  return (
    <ContextMenu
      sections={[
        {
          items: [
            {
              key: 'send',
              title: t('drafts.send'),
              symbol: '',
              disabled: disabled || !sendable,
              run: onSend,
            },
            // While a file is still being added, Send is unavailable too.
            {
              key: 'sendNow',
              ...(waiting === undefined
                ? {
                    title: t('drafts.sendNow.title'),
                    subtitle: t('drafts.sendNow.detail'),
                  }
                : {
                    title: t('drafts.sendNow.waitingTitle', { name: waiting }),
                  }),
              symbol: '',
              disabled: disabled || !sendable,
              run: onSendNow,
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
          disabled={disabled || !sendable}
          label={t('drafts.send')}
          fill="accent"
          onPress={onSend}
        />
        {picker.popover}
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
  const picker = useReminderPicker(true, reminder, onRemind);
  const openReminders = useReminderMenu(onRemind, picker.open);
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
          {picker.popover}
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
