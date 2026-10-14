import type { Translate } from '@private-email/localization';
import type { InboxFilter } from '@private-email/mail-core/mailboxes';
import type { ReactNode } from 'react';

import { filterMessages } from '@private-email/mail-core/mailboxes';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import {
  Fragment,
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import Animated, { FadeIn, ReduceMotion } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Glass, SFSymbol } from './design.tsx';
import { FilterControl, WindowBarContext } from './inbox-bar.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const defaultFilter: InboxFilter = {
  excluded: new Set(),
  unread: true,
  today: false,
};

type Filtered = Parameters<typeof filterMessages>[0][number];
type Shown = Readonly<{ id: string; address?: string | undefined }>;

type Connections = ReadonlyArray<Readonly<{ id: string; address: string }>>;

const criteria = (
  t: Translate,
  { excluded, unread, today }: InboxFilter,
  connections: Connections,
) => {
  const included = connections.filter(({ id }) => !excluded.has(id));
  const [only] = included;
  return [
    ...(unread ? [t('filters.unread')] : []),
    ...(today ? [t('filters.today')] : []),
    ...(included.length === connections.length
      ? []
      : [
          included.length === 1 && only !== undefined
            ? only.address
            : t('filters.mailboxes', { count: included.length }),
        ]),
  ];
};

// Whether a filter leaves anything out.
const narrows = (filter: InboxFilter, connections: Connections) =>
  filter.unread ||
  filter.today ||
  connections.some(({ id }) => filter.excluded.has(id));

// The bar's summary of an applied filter: its one criterion, or how many apply.
const filterLabel = (
  t: Translate,
  filter: InboxFilter,
  connections: Connections,
) => {
  const applied = criteria(t, filter, connections);
  const [only] = applied;
  if (applied.length === 0 || only === undefined) {
    return t('filters.none');
  }
  return applied.length === 1
    ? only
    : t('filters.several', { count: applied.length });
};

// The Filter control's top leading corner in the window, which iPad's popover grows from.
type Anchor = Readonly<{ x: number; y: number }>;

const popoverWidth = 420;
const popoverEntry = FadeIn.reduceMotion(ReduceMotion.System);

const styles = StyleSheet.create({
  backdrop: { flex: 1, justifyContent: 'flex-end' },
  // shortcut: a fixed home-indicator inset, as Move to… uses; read the safe area if a sheet ever opens without one.
  sheet: {
    flex: 1,
    gap: spacing.l,
    paddingTop: spacing.m,
    paddingHorizontal: ipad ? spacing.m * 2 : spacing.l,
    paddingBottom: 34,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  popover: {
    position: 'absolute',
    width: popoverWidth,
    gap: spacing.s,
    paddingTop: spacing.m,
    paddingHorizontal: spacing.l,
    paddingBottom: spacing.l,
    borderRadius: radius.popover,
    borderCurve: 'continuous',
  },
  header: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    ...(ipad ? typography.ipadList.title3Emphasized : textStyles.headline),
  },
  confirm: {
    position: 'absolute',
    right: 0,
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
  },
  list: { flexGrow: 0 },
  sections: { gap: ipad ? spacing.s : spacing.l },
  section: { gap: ipad ? spacing.s : 6 },
  sectionHeader: {
    ...(ipad ? typography.ipadList.body : textStyles.footnote),
    fontWeight: '600',
    paddingTop: ipad ? spacing.s : 0,
    paddingHorizontal: ipad ? 14 : spacing.l,
  },
  group: {
    overflow: 'hidden',
    borderRadius: ipad ? radius.card : radius.insetGroup,
    borderCurve: 'continuous',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 48,
    paddingHorizontal: ipad ? 14 : spacing.l,
    paddingVertical: ipad ? spacing.m : spacing.s,
  },
  rowIcon: { width: 22, alignItems: 'center' },
  rowName: {
    ...(ipad
      ? { ...typography.ipadList.title3Emphasized, fontWeight: '400' }
      : textStyles.body),
    flex: 1,
  },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: ipad ? 0 : 50 },
});

function RowLabel({
  icon,
  label,
}: {
  readonly icon: string;
  readonly label: string;
}) {
  const colors = usePalette();
  return (
    <>
      <View style={styles.rowIcon}>
        <SFSymbol
          name={icon}
          size={18}
          color={colors.accentInk}
        />
      </View>
      <Text style={[styles.rowName, { color: colors.textPrimary }]}>
        {label}
      </Text>
    </>
  );
}

// A criterion chosen among others, checked by a trailing checkmark.
function CheckRow({
  icon,
  label,
  checked,
  onChange,
}: {
  readonly icon: string;
  readonly label: string;
  readonly checked: boolean;
  readonly onChange: (checked: boolean) => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="checkbox"
      accessibilityState={{ checked }}
      onPress={() => {
        onChange(!checked);
      }}
      style={({ pressed }) => [
        styles.row,
        pressed && { backgroundColor: colors.accentSelectionSubtle },
      ]}>
      <RowLabel
        icon={icon}
        label={label}
      />
      {checked ? (
        <SFSymbol
          name="checkmark"
          color={colors.accentInk}
        />
      ) : null}
    </Pressable>
  );
}

// An "Only …" restriction, switched on or off.
function SwitchRow({
  icon,
  label,
  value,
  onChange,
}: {
  readonly icon: string;
  readonly label: string;
  readonly value: boolean;
  readonly onChange: (value: boolean) => void;
}) {
  const colors = usePalette();
  return (
    <View style={styles.row}>
      <RowLabel
        icon={icon}
        label={label}
      />
      <Switch
        accessibilityLabel={label}
        onValueChange={onChange}
        thumbColor={colors.accentOnFill}
        trackColor={{ false: colors.fillTrack, true: colors.accentFill }}
        value={value}
      />
    </View>
  );
}

// The hairline between two rows of a group.
function Separator() {
  const colors = usePalette();
  return (
    <View style={[styles.separator, { backgroundColor: colors.separator }]} />
  );
}

// An inset group of rows under an optional header.
function Section({
  title,
  children,
}: {
  readonly title?: string;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={styles.section}>
      {title === undefined ? null : (
        <Text
          accessibilityRole="header"
          style={[styles.sectionHeader, { color: colors.textSecondary }]}>
          {title}
        </Text>
      )}
      <View style={[styles.group, { backgroundColor: colors.fillQuiet }]}>
        {children}
      </View>
    </View>
  );
}

// Filters edits a copy of the filter; the checkmark applies it, and leaving discards it. It opens as
// a full-height sheet, or on a regular-width iPad window as a popover above the Filter control.
function Filters({
  filter,
  connections,
  anchor,
  onConfirm,
  onClose,
}: {
  readonly filter: InboxFilter;
  // The unified Inbox's connections, which it offers to leave out; none in any other view.
  readonly connections: Connections;
  // Where the popover grows from; a sheet has none.
  readonly anchor: Anchor | undefined;
  readonly onConfirm: (filter: InboxFilter) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dimensions = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const [edited, setEdited] = useState(filter);
  const include = (id: string, included: boolean) => {
    setEdited((current) => {
      const excluded = new Set(current.excluded);
      if (included) {
        excluded.delete(id);
      } else {
        excluded.add(id);
      }
      return { ...current, excluded };
    });
  };
  return (
    <Modal
      visible
      transparent
      animationType={anchor === undefined ? 'fade' : 'none'}
      onRequestClose={onClose}
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}>
      <View
        style={[
          styles.backdrop,
          anchor === undefined && { backgroundColor: colors.scrimTouch },
        ]}>
        <Pressable
          accessible={false}
          onPress={onClose}
          style={StyleSheet.absoluteFill}
        />
        <Animated.View
          {...(anchor === undefined ? {} : { entering: popoverEntry })}
          accessibilityViewIsModal
          onAccessibilityEscape={onClose}
          testID={anchor === undefined ? 'filters-sheet' : 'filters-popover'}
          style={[
            anchor === undefined
              ? [
                  styles.sheet,
                  // The sheet rises to just beneath the status bar, as the iPhone frames show.
                  { marginTop: Math.max(0, insets.top - spacing.s) },
                ]
              : [
                  styles.popover,
                  {
                    left: Math.min(
                      anchor.x,
                      dimensions.width - popoverWidth - spacing.l,
                    ),
                    bottom: dimensions.height - anchor.y + spacing.s,
                    maxHeight: anchor.y - spacing.s - insets.top - spacing.l,
                  },
                ],
            { boxShadow: colors.menuGlassShadow },
          ]}>
          <Glass
            cornerRadius={anchor === undefined ? radius.sheet : radius.popover}
            style={StyleSheet.absoluteFill}
          />
          <View style={styles.header}>
            <Text
              accessibilityRole="header"
              style={[styles.title, { color: colors.textPrimary }]}>
              {t('filters.title')}
            </Text>
            <Pressable
              accessibilityLabel={t('filters.apply')}
              accessibilityRole="button"
              onPress={() => {
                onConfirm(edited);
              }}
              style={[styles.confirm, { backgroundColor: colors.accentFill }]}>
              <SFSymbol
                name="checkmark"
                size={18}
                color={colors.accentOnFill}
              />
            </Pressable>
          </View>
          <ScrollView style={styles.list}>
            <View style={styles.sections}>
              {connections.length > 1 ? (
                <Section title={t('filters.includeFrom')}>
                  {connections.map(({ id, address }, index) => (
                    <Fragment key={id}>
                      {index === 0 ? null : <Separator />}
                      <CheckRow
                        icon="tray"
                        label={address}
                        checked={!edited.excluded.has(id)}
                        onChange={(included) => {
                          include(id, included);
                        }}
                      />
                    </Fragment>
                  ))}
                </Section>
              ) : null}
              <Section title={t('filters.include')}>
                <CheckRow
                  icon="envelope.badge"
                  label={t('filters.unread')}
                  checked={edited.unread}
                  onChange={(unread) => {
                    setEdited((current) => ({ ...current, unread }));
                  }}
                />
              </Section>
              <Section>
                <SwitchRow
                  icon="calendar"
                  label={t('filters.onlyToday')}
                  value={edited.today}
                  onChange={(today) => {
                    setEdited((current) => ({ ...current, today }));
                  }}
                />
              </Section>
            </View>
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}

// The Inbox's filter: whether it applies, what it keeps, and the listed rows it leaves.
export function useInboxFilter<M extends Filtered>({
  scope,
  mailboxes,
  listed,
  now,
}: Readonly<{
  scope: string | undefined;
  mailboxes: readonly Shown[];
  listed: readonly M[];
  now: number;
}>) {
  const [filter, setFilter] = useState(defaultFilter);
  const [on, setOn] = useState(false);
  // The unified Inbox offers to leave connections out; the filter keeps them in any other view.
  const connections = useMemo(
    () =>
      scope === undefined && mailboxes.length > 1
        ? mailboxes.map(({ id, address }) => ({ id, address: address ?? id }))
        : [],
    [scope, mailboxes],
  );
  // A filter is off once it leaves nothing out here, as when a view drops the connections it excluded.
  const active = on && narrows(filter, connections);
  const rows = useMemo(
    () =>
      active ? filterMessages(listed, { filter, connections, now }) : listed,
    [active, filter, connections, listed, now],
  );
  return {
    filter,
    setFilter,
    on: active,
    setOn,
    connections,
    rows,
    // The filter, not an empty mailbox, leaves the list empty.
    hidesAll: active && listed.length > 0 && rows.length === 0,
  };
}

// The bar's filter switch and summary, and the Filters the summary opens: a popover when the bar
// spans a regular-width window, otherwise a sheet.
export function InboxFilterButton({
  state: { filter, setFilter, on, setOn, connections },
}: {
  readonly state: Pick<
    ReturnType<typeof useInboxFilter>,
    'filter' | 'setFilter' | 'on' | 'setOn' | 'connections'
  >;
}) {
  const { t } = useLocalization();
  const popover = use(WindowBarContext) !== undefined;
  const control = useRef<View>(null);
  const { width, height } = useWindowDimensions();
  const [open, setOpen] = useState<
    Readonly<{ anchor: Anchor | undefined }> | undefined
  >();
  useLayoutEffect(() => {
    if (!popover) {
      return;
    }
    let current = true;
    control.current?.measureInWindow((x, y) => {
      if (current) {
        setOpen((opened) =>
          opened === undefined ? opened : { anchor: { x, y } },
        );
      }
    });
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react/exhaustive-effect-dependencies -- A window resize invalidates the native anchor measurement.
  }, [popover, width, height]);
  return (
    <>
      <FilterControl
        label={on ? filterLabel(t, filter, connections) : undefined}
        onOpen={() => {
          if (!popover) {
            setOpen({ anchor: undefined });
            return;
          }
          control.current?.measureInWindow((x, y) => {
            setOpen({ anchor: { x, y } });
          });
        }}
        ref={control}
        onToggle={() => {
          // A filter left with nothing to narrow starts again from Unread.
          if (!on && !narrows(filter, connections)) {
            setFilter(defaultFilter);
          }
          setOn(!on);
        }}
      />
      {open === undefined ? null : (
        <Filters
          anchor={open.anchor}
          connections={connections}
          filter={filter}
          onClose={() => {
            setOpen(undefined);
          }}
          onConfirm={(next) => {
            setFilter(next);
            setOpen(undefined);
            // Applying nothing to narrow by turns the filter off.
            setOn(narrows(next, connections));
          }}
        />
      )}
    </>
  );
}
