import type { ViewScope } from '@private-email/mail-core/mailboxes';
import type { ReactNode, RefObject } from 'react';
import type { TextInput } from 'react-native';

import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  inboxMessages,
  searchMessages,
} from '@private-email/mail-core/mailboxes';
import { spacing } from '@private-email/mail-core/theme';
import { use, useDeferredValue, useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Keyboard,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { KeyboardStickyView } from 'react-native-keyboard-controller';

import type { useInboxFilter } from './inbox-filters.tsx';
import type { InboxMailbox } from './private-storage.ts';

import { Action } from './action.tsx';
import { useCommandPalette, usePaletteHeader } from './command-palette.tsx';
import { SearchToolbar } from './design.tsx';
import {
  BarButton,
  BarNotices,
  BarSpacer,
  FloatingBar,
  NewMessageButton,
  SearchField,
  useBarBottomInset,
  useNewMessage,
  WindowBarContext,
} from './inbox-bar.tsx';
import { InboxFilterButton } from './inbox-filters.tsx';
import { SearchScope } from './inbox-heading.tsx';
import { ipad, styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { useGmailSearch } from './mailbox.tsx';
import { usePalette } from './theme.ts';

/**
 * Search's state and results. Search stays open from focusing its field until
 * Close, so editing the query never shows the Inbox in its place. It searches
 * the shown mailbox or folder, or every Inbox of the Profile when a narrower
 * view widens it.
 */
export function useInboxSearch(
  field: RefObject<TextInput | null>,
  {
    mailboxes,
    shown,
    listed,
    profile,
    scoped,
    several,
    folder,
  }: Readonly<{
    mailboxes: readonly InboxMailbox[];
    shown: readonly InboxMailbox[];
    // The shown mailbox's or folder's messages.
    listed: Parameters<typeof searchMessages<InboxMailbox>>[0];
    profile: string;
    scoped: ViewScope;
    // Whether the Profile has several connections.
    several: boolean;
    // The shown IMAP folder, if any.
    folder: string | undefined;
  }>,
) {
  const [query, setQuery] = useState('');
  const [opened, setOpened] = useState(false);
  const [all, setAll] = useState(false);
  // Counts Search Mail's requests to focus a field that React Native doesn't own.
  const [focusRequest, setFocusRequest] = useState(0);
  // A filtered Inbox shows a Search button, so its field appears only once search opens.
  useEffect(() => {
    if (opened) {
      field.current?.focus();
    }
  }, [opened, field]);
  // Typing stays responsive while the list catches up with the latest query.
  const searched = useDeferredValue(query.trim());
  // A narrower view, one connection or one of its folders, can widen search to every Inbox.
  const widens =
    scoped.mailbox !== undefined &&
    (several || (folder !== undefined && folder !== inboxFolder));
  const searchesAll = widens && all;
  const everyInbox = useMemo(() => ({ profile }), [profile]);
  const searchable = useMemo(
    () => (searchesAll ? inboxMessages(mailboxes, everyInbox) : listed),
    [searchesAll, mailboxes, everyInbox, listed],
  );
  // Searches only the mail saved on this device, so it works offline and asks Gmail nothing.
  const results = useMemo(
    () => (searched === '' ? undefined : searchMessages(searchable, searched)),
    [searchable, searched],
  );
  const online = useGmailSearch(
    searchesAll ? mailboxes : shown,
    searched,
    searchesAll ? everyInbox : scoped,
  );
  return {
    query,
    setQuery,
    searching: opened || query !== '',
    searched,
    results,
    online,
    widens,
    all,
    setAll,
    searchesAll,
    focused: () => {
      setOpened(true);
    },
    focusRequest,
    open: () => {
      setOpened(true);
      setFocusRequest((count) => count + 1);
      field.current?.focus();
    },
    close: () => {
      field.current?.clear();
      setQuery('');
      setOpened(false);
      setAll(false);
      Keyboard.dismiss();
    },
  };
}

// The floating bar. Unfiltered: Filter, the search field and New Message. Filtered: what the Inbox
// is filtered by, then Search and New Message; a regular-width window keeps its field instead.
// Searching: the field and Close. The field keeps its place in each, so focusing it never
// remounts it.
export function InboxBar({
  hidden,
  ready,
  field,
  search: { searching, query, setQuery, focused, open, close },
  filter,
  onCompose,
  scope,
  notice,
  listNotice,
}: {
  readonly hidden: boolean;
  readonly ready: boolean;
  readonly field: RefObject<TextInput | null>;
  readonly search: ReturnType<typeof useInboxSearch>;
  readonly filter: ReturnType<typeof useInboxFilter>;
  readonly onCompose: ((id: string) => void) | undefined;
  readonly scope: string | undefined;
  readonly notice: ReactNode;
  readonly listNotice?: ReactNode;
}) {
  const { t } = useLocalization();
  const header = usePaletteHeader();
  const inWindow = use(WindowBarContext) !== undefined;
  const bottomInset = useBarBottomInset();
  const compact = filter.on && !searching && !inWindow;
  let trailing = null;
  if (searching) {
    trailing = (
      <BarButton
        icon="xmark"
        label={t('search.close')}
        onPress={close}
      />
    );
  } else if (onCompose !== undefined) {
    trailing = (
      <NewMessageButton
        onCompose={onCompose}
        scope={scope}
      />
    );
  }
  return (
    <FloatingBar
      hidden={hidden}
      notice={notice}
      listNotice={listNotice}
      bottomInset={bottomInset}
      leading={
        searching || !ready ? null : <InboxFilterButton state={filter} />
      }
      trailing={trailing}>
      {compact ? <BarSpacer /> : null}
      {compact ? (
        <BarButton
          icon="magnifyingglass"
          label={t('search.title')}
          onPress={open}
        />
      ) : (
        <View
          // Always a native view: gaining the swipe handlers must not re-parent the focused field,
          // which would dismiss its keyboard.
          collapsable={false}
          style={styles.searchField}
          {...(!ipad && searching ? header.swipe : {})}>
          <SearchField
            // Match the mount seed to the native field's readiness lifetime.
            key={ready || searching ? 'field' : 'placeholder'}
            onFocus={focused}
            onQuery={setQuery}
            query={query}
            ready={ready || searching}
            search={field}
          />
        </View>
      )}
    </FloatingBar>
  );
}

// The compact Inbox's system toolbar in place of the floating bar: Filter, the system search field
// and New Message, which UIKit arranges for each state.
export function InboxToolbar({
  hidden,
  ready,
  search: { searching, focusRequest, setQuery, focused, close },
  filter,
  onCompose,
  scope,
  notice,
  listNotice,
}: {
  readonly hidden: boolean;
  readonly ready: boolean;
  readonly search: ReturnType<typeof useInboxSearch>;
  readonly filter: ReturnType<typeof useInboxFilter>;
  readonly onCompose: (id: string) => void;
  readonly scope: string | undefined;
  readonly notice: ReactNode;
  readonly listNotice?: ReactNode;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const message = useNewMessage({ onCompose, scope });
  const { open: openPalette } = useCommandPalette();
  const bottomInset = useBarBottomInset();
  return (
    <>
      {message?.command}
      {/* Notices ride above the toolbar, and above the keyboard while search uses it. */}
      <KeyboardStickyView
        offset={{ opened: bottomInset + spacing.xs - spacing.m }}
        pointerEvents="box-none"
        style={StyleSheet.absoluteFill}>
        <BarNotices
          bottom={bottomInset + spacing.xs}
          hidden={hidden}>
          {listNotice}
          {notice}
        </BarNotices>
      </KeyboardStickyView>
      <InboxFilterButton
        state={filter}
        renderControl={({ label, onToggle, onOpen }) => (
          <SearchToolbar
            accent={colors.accentFill}
            composeEnabled={message !== undefined && !message.disabled}
            composeLabel={t('drafts.newMessage')}
            covered={hidden}
            filterHint={t('filters.openHint')}
            filterLabel={t('filters.filter')}
            filterSummary={label}
            filteredBy={t('filters.filteredBy')}
            filtered={label !== undefined}
            focusRequest={focusRequest}
            onCompose={() => message?.compose()}
            onFilterOpen={onOpen}
            onFilterToggle={onToggle}
            onPalette={openPalette}
            onSearchClose={close}
            onSearchFocus={focused}
            onSearchText={({ nativeEvent: { text } }) => {
              setQuery(text);
            }}
            paletteLabel={t('commands.openPalette')}
            placeholder={t('search.placeholder')}
            ready={ready}
            searchLabel={t('search.label')}
            searching={searching}
          />
        )}
      />
    </>
  );
}

// While searching, the heading gives way to the scope choice where the view offers one.
export function SearchHeading({
  search: { searching, widens, all, setAll },
  children,
}: {
  readonly search: ReturnType<typeof useInboxSearch>;
  // The Inbox's own heading.
  readonly children: ReactNode;
}) {
  if (!searching) {
    return children;
  }
  return widens ? (
    <SearchScope
      all={all}
      onAll={setAll}
    />
  ) : null;
}

// Gmail's own search, asked for explicitly below the results saved on this device, which it never
// replaces. Each mailbox that Gmail could not search says why.
export function OnlineResults({
  search,
  query,
}: {
  readonly search: ReturnType<typeof useGmailSearch>;
  readonly query: string;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { found, searching } = search;
  if (!search.available) {
    return null;
  }
  if (found === undefined && !searching) {
    return (
      <View style={styles.noticeAction}>
        <Action
          variant="list"
          label={t('search.online', { query })}
          onPress={() => {
            void search.search();
          }}
        />
      </View>
    );
  }
  return (
    <View>
      {found?.results.length === 0 && found.failures.length === 0 ? (
        <Text style={[styles.notice, { color: colors.textSecondary }]}>
          {t('search.onlineEmpty', { query })}
        </Text>
      ) : null}
      {searching ? (
        <ActivityIndicator accessibilityLabel={t('search.searching')} />
      ) : null}
      {!searching && found !== undefined && found.next.size > 0 ? (
        <View style={styles.noticeAction}>
          <Action
            variant="list"
            label={t('search.more')}
            onPress={() => {
              void search.more();
            }}
          />
        </View>
      ) : null}
      {!searching && found !== undefined && found.failures.length > 0 ? (
        <View style={styles.noticeAction}>
          <Action
            variant="list"
            label={t('search.retry')}
            onPress={() => {
              void search.search();
            }}
          />
        </View>
      ) : null}
    </View>
  );
}
