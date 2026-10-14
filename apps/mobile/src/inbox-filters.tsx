import type { Translate } from '@private-email/localization';
import type { InboxFilter } from '@private-email/mail-core/mailboxes';
import type { ReactNode } from 'react';

import { filterMessages } from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { Fragment, useMemo, useState } from 'react';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';

import { Glass, SFSymbol } from './design.tsx';
import { FilterControl } from './inbox-bar.tsx';
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

const styles = StyleSheet.create({
  backdrop: { flex: 1, justifyContent: 'flex-end' },
  // shortcut: a fixed home-indicator inset, as Move to… uses; read the safe area if a sheet ever opens without one.
  sheet: {
    maxHeight: '85%',
    gap: spacing.l,
    paddingTop: spacing.m,
    paddingHorizontal: spacing.l,
    paddingBottom: 34,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  header: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: { ...textStyles.headline },
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
  sections: { gap: spacing.l },
  section: { gap: 6 },
  sectionHeader: { ...textStyles.footnote, paddingHorizontal: spacing.l },
  group: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 48,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.s,
  },
  rowIcon: { width: 22, alignItems: 'center' },
  rowName: { ...textStyles.body, flex: 1 },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 50 },
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

// The Filters sheet edits a copy of the filter; the checkmark applies it, and leaving discards it.
function FiltersSheet({
  filter,
  connections,
  onConfirm,
  onClose,
}: {
  readonly filter: InboxFilter;
  // The unified Inbox's connections, which it offers to leave out; none in any other view.
  readonly connections: Connections;
  readonly onConfirm: (filter: InboxFilter) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
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
      animationType="fade"
      onRequestClose={onClose}
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}>
      <View style={[styles.backdrop, { backgroundColor: colors.scrimTouch }]}>
        <Pressable
          accessible={false}
          onPress={onClose}
          style={StyleSheet.absoluteFill}
        />
        <View
          accessibilityViewIsModal
          onAccessibilityEscape={onClose}
          testID="filters-sheet"
          style={[styles.sheet, { boxShadow: colors.menuGlassShadow }]}>
          <Glass
            cornerRadius={radius.sheet}
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
              style={({ pressed }) => [
                styles.confirm,
                {
                  backgroundColor: pressed
                    ? colors.accentInk
                    : colors.accentFill,
                },
              ]}>
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
        </View>
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
  const rows = useMemo(
    () => (on ? filterMessages(listed, { filter, connections, now }) : listed),
    [on, filter, connections, listed, now],
  );
  return {
    filter,
    setFilter,
    on,
    setOn,
    connections,
    rows,
    // The filter, not an empty mailbox, leaves the list empty.
    hidesAll: on && listed.length > 0 && rows.length === 0,
  };
}

// The bar's filter switch and summary, and the Filters sheet the summary opens.
export function InboxFilterButton({
  state: { filter, setFilter, on, setOn, connections },
}: {
  readonly state: Pick<
    ReturnType<typeof useInboxFilter>,
    'filter' | 'setFilter' | 'on' | 'setOn' | 'connections'
  >;
}) {
  const { t } = useLocalization();
  const [open, setOpen] = useState(false);
  return (
    <>
      <FilterControl
        label={on ? filterLabel(t, filter, connections) : undefined}
        onOpen={() => {
          setOpen(true);
        }}
        onToggle={() => {
          // A filter left with nothing to narrow starts again from Unread.
          if (!on && !narrows(filter, connections)) {
            setFilter(defaultFilter);
          }
          setOn(!on);
        }}
      />
      {open ? (
        <FiltersSheet
          connections={connections}
          filter={filter}
          onClose={() => {
            setOpen(false);
          }}
          onConfirm={(next) => {
            setFilter(next);
            setOpen(false);
            // Applying nothing to narrow by turns the filter off.
            setOn(narrows(next, connections));
          }}
        />
      ) : null}
    </>
  );
}
