import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
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
    gap: spacing.m,
    paddingTop: spacing.m,
    paddingHorizontal: spacing.l,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  caption: { ...textStyles.footnote, textAlign: 'center' },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  close: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
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
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 46 },
});

// A folder Move to… offers: tray for the Inbox, archivebox for the archive, folder otherwise.
type Destination = Readonly<{
  id: string;
  name: string;
  icon: string;
  current: boolean;
}>;

// iPhone's Move picker for a mailbox whose messages live in one folder. It grows out of the Move
// button: the mailbox, the message, its folders with the current one unavailable, and a search
// below them. Moving closes it.
export function MoveSheet({
  open,
  origin,
  message,
  destinations,
  limited,
  onMove,
  onClose,
}: {
  readonly open: boolean;
  // Where the Move button was pressed, across the screen.
  readonly origin: number;
  readonly message: Readonly<{ sender: string; subject: string }>;
  readonly destinations: readonly Destination[];
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
  const [query, setQuery] = useState('');
  const [focused, setFocused] = useState<string>();
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setQuery('');
      setFocused(undefined);
    }
  }
  const needle = query.trim().toLocaleLowerCase();
  const shown = destinations.filter(({ name }) =>
    name.toLocaleLowerCase().includes(needle),
  );
  const note = (text: string) => (
    <Text style={[styles.note, { color: colors.textSecondary }]}>{text}</Text>
  );
  if (!motion.shown) {
    return null;
  }
  return (
    <Modal
      visible
      transparent
      animationType="none"
      onRequestClose={onClose}
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
              boxShadow: colors.menuGlassShadow,
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
          <Text style={[styles.caption, { color: colors.textSecondary }]}>
            {t('gmailActions.moveCaption')}
          </Text>
          <View style={styles.titleRow}>
            <View style={styles.close} />
            <Text
              accessibilityRole="header"
              numberOfLines={1}
              style={[styles.title, { color: colors.textPrimary }]}>
              {mailbox?.address ?? provider}
            </Text>
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={t('message.closeResponses')}
              onFocus={() => {
                setFocused('close');
              }}
              onBlur={() => {
                setFocused(undefined);
              }}
              onPress={onClose}
              style={({ pressed }) => [
                styles.close,
                {
                  backgroundColor: pressed
                    ? colors.accentSelectionSubtle
                    : colors.fillQuiet,
                  borderColor:
                    focused === 'close' ? colors.accentInk : 'transparent',
                },
              ]}>
              <SFSymbol
                name="xmark"
                color={colors.textPrimary}
              />
            </Pressable>
          </View>
          <ScrollView
            keyboardShouldPersistTaps="handled"
            style={styles.sheetList}>
            <View style={[styles.message, { borderColor: colors.separator }]}>
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
                  t(
                    destinations.length === 0
                      ? 'gmailActions.noFolders'
                      : 'gmailActions.noMatchingFolders',
                  ),
                )
              : shown.map((destination, index) => (
                  <View key={destination.id}>
                    {index === 0 ? null : (
                      <View
                        style={[
                          styles.separator,
                          { backgroundColor: colors.separator },
                        ]}
                      />
                    )}
                    <Pressable
                      accessibilityLabel={
                        destination.current
                          ? destination.name
                          : t('gmailActions.moveTo', {
                              label: destination.name,
                            })
                      }
                      accessibilityRole="button"
                      accessibilityState={{
                        disabled: destination.current,
                        selected: destination.current,
                      }}
                      disabled={destination.current}
                      focusable
                      onBlur={() => {
                        setFocused(undefined);
                      }}
                      onFocus={() => {
                        setFocused(destination.id);
                      }}
                      onPress={() => {
                        onMove(destination.id);
                      }}
                      style={({ pressed }) => [
                        styles.row,
                        {
                          backgroundColor: pressed
                            ? colors.accentSelectionSubtle
                            : 'transparent',
                          borderColor:
                            focused === destination.id
                              ? colors.accentInk
                              : 'transparent',
                        },
                      ]}>
                      <View style={styles.rowIcon}>
                        <SFSymbol
                          name={destination.icon}
                          size={18}
                          color={
                            destination.current
                              ? colors.textSecondary
                              : colors.textPrimary
                          }
                        />
                      </View>
                      <Text
                        numberOfLines={1}
                        style={[
                          styles.rowName,
                          {
                            color: destination.current
                              ? colors.textSecondary
                              : colors.textPrimary,
                          },
                        ]}>
                        {destination.name}
                      </Text>
                    </Pressable>
                  </View>
                ))}
            {shown.length > 0 && destinations.every(({ current }) => current)
              ? note(t('gmailActions.noFolders'))
              : null}
            {limited === undefined
              ? null
              : note(t('gmailActions.foldersLimited', { count: limited }))}
          </ScrollView>
          <View style={[styles.search, { backgroundColor: colors.fillQuiet }]}>
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
        </Animated.View>
      </View>
    </Modal>
  );
}
