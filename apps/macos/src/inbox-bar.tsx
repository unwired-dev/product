import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import { use, useRef, useState } from 'react';
import { Pressable, StyleSheet, TextInput, View } from 'react-native';

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
    borderWidth: 1,
    borderRadius: 20,
  },
  search: { ...textStyles.body, flex: 1, minHeight: 40 },
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
    borderRadius: 20,
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
  const sender = senders.find(({ id }) => id === scope) ?? senders[0];
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
    <GlassGroup style={{ padding: 0, borderRadius: 20 }}>
      <Pressable
        accessibilityLabel={t('drafts.newMessage')}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
        disabled={disabled}
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
        style={[
          styles.newMessage,
          { borderColor: focused ? colors.accentInk : 'transparent' },
        ]}>
        <SFSymbol
          name="square.and.pencil"
          color={disabled ? colors.textSecondary : colors.accentInk}
        />
      </Pressable>
    </GlassGroup>
  );
}

// The floating glass bar over the list: search on the mail saved on this device, and New Message.
export function FloatingBar({
  ready,
  query,
  onQuery,
  onCompose,
  scope,
}: {
  // Search waits for a mailbox to be readable.
  readonly ready: boolean;
  readonly query: string;
  readonly onQuery: (query: string) => void;
  readonly onCompose: ((id: string) => void) | undefined;
  readonly scope: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      <View
        pointerEvents="none"
        style={[
          styles.scrollEdge,
          {
            experimental_backgroundImage: `linear-gradient(to bottom, ${colors.surfaceContent}00, ${colors.surfaceContent})`,
          },
        ]}
      />
      <View
        pointerEvents="box-none"
        style={styles.bottomBar}>
        {ready ? (
          <GlassGroup style={styles.searchBar}>
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
              onChangeText={onQuery}
              placeholder={t('search.placeholder')}
              placeholderTextColor={colors.textSecondary}
              returnKeyType="search"
              style={[styles.search, { color: colors.textPrimary }]}
              value={query}
            />
          </GlassGroup>
        ) : (
          <View style={styles.searchBar} />
        )}
        {onCompose === undefined ? null : (
          <NewMessageButton
            onCompose={onCompose}
            scope={scope}
          />
        )}
      </View>
    </>
  );
}
