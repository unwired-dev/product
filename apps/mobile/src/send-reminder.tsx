import type { SendReminder } from '@private-email/mail-core/send-reminders';
import type { ReactElement } from 'react';

import {
  BottomSheet,
  DatePicker,
  Group,
  Host,
  Popover,
  RNHostView,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  datePickerStyle,
  font,
  frame,
  disabled as inactive,
  labelStyle,
  labelsHidden,
  presentationDetents,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  mobileReminderTimes,
  reminderCity,
  reminderDay,
} from '@private-email/mail-core/send-reminders';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
import {
  AccessibilityInfo,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

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
  // The sheet's empty host stays out of the trigger's row, whose gap would move the trigger.
  sheetHost: { position: 'absolute' },
  // The frame's width, which keeps the time zone line on one line (#2147).
  popover: { width: 359 },
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
  pickerHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
  },
  passed: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
});

// `at` as `options`, with their time zone, name it in the person's language.
const formatAt = (
  locale: string,
  at: number | undefined,
  options: Intl.DateTimeFormatOptions,
) => new Intl.DateTimeFormat(locale, options).format(at);

// Choose Date and Time…: the system's calendar and time from `start`, in the device's time zone,
// then the zone line and Set Reminder. Days before today can't be chosen, and Set Reminder waits
// for a time that has not passed, checking again when pressed. Back returns to the times.
function ReminderDateTime({
  popover,
  start,
  zone,
  onBack,
  onSet,
  onClose,
}: {
  readonly popover: boolean;
  readonly start: number;
  readonly zone: (at: number) => ReactElement;
  readonly onBack: () => void;
  readonly onSet: (dueAt: number) => void;
  readonly onClose: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const [at, setAt] = useState(start);
  // The latest instant Set Reminder found passed, so a time that passed while open shows it.
  const [checked, setChecked] = useState(0);
  const passed = at <= Math.max(useNow(), checked);
  // oxlint-disable-next-line react/hook-use-state -- One picker keeps the day it opened on.
  const [today] = useState(() => new Date(new Date().setHours(0, 0, 0, 0)));
  useEffect(() => {
    if (passed) {
      AccessibilityInfo.announceForAccessibility(t('drafts.reminder.passed'));
    }
  }, [passed, t]);
  const set = () => {
    const now = Date.now();
    if (at <= now) {
      setChecked(now);
    } else {
      onSet(at);
    }
  };
  const setLabel = (
    <SwiftUIText
      modifiers={[
        font({ textStyle: 'headline' }),
        ...(popover ? [] : [frame({ maxWidth: Infinity })]),
      ]}>
      {t('drafts.reminder.set')}
    </SwiftUIText>
  );
  return (
    <>
      <View style={styles.pickerHeader}>
        <Host matchContents>
          <SwiftUIButton
            label={t('message.back')}
            systemImage="chevron.left"
            onPress={onBack}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('glass'),
              buttonBorderShape('circle'),
              controlSize(popover ? 'small' : 'large'),
              tint(colors.textPrimary),
            ]}
          />
        </Host>
        <Text
          accessibilityRole="header"
          style={[
            popover ? styles.title : styles.sheetTitle,
            styles.rowText,
            { color: colors.textPrimary },
          ]}>
          {t('drafts.reminder.title')}
        </Text>
        {/* Balances Back, so the iPhone title stays centred. */}
        {popover ? null : <View style={{ width: 44 }} />}
      </View>
      <Host matchContents={{ vertical: true }}>
        <DatePicker
          title={t('drafts.reminder.title')}
          selection={new Date(at)}
          range={{ start: today }}
          displayedComponents={['date', 'hourAndMinute']}
          onDateChange={(date) => {
            setAt(date.getTime());
          }}
          modifiers={[
            datePickerStyle('graphical'),
            labelsHidden(),
            tint(colors.accentFill),
          ]}
        />
      </Host>
      {passed ? (
        <View style={styles.passed}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            size={12}
            color={colors.statusDestructive}
          />
          <Text
            style={[textStyles.footnote, { color: colors.statusDestructive }]}>
            {t('drafts.reminder.passed')}
          </Text>
        </View>
      ) : null}
      {zone(at)}
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
              onPress={set}
              modifiers={[
                buttonStyle('borderedProminent'),
                buttonBorderShape('capsule'),
                tint(colors.accentFill),
                inactive(passed),
              ]}>
              {setLabel}
            </SwiftUIButton>
          </Host>
        </View>
      ) : (
        <Host matchContents={{ vertical: true }}>
          <SwiftUIButton
            onPress={set}
            modifiers={[
              buttonStyle('borderedProminent'),
              buttonBorderShape('capsule'),
              controlSize('large'),
              tint(colors.accentFill),
              inactive(passed),
            ]}>
            {setLabel}
          </SwiftUIButton>
        </Host>
      )}
    </>
  );
}

// The reminder choices from now in the device's time zone, under the note that a reminder never
// sends. In the iPad popover a choice is selected and Set Reminder sets it; on iPhone a row sets it.
// Choose Date and Time… shows the picker in their place, starting at the `stored` reminder or
// Tomorrow Morning.
function ReminderChoices({
  popover,
  stored,
  picking,
  onPicking,
  onRemind,
  onClose,
}: {
  readonly popover: boolean;
  readonly stored: number | undefined;
  readonly picking: boolean;
  readonly onPicking: (picking: boolean) => void;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onClose: () => void;
}) {
  const { t, settings } = useLocalization();
  const colors = usePalette();
  // oxlint-disable-next-line react/hook-use-state -- One presentation keeps the times it opened with.
  const [{ opened, timeZone, times }] = useState(() => {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const at = Date.now();
    return {
      opened: at,
      timeZone: zone,
      times: mobileReminderTimes(at, zone, !popover),
    };
  });
  const tomorrow = times.find(({ time }) => time === 'tomorrowMorning')?.dueAt;
  const [selected, setSelected] = useState(tomorrow);
  const time = (at: number) =>
    formatAt(settings.locale, at, {
      timeZone,
      hour: 'numeric',
      minute: '2-digit',
    });
  // The zone's long name is what naming it adds to the date: Hermes on Apple splits formatToParts at
  // every space, so its timeZoneName part is only the name's first word (#2147).
  const zoneName = (at: number | undefined) =>
    formatAt(settings.locale, at, { timeZone, timeZoneName: 'long' })
      .replace(formatAt(settings.locale, at, { timeZone }), '')
      .replaceAll(/^[\s,،]+|[\s,،]+$/gu, '') || timeZone;
  const zone = (at: number | undefined) => (
    <View style={styles.zone}>
      <SFSymbol
        name="clock"
        size={12}
        color={colors.textSecondary}
      />
      <Text style={[textStyles.footnote, { color: colors.textSecondary }]}>
        {t('drafts.reminder.zone', {
          zone: zoneName(at),
          city: reminderCity(timeZone),
        })}
      </Text>
    </View>
  );
  const choose = (dueAt: number) => {
    onClose();
    onRemind(dueAt, timeZone);
  };
  if (picking) {
    return (
      <View style={[styles.choices, popover && styles.popover]}>
        <ReminderDateTime
          popover={popover}
          start={stored ?? tomorrow ?? opened}
          zone={zone}
          onBack={() => {
            onPicking(false);
          }}
          onSet={choose}
          onClose={onClose}
        />
      </View>
    );
  }
  const rows = times.map(({ time: choice, dueAt }) => {
    const title = t(`drafts.reminder.${choice}`);
    const today = choice === 'thisEvening';
    const date = formatAt(settings.locale, dueAt, {
      timeZone,
      weekday: 'short',
      day: 'numeric',
      month: 'short',
    });
    // iPad names the day and date beneath the choice; iPhone shows the time beside it, and Next
    // Week's date.
    let when = time(dueAt);
    if (popover && today) {
      when = t('drafts.reminder.todayAt', { time: when });
    } else if (popover) {
      when = t('drafts.reminder.dateAt', { date, time: when });
    } else if (choice === 'nextWeek') {
      when = date;
    } else if (!today) {
      when = t('drafts.reminder.dayAt', {
        day: formatAt(settings.locale, dueAt, { timeZone, weekday: 'short' }),
        time: when,
      });
    }
    const checked = selected === dueAt;
    let symbol = 'clock';
    if (choice === 'thisWeekend' || choice === 'nextWeek') {
      symbol = 'calendar';
    }
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
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            onPicking(true);
          }}
          style={({ pressed }) => [
            styles.row,
            {
              backgroundColor: pressed
                ? colors.accentSelectionSubtle
                : 'transparent',
            },
          ]}>
          <SFSymbol
            name="calendar.badge.clock"
            color={colors.textPrimary}
          />
          <Text
            style={[
              textStyles.body,
              styles.rowText,
              { color: colors.textPrimary },
            ]}>
            {t('drafts.reminder.chooseDateAndTime')}
          </Text>
        </Pressable>
      </View>
      {zone(selected)}
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
// Choose Date and Time… shows the picker in the same presentation; the iPhone sheet grows to fit it,
// scrolling at larger text sizes.
function ReminderPicker({
  open,
  popover,
  stored,
  trigger,
  onRemind,
  onClose,
}: {
  readonly open: boolean;
  readonly popover: boolean;
  readonly stored: number | undefined;
  readonly trigger: ReactElement;
  readonly onRemind: (dueAt: number, timeZone: string) => void;
  readonly onClose: () => void;
}) {
  const [picking, setPicking] = useState(false);
  // The picker's height, which the iPhone sheet grows to.
  const [height, setHeight] = useState<{ height: number }>();
  const close = () => {
    setPicking(false);
    onClose();
  };
  const dismiss = (presented: boolean) => {
    if (!presented) {
      close();
    }
  };
  // Each presentation offers the times from when it opened.
  let choices = open ? (
    <ReminderChoices
      popover={popover}
      stored={stored}
      picking={picking}
      onPicking={setPicking}
      onRemind={onRemind}
      onClose={close}
    />
  ) : null;
  if (picking && !popover) {
    choices = (
      <ScrollView
        onContentSizeChange={(_, contentHeight) => {
          setHeight({ height: contentHeight });
        }}>
        {choices}
      </ScrollView>
    );
  }
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
      <Host
        matchContents
        style={styles.sheetHost}>
        <BottomSheet
          isPresented={open}
          onIsPresentedChange={dismiss}>
          <Group
            modifiers={[
              presentationDetents([picking ? (height ?? 'large') : 'medium']),
            ]}>
            <RNHostView>{choices ?? <View />}</RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
  );
}

// Send's menu, which a long press opens: Send Now sends without the Undo Send Window, and Remind Me
// to Send… opens the reminder choices from Send. A tap still sends.
export function SendMenu({
  popover,
  stored,
  disabled,
  sendNow,
  onSendNow,
  onRemind,
  children,
}: {
  readonly popover: boolean;
  // When the Draft's reminder is due, where Choose Date and Time… starts.
  readonly stored: number | undefined;
  readonly disabled: boolean;
  // Whether Send Now is unavailable, and the file it waits for while one is still being added.
  readonly sendNow: Readonly<{
    disabled: boolean;
    waiting: string | undefined;
  }>;
  readonly onSendNow: () => void;
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
      stored={stored}
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
                  key: 'sendNow',
                  title: t('drafts.sendNow.title'),
                  subtitle:
                    sendNow.waiting === undefined
                      ? t('drafts.sendNow.detail')
                      : t('drafts.sendNow.waiting', { name: sendNow.waiting }),
                  symbol: '',
                  disabled: sendNow.disabled,
                  run: onSendNow,
                },
              ],
            },
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
          stored={dueAt}
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
