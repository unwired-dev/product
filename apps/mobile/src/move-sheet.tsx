import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  Animated,
  Keyboard,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Glass, Monogram, SFSymbol, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProviderName } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  sheetBackdrop: { justifyContent: 'flex-end' },
  sheet: {
    flex: 1,
    paddingHorizontal: spacing.l,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  caption: { ...textStyles.footnote, textAlign: 'center' },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  circle: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  cancel: {
    minWidth: 44,
    height: 44,
    paddingHorizontal: spacing.l - 2,
    borderRadius: 22,
    borderWidth: 2,
    justifyContent: 'center',
  },
  cancelLabel: { ...textStyles.body },
  hidden: { opacity: 0 },
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
    // The focus border counts toward the row's 12pt horizontal and 11pt vertical insets.
    paddingHorizontal: spacing.m - 2,
    paddingVertical: 11 - 2,
    borderWidth: 2,
    borderRadius: radius.card,
  },
  rowIcon: { width: 22, alignItems: 'center' },
  rowName: { ...textStyles.body, flex: 1 },
  count: { ...textStyles.body },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 46 },
});

// Each level of nesting indents a folder by one icon column.
const indent = 28;

// A folder Move to… lists: tray for the Inbox, archivebox for the archive, folder otherwise.
export type Destination = Readonly<{
  id: string;
  // The folder's names from its top-level ancestor down, as the provider nests them.
  path: readonly string[];
  icon: string;
  // The message's own folder, which it cannot move to again.
  current: boolean;
  // False for a folder the message cannot move to, such as a container holding only folders.
  selectable: boolean;
  // Unread mail this device already knows the folder holds.
  count?: number | undefined;
}>;
type Row = Destination & Readonly<{ name: string; depth: number }>;

const pathKey = (path: readonly string[]) => path.join('\u0000');
const pathName = (path: readonly string[]) => path.join(' / ');

// Destinations in tree order: each folder follows its nearest listed ancestor, one level deeper,
// and names the path below it; ancestors that are not listed stay part of its name.
const nest = (destinations: readonly Destination[]) => {
  const listed = new Set(destinations.map(({ path }) => pathKey(path)));
  const parentOf = (path: readonly string[]) => {
    for (let length = path.length - 1; length > 0; length -= 1) {
      if (listed.has(pathKey(path.slice(0, length)))) {
        return length;
      }
    }
    return 0;
  };
  const children = new Map<string, Destination[]>();
  for (const destination of destinations) {
    const ancestors = destination.path.slice(0, parentOf(destination.path));
    const parent = pathKey(ancestors);
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
      const below = destination.path.slice(parentOf(destination.path));
      rows.push({ ...destination, name: pathName(below), depth });
      visit(pathKey(destination.path), depth + 1);
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

// A round or pill control in the picker's header, ringed in the accent while it has focus.
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
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onFocus={() => {
        setFocused(true);
      }}
      onBlur={() => {
        setFocused(false);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        style,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.fillQuiet,
          borderColor: focused ? colors.accentInk : 'transparent',
        },
      ]}>
      {children}
    </Pressable>
  );
}

// A row of the picker, indented by its depth and ringed in the accent while it has focus.
function SheetRow({
  label,
  depth = 0,
  current = false,
  disabled = false,
  onPress,
  children,
}: {
  readonly label: string;
  readonly depth?: number;
  readonly current?: boolean;
  readonly disabled?: boolean;
  readonly onPress: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected: current }}
      disabled={disabled}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        {
          paddingLeft: styles.row.paddingHorizontal + indent * depth,
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
          borderColor: focused ? colors.accentInk : 'transparent',
        },
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
  onChoose,
}: {
  readonly row: Row;
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
      onPress={() => {
        onChoose(row.id);
      }}>
      <View style={styles.rowIcon}>
        <SFSymbol
          name={row.icon}
          size={18}
          color={unavailable ? colors.textSecondary : colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={1}
        style={[
          styles.rowName,
          { color: unavailable ? colors.textSecondary : colors.textPrimary },
        ]}>
        {row.name}
      </Text>
      {row.count === undefined ? null : (
        <Text style={[styles.count, { color: colors.textSecondary }]}>
          {row.count}
        </Text>
      )}
    </SheetRow>
  );
}

// iPhone's Move picker. It grows out of the Move button: the mailbox, the message, its folders
// nested as the provider lists them, with the current one and containers unavailable, and a
// search below them. Back lists the account, as mail moves only within it. Moving closes the
// picker, then moves once it has shrunk away.
export function MoveSheet({
  open,
  origin,
  message,
  destinations,
  empty,
  limited,
  onMove,
  onClose,
}: {
  readonly open: boolean;
  // Where the Move button was pressed, across the screen.
  readonly origin: number;
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
  const insets = useSafeAreaInsets();
  const { width, height } = useWindowDimensions();
  const [keyboardHeight, setKeyboardHeight] = useState(
    () => Keyboard.metrics()?.height ?? 0,
  );
  useEffect(() => {
    // Use the keyboard frame directly; measuring the resizing sheet can feed back into avoidance.
    const subscription = Keyboard.addListener(
      'keyboardWillChangeFrame',
      ({ endCoordinates }) => {
        setKeyboardHeight(
          endCoordinates.screenY >= height ? 0 : endCoordinates.height,
        );
      },
    );
    return () => {
      subscription.remove();
    };
  }, [height]);
  const motion = useMenuMotion(open, 'grow');
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
  const landscapeKeyboard = keyboardHeight > 0 && width > height;
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
    <Modal
      visible={motion.shown}
      transparent
      animationType="none"
      onRequestClose={onClose}
      // Moving closes the reader, which would cut the picker's exit short.
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
      }}
      supportedOrientations={[
        'portrait',
        'portrait-upside-down',
        'landscape-left',
        'landscape-right',
      ]}>
      <View
        accessibilityElementsHidden={!open}
        pointerEvents={open ? 'auto' : 'none'}
        style={[
          styles.sheetBackdrop,
          {
            height: Math.max(0, height - keyboardHeight),
            paddingTop: insets.top + spacing.s,
          },
        ]}>
        <Animated.View
          style={[
            StyleSheet.absoluteFill,
            { backgroundColor: colors.scrimTouch },
            motion.backdropStyle,
          ]}
        />
        <Pressable
          accessible={false}
          onPress={onClose}
          style={StyleSheet.absoluteFill}
        />
        <Animated.View
          accessibilityViewIsModal
          onAccessibilityEscape={onClose}
          testID="move-sheet"
          style={[
            styles.sheet,
            motion.style,
            {
              // Leave a full folder row visible in the short space above a landscape keyboard.
              gap: landscapeKeyboard ? 0 : spacing.m,
              paddingTop: landscapeKeyboard ? spacing.s : spacing.m,
              boxShadow: colors.menuGlassShadow,
              backgroundColor: colors.surfaceContent,
              // Above the keyboard the search needs no home-indicator inset.
              paddingBottom: keyboardHeight > 0 ? spacing.s : 34,
              // The picker grows out of where Move was pressed, at the bottom of the screen.
              // Keyboard activation reports no touch; grow from the middle then.
              transformOrigin: `${origin || width / 2}px 100%`,
            },
          ]}>
          <Glass
            cornerRadius={radius.sheet}
            style={StyleSheet.absoluteFill}
          />
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
              <Text style={[styles.caption, { color: colors.textSecondary }]}>
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
                  style={[styles.message, { borderColor: colors.separator }]}>
                  <Monogram name={message.sender} />
                  <View style={styles.messageText}>
                    <Text
                      numberOfLines={1}
                      style={[styles.sender, { color: colors.textPrimary }]}>
                      {message.sender}
                    </Text>
                    <Text
                      numberOfLines={1}
                      style={[styles.subject, { color: colors.textSecondary }]}>
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
                  : note(t('gmailActions.foldersLimited', { count: limited }))}
              </ScrollView>
              <View
                style={[styles.search, { backgroundColor: colors.fillQuiet }]}>
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
                  returnKeyType="search"
                  style={[styles.searchInput, { color: colors.textPrimary }]}
                  value={query}
                />
              </View>
            </>
          )}
        </Animated.View>
      </View>
    </Modal>
  );
}
