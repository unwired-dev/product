import type { ReactNode, Ref, RefObject } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

import { composeCommand } from '@private-email/mail-core/commands';
import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
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
  scrollEdge: { position: 'absolute', bottom: 0, height: 72 },
  listEdge: { left: 0, right: 0 },
  readerEdge: { right: 0 },
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
  // A regular-width window's bar: the field 400pt wide and centered, the Filter control leading it
  // and New Message pinned to the trailing edge.
  windowBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
  },
  side: {
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'flex-end',
    alignItems: 'center',
  },
  field: { width: 400, flexDirection: 'row' },
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
  ref,
}: {
  // The applied filter's summary; none while the Inbox is unfiltered.
  readonly label: string | undefined;
  readonly onToggle: () => void;
  readonly onOpen: () => void;
  // Where iPad's Filters popover grows from.
  readonly ref?: Ref<View>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const on = label !== undefined;
  return (
    <GlassGroup
      ref={ref}
      style={on ? styles.filtered : styles.round}>
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

// A regular-width window's bottom edge, which shows the Inbox's floating bar across the window
// rather than over the list column. Compact layouts provide none and keep the bar in the list.
export function createWindowBar() {
  let bar: ReactNode = null;
  const listeners = new Set<() => void>();
  return {
    show: (next: ReactNode) => {
      bar = next;
      for (const listener of listeners) {
        listener();
      }
    },
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    bar: () => bar,
  };
}

export const WindowBarContext = createContext<
  ReturnType<typeof createWindowBar> | undefined
>(undefined);

function ScrollEdge({ style }: { readonly style: StyleProp<ViewStyle> }) {
  const colors = usePalette();
  return (
    <View
      pointerEvents="none"
      style={[
        styles.scrollEdge,
        style,
        {
          experimental_backgroundImage: `linear-gradient(to bottom, ${colors.surfaceContent}00, ${colors.surfaceContent})`,
        },
      ]}
    />
  );
}

// Shows the window's bar above the split view, with the reader's scroll edge beneath it.
export function WindowBarHost({
  windowBar,
  readerWidth,
  bottom,
}: {
  readonly windowBar: ReturnType<typeof createWindowBar>;
  readonly readerWidth: number;
  // The bar's distance from the window's bottom edge.
  readonly bottom: number;
}) {
  const bar = useSyncExternalStore(windowBar.subscribe, windowBar.bar);
  if (bar === null) {
    return null;
  }
  return (
    <>
      <ScrollEdge style={[styles.readerEdge, { width: readerWidth }]} />
      <View
        pointerEvents="box-none"
        testID="window-bar"
        style={[styles.windowBar, { bottom }]}>
        {bar}
      </View>
    </>
  );
}

// The floating glass bar over the list, holding search, filters and New Message. A regular-width
// window shows it across its bottom edge instead.
export function FloatingBar({
  hidden = false,
  leading,
  trailing,
  children,
}: {
  readonly hidden?: boolean;
  readonly leading: ReactNode;
  readonly trailing: ReactNode;
  // The search field, or the button that opens it.
  readonly children: ReactNode;
}) {
  const windowBar = use(WindowBarContext);
  const shown = hidden ? null : (
    <>
      <View
        pointerEvents="box-none"
        style={styles.side}>
        {leading}
      </View>
      <View style={styles.field}>{children}</View>
      <View
        pointerEvents="box-none"
        style={styles.side}>
        {trailing}
      </View>
    </>
  );
  useLayoutEffect(() => {
    windowBar?.show(shown);
  });
  useLayoutEffect(
    () => () => {
      windowBar?.show(null);
    },
    [windowBar],
  );
  return (
    <>
      <ScrollEdge
        style={[styles.listEdge, { display: hidden ? 'none' : 'flex' }]}
      />
      {windowBar === undefined ? (
        <View
          pointerEvents="box-none"
          style={[styles.bottomBar, { display: hidden ? 'none' : 'flex' }]}>
          {leading}
          {children}
          {trailing}
        </View>
      ) : null}
    </>
  );
}
