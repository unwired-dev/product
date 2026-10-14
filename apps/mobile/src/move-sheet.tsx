import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useState } from 'react';
import {
  Keyboard,
  Animated,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';

import { Glass, SFSymbol, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProviderName } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  sheetBackdrop: { justifyContent: 'flex-end' },
  // shortcut: a fixed home-indicator inset; read the safe area if a sheet ever opens without one.
  sheet: {
    maxHeight: '85%',
    gap: 14,
    paddingTop: 10,
    paddingHorizontal: spacing.l,
    paddingBottom: 34,
    borderTopLeftRadius: radius.sheet,
    borderTopRightRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  grabber: { alignSelf: 'center', width: 36, height: 5, borderRadius: 3 },
  sheetTitle: { ...textStyles.headline, textAlign: 'center', paddingTop: 4 },
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
  sheetList: { flexGrow: 0 },
  section: { gap: 6 },
  sectionHeader: {
    ...textStyles.footnote,
    paddingTop: 4,
    paddingHorizontal: spacing.l,
  },
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
    // The focus border counts toward the frame's 16pt horizontal and 13pt vertical insets.
    paddingHorizontal: spacing.l - 2,
    paddingVertical: 13 - 2,
    borderWidth: 2,
    borderRadius: radius.insetGroup,
  },
  rowIcon: { width: 22, alignItems: 'center' },
  rowName: { ...textStyles.body, flex: 1 },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 50 },
});

// A folder Move to… offers: tray for the Inbox, archivebox for the archive, folder otherwise.
type Destination = Readonly<{
  id: string;
  name: string;
  icon: string;
  current: boolean;
}>;

// iPhone's Move to… sheet for a mailbox whose messages live in one folder: its folders, the
// message's current one checked, narrowed by a search. Moving closes it.
export function MoveSheet({
  open,
  destinations,
  limited,
  onMove,
  onClose,
}: {
  readonly open: boolean;
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
  const { height } = useWindowDimensions();
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
  const motion = useMenuMotion(open, 'sheet');
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
    <Text style={[styles.sectionHeader, { color: colors.textSecondary }]}>
      {text}
    </Text>
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
            { boxShadow: colors.menuGlassShadow },
          ]}>
          <Glass
            cornerRadius={radius.sheet}
            style={StyleSheet.absoluteFill}
          />
          <View
            style={[styles.grabber, { backgroundColor: colors.textSecondary }]}
          />
          <Text
            accessibilityRole="header"
            style={[styles.sheetTitle, { color: colors.textPrimary }]}>
            {t('gmailActions.moveToTitle')}
          </Text>
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
          <ScrollView
            keyboardShouldPersistTaps="handled"
            style={styles.sheetList}>
            <View style={styles.section}>
              {note(
                mailbox === undefined
                  ? provider
                  : t('gmailActions.connection', {
                      provider,
                      address: mailbox.address,
                    }),
              )}
              {shown.length === 0 ? (
                note(
                  t(
                    destinations.length === 0
                      ? 'gmailActions.noFolders'
                      : 'gmailActions.noMatchingFolders',
                  ),
                )
              ) : (
                <View
                  style={[
                    styles.group,
                    { backgroundColor: colors.surfaceContent },
                  ]}>
                  {shown.map((destination, index) => (
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
                        {destination.current ? (
                          <SFSymbol
                            name="checkmark"
                            color={colors.accentInk}
                          />
                        ) : null}
                      </Pressable>
                    </View>
                  ))}
                </View>
              )}
              {shown.length > 0 && destinations.every(({ current }) => current)
                ? note(t('gmailActions.noFolders'))
                : null}
              {limited === undefined
                ? null
                : note(
                    t('gmailActions.foldersLimited', {
                      count: limited,
                    }),
                  )}
            </View>
          </ScrollView>
        </Animated.View>
      </View>
    </Modal>
  );
}
