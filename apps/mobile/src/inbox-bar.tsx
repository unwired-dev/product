import type { ReactNode, RefObject } from 'react';

import { composeCommand } from '@private-email/mail-core/commands';
import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import { use, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { RegisterCommands, usePaletteHeader } from './command-palette.tsx';
import { GlassGroup, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useProfile,
} from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  newMessage: {
    width: 48,
    height: 48,
    alignItems: 'center',
    justifyContent: 'center',
  },
  search: { ...textStyles.body, flex: 1, minHeight: 48 },
  round: { padding: 0, borderRadius: 24, backgroundColor: 'transparent' },
  filtered: {
    flexShrink: 1,
    flexWrap: 'nowrap',
    alignItems: 'center',
    padding: 0,
    paddingRight: spacing.l,
    borderRadius: 24,
    backgroundColor: 'transparent',
  },
  filterIcon: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
  },
  filteredBy: { flexShrink: 1, minHeight: 48, justifyContent: 'center' },
  filteredByCaption: { ...textStyles.caption1, fontWeight: '600' },
  filteredByValue: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
  filteredByLabel: { ...textStyles.caption1, flexShrink: 1 },
  spacer: { flex: 1 },
  scrollEdge: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: 72,
  },
  bottomBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    padding: spacing.l,
  },
  searchBar: {
    flex: 1,
    alignSelf: 'stretch',
    flexWrap: 'nowrap',
    alignItems: 'center',
    gap: spacing.s,
    paddingLeft: spacing.m,
    paddingRight: spacing.s,
    paddingVertical: 0,
    borderRadius: 24,
    backgroundColor: 'transparent',
  },
});

// The New Message control of the floating search bar.
export function NewMessageButton({
  onCompose,
  scope,
}: {
  readonly onCompose: (id: string) => void;
  // The mailbox the Inbox shows, which a new message sends from when it can.
  readonly scope: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const account = use(AccountContext);
  const store = useDraftStore();
  const state = useDrafts();
  const navigation = useComposerNavigation();
  const windowProfile = useProfile();
  const creating = useRef(false);
  const [creatingShown, setCreatingShown] = useState(false);
  if (account === undefined || state.kind === 'closed') {
    return null;
  }
  // The unified Inbox sends from the window's Profile.
  const senders = sendingMailboxes(
    account.mailboxes,
    scope === undefined ? windowProfile : profileOf(scope, account.mailboxes),
  );
  // One shown mailbox sends only from itself; every mailbox sends from the first usable one.
  const sender =
    scope === undefined ? senders[0] : senders.find(({ id }) => id === scope);
  const disabled =
    state.kind !== 'ready' || sender === undefined || creatingShown;
  const compose = async () => {
    if (creating.current || sender === undefined) {
      return;
    }
    creating.current = true;
    setCreatingShown(true);
    // Leaving and creating resolve rather than reject, so the press always settles here.
    const id = await navigation.create(store, sender);
    creating.current = false;
    setCreatingShown(false);
    if (id !== undefined) {
      onCompose(id);
    }
  };
  return (
    <>
      {disabled ? null : (
        <RegisterCommands
          offer={() => [
            composeCommand(t, () => {
              void compose();
            }),
          ]}
        />
      )}
      <GlassGroup style={styles.round}>
        <Pressable
          accessibilityLabel={t('drafts.newMessage')}
          accessibilityRole="button"
          accessibilityState={{ disabled }}
          disabled={disabled}
          onPress={() => {
            void compose();
          }}
          style={styles.newMessage}>
          <SFSymbol
            name="square.and.pencil"
            color={disabled ? colors.textSecondary : colors.accentInk}
          />
        </Pressable>
      </GlassGroup>
    </>
  );
}

// A round glass button of the bar, as tall as the search field.
export function BarButton({
  label,
  icon,
  onPress,
}: {
  readonly label: string;
  readonly icon: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <GlassGroup style={styles.round}>
      <Pressable
        accessibilityLabel={label}
        accessibilityRole="button"
        onPress={onPress}
        style={styles.newMessage}>
        <SFSymbol
          name={icon}
          color={colors.textPrimary}
        />
      </Pressable>
    </GlassGroup>
  );
}

// The filter switch, and while it is on, what the Inbox is filtered by, which opens the Filters sheet.
export function FilterControl({
  label,
  onToggle,
  onOpen,
}: {
  // The applied filter's summary; none while the Inbox is unfiltered.
  readonly label: string | undefined;
  readonly onToggle: () => void;
  readonly onOpen: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const on = label !== undefined;
  return (
    <GlassGroup style={on ? styles.filtered : styles.round}>
      <Pressable
        accessibilityLabel={t('filters.filter')}
        accessibilityRole="togglebutton"
        accessibilityState={{ checked: on }}
        onPress={onToggle}
        style={styles.newMessage}>
        <View
          style={[
            styles.filterIcon,
            on && { backgroundColor: colors.accentFill },
          ]}>
          <SFSymbol
            name="line.3.horizontal.decrease"
            color={on ? colors.accentOnFill : colors.textPrimary}
          />
        </View>
      </Pressable>
      {on ? (
        <Pressable
          accessibilityHint={t('filters.openHint')}
          accessibilityLabel={t('filters.filteredByLabel', { label })}
          accessibilityRole="button"
          onPress={onOpen}
          style={styles.filteredBy}>
          <Text
            numberOfLines={1}
            style={[styles.filteredByCaption, { color: colors.textPrimary }]}>
            {t('filters.filteredBy')}
          </Text>
          <View style={styles.filteredByValue}>
            <Text
              numberOfLines={1}
              style={[styles.filteredByLabel, { color: colors.accentInk }]}>
              {label}
            </Text>
            <SFSymbol
              name="chevron.down"
              size={10}
              color={colors.accentInk}
            />
          </View>
        </Pressable>
      ) : null}
    </GlassGroup>
  );
}

// Keeps the bar's trailing buttons at its trailing edge.
export function BarSpacer() {
  return <View style={styles.spacer} />;
}

// The search field. Focusing it opens search; it shows while a mailbox is readable.
export function SearchField({
  ready,
  query,
  onQuery,
  onFocus,
  search,
}: {
  readonly ready: boolean;
  readonly query: string;
  readonly onQuery: (query: string) => void;
  readonly onFocus: () => void;
  // The search field, which the Command Palette's Search Mail focuses.
  readonly search: RefObject<TextInput | null>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { accessibilityActions, onAccessibilityAction: handlePaletteAction } =
    usePaletteHeader().action;
  if (!ready) {
    return <View style={styles.searchBar} />;
  }
  return (
    <GlassGroup style={styles.searchBar}>
      <SFSymbol
        name="magnifyingglass"
        color={colors.textSecondary}
      />
      <TextInput
        // While searching the field replaces the heading, so it also opens the Command Palette.
        accessibilityActions={accessibilityActions}
        onAccessibilityAction={handlePaletteAction}
        accessibilityLabel={t('search.label')}
        accessibilityRole="search"
        autoCapitalize="none"
        autoComplete="off"
        autoCorrect={false}
        clearButtonMode="while-editing"
        onChangeText={onQuery}
        onFocus={onFocus}
        ref={search}
        placeholder={t('search.placeholder')}
        placeholderTextColor={colors.textSecondary}
        returnKeyType="search"
        style={[styles.search, { color: colors.textPrimary }]}
        value={query}
      />
    </GlassGroup>
  );
}

// The floating glass bar over the list, holding search, filters and New Message.
export function FloatingBar({
  hidden = false,
  children,
}: {
  readonly hidden?: boolean;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <>
      <View
        pointerEvents="none"
        style={[
          styles.scrollEdge,
          { display: hidden ? 'none' : 'flex' },
          {
            experimental_backgroundImage: `linear-gradient(to bottom, ${colors.surfaceContent}00, ${colors.surfaceContent})`,
          },
        ]}
      />
      <View
        pointerEvents="box-none"
        style={[styles.bottomBar, { display: hidden ? 'none' : 'flex' }]}>
        {children}
      </View>
    </>
  );
}
