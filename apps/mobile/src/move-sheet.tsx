import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

import { BottomSheet, Group, Host, RNHostView } from '@expo/ui/swift-ui';
import {
  presentationBackground,
  presentationDetents,
} from '@expo/ui/swift-ui/modifiers';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Monogram, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProviderName } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

// The iPad popover's width in the Move to Folder frame; it starts 20pt before the toolbar.
export const movePanelWidth = 322;
// Its glass corners, the frame's 13.8pt menu radius at the iPad's 1.15 scale.
export const movePanelRadius = 13.8 * ipadListScale;

// The popover's rows: 32.2pt, their contents 9.2pt apart, with the label 24.7pt after the icon.
const panelRowGap = 8 * ipadListScale;
// Rows other than the message's own folder keep the frame's unseen checkmark column before the icon.
const panelCheckWidth = 9.625 * ipadListScale;

const styles = StyleSheet.create({
  sheet: { flex: 1, paddingHorizontal: spacing.l },
  caption: { ...textStyles.footnote, textAlign: 'center' },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  circle: {
    width: 44,
    height: 44,
    borderRadius: 22,
    alignItems: 'center',
    justifyContent: 'center',
  },
  cancel: {
    minWidth: 44,
    height: 44,
    paddingHorizontal: spacing.l,
    borderRadius: 22,
    justifyContent: 'center',
  },
  cancelLabel: { ...textStyles.body },
  hidden: { opacity: 0 },
  unavailable: { opacity: 0.5 },
  message: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingBottom: spacing.m,
    marginBottom: spacing.m,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  messageText: { flex: 1 },
  sender: { ...textStyles.headline },
  subject: { ...textStyles.footnote },
  search: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    height: 44,
    paddingHorizontal: spacing.m,
    borderRadius: radius.searchField,
    borderCurve: 'continuous',
  },
  searchIcon: { width: spacing.xl, alignItems: 'center' },
  searchInput: { ...textStyles.body, flex: 1, minHeight: 44, padding: 0 },
  sheetList: { flex: 1 },
  note: { ...textStyles.footnote, paddingVertical: spacing.s },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 44,
    paddingHorizontal: spacing.m,
    paddingVertical: 11,
    borderRadius: radius.card,
  },
  rowIcon: { width: 22, alignItems: 'center' },
  rowName: { ...textStyles.body, flex: 1 },
  count: { ...textStyles.body },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 46 },
  // The iPad Move to Folder frame's popover: search, the account, then its folders, at the
  // Mac menu recipe scaled 1.15.
  panel: { width: movePanelWidth, padding: 6 * ipadListScale },
  panelSearch: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6 * ipadListScale,
    height: 28 * ipadListScale,
    paddingHorizontal: 8 * ipadListScale,
    borderRadius: 7 * ipadListScale,
    borderCurve: 'continuous',
  },
  panelSearchInput: { ...textStyles.subheadline, flex: 1, padding: 0 },
  panelCaption: {
    ...typography.ipadList.subheadline,
    fontWeight: '600',
    minHeight: 22.8 * ipadListScale,
    paddingLeft: 10 * ipadListScale,
    paddingTop: 6 * ipadListScale,
    paddingBottom: 2 * ipadListScale,
  },
  panelList: { maxHeight: 360, flexGrow: 0 },
  panelRow: {
    gap: panelRowGap,
    minHeight: 28 * ipadListScale,
    paddingVertical: 6 * ipadListScale,
    paddingHorizontal: 10 * ipadListScale,
    borderRadius: radius.row,
  },
  panelCheck: { width: panelCheckWidth },
  panelIcon: {
    width: 21.485 * ipadListScale - panelRowGap,
    alignItems: 'center',
  },
  panelName: { ...typography.ipadList.body, flex: 1 },
  panelCount: { ...typography.ipadList.body },
});

// Each level of nesting indents a folder by one icon column.
const indent = 28;

// A folder Move to… lists: tray for the Inbox, archivebox for the archive, folder otherwise.
export type Destination = Readonly<{
  id: string;
  // The folder's names from its top-level ancestor down, as the provider nests them.
  path: readonly string[];
  // Keeps the system Inbox and its descendants apart from equally named user folders.
  inboxPath: boolean;
  icon: string;
  // The message's own folder, which it cannot move to again.
  current: boolean;
  // False for a folder the message cannot move to, such as a container holding only folders.
  selectable: boolean;
  // Unread mail this device already knows the folder holds.
  count?: number | undefined;
}>;
type Row = Destination & Readonly<{ name: string; depth: number }>;

const pathKey = (path: readonly string[], inboxPath: boolean) =>
  path.length === 0 ? '' : `${inboxPath}\u0000${path.join('\u0000')}`;
const pathName = (path: readonly string[]) => path.join(' / ');

// Destinations in tree order: each folder follows its nearest listed ancestor, one level deeper,
// and names the path below it; ancestors that are not listed stay part of its name.
const nest = (destinations: readonly Destination[]) => {
  const listed = new Set(
    destinations.map(({ path, inboxPath }) => pathKey(path, inboxPath)),
  );
  const parentOf = ({ path, inboxPath }: Destination) => {
    for (let length = path.length - 1; length > 0; length -= 1) {
      if (listed.has(pathKey(path.slice(0, length), inboxPath))) {
        return length;
      }
    }
    return 0;
  };
  const children = new Map<string, Destination[]>();
  for (const destination of destinations) {
    const ancestors = destination.path.slice(0, parentOf(destination));
    const parent = pathKey(ancestors, destination.inboxPath);
    const siblings = children.get(parent);
    if (siblings === undefined) {
      children.set(parent, [destination]);
    } else {
      siblings.push(destination);
    }
  }
  const rows: Row[] = [];
  const visit = (parent: string, depth: number) => {
    const level = children.get(parent) ?? [];
    // A path listed twice is shown once.
    children.delete(parent);
    for (const destination of level) {
      const below = destination.path.slice(parentOf(destination));
      rows.push({ ...destination, name: pathName(below), depth });
      visit(pathKey(destination.path, destination.inboxPath), depth + 1);
    }
  };
  visit('', 0);
  return rows;
};

// The picker's rows: every destination nested, or for a search, those that can hold mail by
// their full path.
const rowsFor = (
  destinations: readonly Destination[],
  needle: string,
): readonly Row[] =>
  needle === ''
    ? nest(destinations)
    : destinations
        .filter(
          ({ path, selectable }) =>
            selectable && pathName(path).toLocaleLowerCase().includes(needle),
        )
        .map((destination) => ({
          ...destination,
          name: pathName(destination.path),
          depth: 0,
        }));

// A round or pill control in the picker's header.
function SheetButton({
  label,
  style,
  onPress,
  children,
}: {
  readonly label?: string;
  readonly style: StyleProp<ViewStyle>;
  readonly onPress: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      style={({ pressed }) => [
        style,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.fillQuiet,
        },
      ]}>
      {children}
    </Pressable>
  );
}

// A row of the picker, indented by its depth.
function SheetRow({
  label,
  depth = 0,
  current = false,
  disabled = false,
  dense = false,
  onPress,
  children,
}: {
  readonly label: string;
  readonly depth?: number;
  readonly current?: boolean;
  readonly disabled?: boolean;
  // The iPad popover's 32pt rows.
  readonly dense?: boolean;
  readonly onPress: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const row = dense ? [styles.row, styles.panelRow] : styles.row;
  const inset = dense
    ? styles.panelRow.paddingHorizontal
    : styles.row.paddingHorizontal;
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected: current }}
      disabled={disabled}
      focusable
      onPress={onPress}
      style={({ pressed }) => [
        row,
        {
          paddingLeft: inset + indent * depth,
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
        },
        // iPhone's sheet dims what cannot be chosen, its count included.
        disabled && !dense && styles.unavailable,
      ]}>
      {children}
    </Pressable>
  );
}

// The picker's Back page: the account whose folders it lists, as mail moves only within it.
function AccountPage({
  account,
  onFolders,
  onCancel,
}: {
  readonly account: string;
  readonly onFolders: () => void;
  readonly onCancel: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      <View style={styles.titleRow}>
        {/* An unseen copy of Cancel keeps the title centred. */}
        <View
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          style={[styles.cancel, styles.hidden]}>
          <Text style={styles.cancelLabel}>{t('common.cancel')}</Text>
        </View>
        <Text
          accessibilityRole="header"
          numberOfLines={1}
          style={[styles.title, { color: colors.textPrimary }]}>
          {t('settings.sections.accounts')}
        </Text>
        <SheetButton
          style={styles.cancel}
          onPress={onCancel}>
          <Text style={[styles.cancelLabel, { color: colors.textPrimary }]}>
            {t('common.cancel')}
          </Text>
        </SheetButton>
      </View>
      <ScrollView style={styles.sheetList}>
        <SheetRow
          label={account}
          onPress={onFolders}>
          <Text
            numberOfLines={1}
            style={[styles.rowName, { color: colors.textPrimary }]}>
            {account}
          </Text>
          <SFSymbol
            name="chevron.right"
            size={14}
            color={colors.textSecondary}
          />
        </SheetRow>
      </ScrollView>
    </>
  );
}

// A destination: its symbol in the accent, or secondary with its name when it cannot be chosen.
function DestinationRow({
  row,
  dense = false,
  onChoose,
}: {
  readonly row: Row;
  readonly dense?: boolean;
  readonly onChoose: (id: string) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const unavailable = row.current || !row.selectable;
  const path = pathName(row.path);
  return (
    <SheetRow
      label={unavailable ? path : t('gmailActions.moveTo', { label: path })}
      depth={row.depth}
      current={row.current}
      disabled={unavailable}
      dense={dense}
      onPress={() => {
        onChoose(row.id);
      }}>
      {/* The message's own folder takes the checkmark column's place, as the frame selects it. */}
      {dense && !row.current ? <View style={styles.panelCheck} /> : null}
      <View style={dense ? styles.panelIcon : styles.rowIcon}>
        <SFSymbol
          name={row.icon}
          size={dense ? 15 : 18}
          color={unavailable || dense ? colors.textSecondary : colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={1}
        style={[
          dense ? styles.panelName : styles.rowName,
          { color: unavailable ? colors.textSecondary : colors.textPrimary },
        ]}>
        {row.name}
      </Text>
      {row.count === undefined ? null : (
        <Text
          style={[
            dense ? styles.panelCount : styles.count,
            { color: colors.textSecondary },
          ]}>
          {row.count}
        </Text>
      )}
    </SheetRow>
  );
}

// iPhone's Move picker, a system sheet: the mailbox, the message, its folders nested as the
// provider lists them, with the current one and containers unavailable, and a search below them.
// Back lists the account, as mail moves only within it. Moving closes the picker, then moves once
// it has finished dismissing.
export function MoveSheet({
  open,
  message,
  destinations,
  empty,
  limited,
  onMove,
  onClose,
}: {
  readonly open: boolean;
  readonly message: Readonly<{ sender: string; subject: string }>;
  readonly destinations: readonly Destination[];
  // Shown when no destination can be chosen.
  readonly empty?: string | undefined;
  // Microsoft lists only its first folders; IMAP lists all of them.
  readonly limited: number | undefined;
  readonly onMove: (id: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = useProviderName();
  const { width, height } = useWindowDimensions();
  const { bottom } = useSafeAreaInsets();
  const pending = useRef<
    Readonly<{ message: typeof message; id: string }> | undefined
  >(undefined);
  const owner = useRef<typeof message | undefined>(undefined);
  useLayoutEffect(() => {
    owner.current = message;
    return () => {
      owner.current = undefined;
      pending.current = undefined;
    };
  }, [message]);
  // The sheet keeps itself above the keyboard; searching in landscape leaves it little height.
  const [searching, setSearching] = useState(false);
  const landscapeKeyboard = searching && width > height;
  const [query, setQuery] = useState('');
  const [accounts, setAccounts] = useState(false);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setQuery('');
      setAccounts(false);
    }
  }
  const needle = query.trim().toLocaleLowerCase();
  const shown = rowsFor(destinations, needle);
  const choose = (id: string) => {
    if (!open || owner.current !== message || pending.current !== undefined) {
      return;
    }
    pending.current = { message, id };
    onClose();
  };
  const account = mailbox?.address ?? provider;
  const note = (text: string) => (
    <Text style={[styles.note, { color: colors.textSecondary }]}>{text}</Text>
  );
  const nothingToChoose = destinations.every(
    ({ current, selectable }) => current || !selectable,
  );
  return (
    <Host matchContents>
      <BottomSheet
        isPresented={open}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            onClose();
          }
        }}
        // Moving closes the reader, which would cut the sheet's dismissal short.
        onDismiss={() => {
          const selected = pending.current;
          pending.current = undefined;
          if (
            !open &&
            owner.current === message &&
            selected?.message === message
          ) {
            onMove(selected.id);
          }
        }}>
        <Group
          modifiers={[
            // In portrait the frames leave 70pt above the sheet, a little more than large does. A
            // custom detent's height leaves out the bottom safe area, which the sheet adds.
            presentationDetents(
              height > width ? [{ height: height - 70 - bottom }] : ['large'],
            ),
            // The frames draw the sheet as the glass panel surface.
            presentationBackground(colors.surfacePanel),
          ]}>
          <RNHostView>
            <View
              testID="move-sheet"
              style={[
                styles.sheet,
                {
                  // Leave a full folder row visible in the short space above a landscape keyboard.
                  gap: landscapeKeyboard ? 0 : spacing.m,
                  paddingTop: landscapeKeyboard ? spacing.s : spacing.m,
                  // The sheet already insets the home indicator; keep a gap only above the keyboard.
                  paddingBottom: searching ? spacing.s : 0,
                },
              ]}>
              {accounts ? (
                <AccountPage
                  account={account}
                  onFolders={() => {
                    setAccounts(false);
                  }}
                  onCancel={onClose}
                />
              ) : (
                <>
                  <Text
                    style={[styles.caption, { color: colors.textSecondary }]}>
                    {t('gmailActions.moveCaption')}
                  </Text>
                  <View style={styles.titleRow}>
                    <SheetButton
                      label={t('message.back')}
                      style={styles.circle}
                      onPress={() => {
                        setAccounts(true);
                      }}>
                      <SFSymbol
                        name="chevron.left"
                        color={colors.textPrimary}
                      />
                    </SheetButton>
                    <Text
                      accessibilityRole="header"
                      numberOfLines={1}
                      style={[styles.title, { color: colors.textPrimary }]}>
                      {account}
                    </Text>
                    <SheetButton
                      label={t('message.closeResponses')}
                      style={styles.circle}
                      onPress={onClose}>
                      <SFSymbol
                        name="xmark"
                        color={colors.textPrimary}
                      />
                    </SheetButton>
                  </View>
                  <ScrollView
                    keyboardShouldPersistTaps={
                      landscapeKeyboard ? 'always' : 'handled'
                    }
                    style={styles.sheetList}>
                    <View
                      style={[
                        styles.message,
                        { borderColor: colors.separator },
                      ]}>
                      <Monogram name={message.sender} />
                      <View style={styles.messageText}>
                        <Text
                          numberOfLines={1}
                          style={[
                            styles.sender,
                            { color: colors.textPrimary },
                          ]}>
                          {message.sender}
                        </Text>
                        <Text
                          numberOfLines={1}
                          style={[
                            styles.subject,
                            { color: colors.textSecondary },
                          ]}>
                          {message.subject}
                        </Text>
                      </View>
                    </View>
                    {shown.length === 0
                      ? note(
                          needle === '' && empty !== undefined
                            ? empty
                            : t('gmailActions.noMatchingFolders'),
                        )
                      : shown.map((row, index) => (
                          <View key={row.id}>
                            {index === 0 ? null : (
                              <View
                                style={[
                                  styles.separator,
                                  {
                                    marginLeft:
                                      styles.separator.marginLeft +
                                      indent * row.depth,
                                    backgroundColor: colors.separator,
                                  },
                                ]}
                              />
                            )}
                            <DestinationRow
                              row={row}
                              onChoose={choose}
                            />
                          </View>
                        ))}
                    {empty !== undefined && shown.length > 0 && nothingToChoose
                      ? note(empty)
                      : null}
                    {limited === undefined
                      ? null
                      : note(
                          t('gmailActions.foldersLimited', { count: limited }),
                        )}
                  </ScrollView>
                  <View
                    style={[
                      styles.search,
                      { backgroundColor: colors.fillQuiet },
                    ]}>
                    <View style={styles.searchIcon}>
                      <SFSymbol
                        name="magnifyingglass"
                        color={colors.textSecondary}
                      />
                    </View>
                    <TextInput
                      accessibilityLabel={t('search.title')}
                      autoCapitalize="none"
                      autoCorrect={false}
                      clearButtonMode="while-editing"
                      onChangeText={setQuery}
                      placeholder={t('search.title')}
                      placeholderTextColor={colors.textSecondary}
                      onFocus={() => {
                        setSearching(true);
                      }}
                      onBlur={() => {
                        setSearching(false);
                      }}
                      returnKeyType="search"
                      style={[
                        styles.searchInput,
                        { color: colors.textPrimary },
                      ]}
                      value={query}
                    />
                  </View>
                </>
              )}
            </View>
          </RNHostView>
        </Group>
      </BottomSheet>
    </Host>
  );
}

// iPad's Move picker, the popover beneath the reader toolbar's Move: a search over the folders,
// the account they belong to, and its folders nested as the provider lists them, with the current
// one and containers unavailable.
export function MovePanel({
  open,
  destinations,
  empty,
  limited,
  onMove,
}: {
  readonly open: boolean;
  readonly message: Readonly<{ sender: string; subject: string }>;
  readonly destinations: readonly Destination[];
  readonly empty?: string | undefined;
  readonly limited: number | undefined;
  readonly onMove: (id: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = useProviderName();
  const [query, setQuery] = useState('');
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setQuery('');
    }
  }
  const needle = query.trim().toLocaleLowerCase();
  const shown = rowsFor(destinations, needle);
  const note = (text: string) => (
    <Text style={[styles.note, { color: colors.textSecondary }]}>{text}</Text>
  );
  const nothingToChoose = destinations.every(
    ({ current, selectable }) => current || !selectable,
  );
  return (
    <View
      testID="move-panel"
      style={styles.panel}>
      <View style={[styles.panelSearch, { backgroundColor: colors.fillQuiet }]}>
        <SFSymbol
          name="magnifyingglass"
          size={13}
          color={colors.textSecondary}
        />
        <TextInput
          accessibilityLabel={t('contextMenu.moveTo')}
          autoCapitalize="none"
          autoCorrect={false}
          clearButtonMode="while-editing"
          onChangeText={setQuery}
          placeholder={t('contextMenu.moveTo')}
          placeholderTextColor={colors.textSecondary}
          returnKeyType="search"
          style={[styles.panelSearchInput, { color: colors.textPrimary }]}
          value={query}
        />
      </View>
      <Text
        accessibilityRole="header"
        numberOfLines={1}
        style={[styles.panelCaption, { color: colors.textSecondary }]}>
        {mailbox === undefined ? provider : `${provider} · ${mailbox.address}`}
      </Text>
      <ScrollView
        keyboardShouldPersistTaps="handled"
        style={styles.panelList}>
        {shown.length === 0
          ? note(
              needle === '' && empty !== undefined
                ? empty
                : t('gmailActions.noMatchingFolders'),
            )
          : shown.map((row) => (
              <DestinationRow
                key={row.id}
                row={row}
                dense
                onChoose={onMove}
              />
            ))}
        {empty !== undefined && shown.length > 0 && nothingToChoose
          ? note(empty)
          : null}
        {limited === undefined
          ? null
          : note(t('gmailActions.foldersLimited', { count: limited }))}
      </ScrollView>
    </View>
  );
}
