import type { ReactNode, RefObject } from 'react';

import { composeCommand } from '@private-email/mail-core/commands';
import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { Pressable, StyleSheet, TextInput, View } from 'react-native';

import { RegisterCommands } from './command-palette.tsx';
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
    width: 40,
    height: 40,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 2,
    borderRadius: 20,
  },
  // Native padding centres text without shrinking the field's click target.
  search: { ...textStyles.body, flex: 1, paddingVertical: spacing.m },
  scrollEdge: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: 72,
  },
  // Spans the list and reader: the search field centered in the window, New Message at the
  // trailing edge.
  bottomBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: 40 + 2 * spacing.l,
  },
  field: { position: 'absolute', bottom: spacing.l },
  trailing: { position: 'absolute', right: spacing.l, bottom: spacing.l },
  // Centered 12pt above the search bar.
  notice: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: spacing.l + 40 + spacing.m,
    alignItems: 'center',
    paddingHorizontal: spacing.l,
  },
  searchBar: {
    height: 40,
    flexWrap: 'nowrap',
    alignItems: 'center',
    gap: spacing.s,
    paddingLeft: spacing.m,
    paddingRight: spacing.s,
    paddingVertical: 0,
    borderRadius: 20,
    backgroundColor: 'transparent',
  },
});

// The New Message control of the floating search bar.
function NewMessageButton({
  onCompose,
  scope,
}: {
  readonly onCompose: (id: string) => void;
  // The mailbox the Inbox shows, which a new message sends from when it can.
  readonly scope: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [focused, setFocused] = useState(false);
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
    let id: string | undefined = undefined;
    try {
      id = await navigation.create(store, sender);
    } catch {
      // An unexpected rejection, such as a throwing Draft subscriber, keeps New Message usable.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
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
      <GlassGroup
        style={{
          padding: 0,
          borderRadius: 20,
          backgroundColor: 'transparent',
        }}>
        <Pressable
          accessibilityLabel={t('drafts.newMessage')}
          accessibilityRole="button"
          accessibilityState={{ disabled }}
          disabled={disabled}
          // The control's accent/ink ring replaces the system focus ring.
          enableFocusRing={false}
          focusable
          onBlur={() => {
            setFocused(false);
          }}
          onFocus={() => {
            setFocused(true);
          }}
          onPress={() => {
            void compose();
          }}
          style={({ pressed }) => [
            styles.newMessage,
            {
              backgroundColor: pressed
                ? colors.accentSelectionSubtle
                : 'transparent',
              borderColor: focused ? colors.accentInk : 'transparent',
              opacity: disabled ? 0.4 : 1,
            },
          ]}>
          <SFSymbol
            name="square.and.pencil"
            color={colors.accentInk}
          />
        </Pressable>
      </GlassGroup>
    </>
  );
}

const searchWidth = 400;

// The search field's width: up to 400pt, centered on the window, clear of the window's edge and of
// New Message.
const fieldFrame = (width: number, offset: number) => {
  const center = width / 2 - offset;
  const half = Math.max(
    0,
    Math.min(
      searchWidth / 2,
      center - spacing.l,
      width - spacing.l - 40 - spacing.s - center,
    ),
  );
  return { left: center - half, width: 2 * half };
};

// How far the window's center lies before the panes' center: half the sidebar's visible width,
// which AppKit reports through each frame of its animation. A store, so only the bar follows it.
export type BarOffset = Readonly<{
  subscribe: (listener: () => void) => () => void;
  get: () => number;
}>;

export const BarOffsetContext = createContext<BarOffset>({
  subscribe: () => () => undefined,
  get: () => 0,
});

export const createBarOffset = () => {
  let offset = 0;
  const listeners = new Set<() => void>();
  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    get: () => offset,
    set: (next: number) => {
      if (next === offset) {
        return;
      }
      offset = next;
      for (const listener of listeners) {
        listener();
      }
    },
  };
};

// The floating glass bar over the panes: search on the mail saved on this device, and New Message.
export function FloatingBar({
  hidden = false,
  ready,
  query,
  onQuery,
  onCompose,
  scope,
  search,
  notice,
}: {
  readonly hidden?: boolean;
  // Search waits for a mailbox to be readable.
  readonly ready: boolean;
  readonly query: string;
  readonly onQuery: (query: string) => void;
  readonly onCompose: ((id: string) => void) | undefined;
  readonly scope: string | undefined;
  // The search field, which the Command Palette's Search Mail focuses.
  readonly search: RefObject<TextInput | null>;
  // A toast above the bar.
  readonly notice?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const barOffset = use(BarOffsetContext);
  const offset = useSyncExternalStore(barOffset.subscribe, barOffset.get);
  const [width, setWidth] = useState(0);
  const [searching, setSearching] = useState(false);
  const centered = { transform: [{ translateX: -offset }] };
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
        onLayout={({ nativeEvent }) => {
          setWidth(nativeEvent.layout.width);
        }}
        pointerEvents="box-none"
        style={[styles.bottomBar, { display: hidden ? 'none' : 'flex' }]}>
        <View
          pointerEvents="box-none"
          style={[styles.field, fieldFrame(width, offset)]}>
          {ready ? (
            <GlassGroup
              search
              style={[
                styles.searchBar,
                // The capsule's accent/ink ring replaces the field's own focus ring.
                searching && {
                  outlineWidth: 2,
                  outlineColor: colors.accentInk,
                },
              ]}>
              <SFSymbol
                name="magnifyingglass"
                color={colors.textSecondary}
              />
              <TextInput
                accessibilityLabel={t('search.label')}
                accessibilityRole="search"
                autoCapitalize="none"
                autoComplete="off"
                autoCorrect={false}
                enableFocusRing={false}
                onBlur={() => {
                  setSearching(false);
                }}
                onChangeText={onQuery}
                onFocus={() => {
                  setSearching(true);
                }}
                ref={search}
                placeholder={t('search.placeholder')}
                placeholderTextColor={colors.textSecondary}
                returnKeyType="search"
                style={[styles.search, { color: colors.textPrimary }]}
                value={query}
              />
            </GlassGroup>
          ) : null}
        </View>
        {onCompose === undefined ? null : (
          <View style={styles.trailing}>
            <NewMessageButton
              onCompose={onCompose}
              scope={scope}
            />
          </View>
        )}
      </View>
      <View
        pointerEvents="box-none"
        style={[
          styles.notice,
          centered,
          { display: hidden ? 'none' : 'flex' },
        ]}>
        {notice}
      </View>
    </>
  );
}
