import type { Translate } from '@private-email/localization';
import type { ViewScope } from '@private-email/mail-core/mailboxes';
import type { ReactNode, RefObject } from 'react';
import type { TextInputInstance } from 'react-native';

import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  inboxMessages,
  inboxUnlisted,
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

import type { useInboxFilter } from './inbox-filters.tsx';
import type { InboxMailbox } from './private-storage.ts';

import { Action } from './action.tsx';
import { useCommandPalette, usePaletteHeader } from './command-palette.tsx';
import { SearchToolbar, SFSymbol, useOutcomeAnnouncement } from './design.tsx';
import {
  BarButton,
  BarNotices,
  barHeight,
  BarSpacer,
  FloatingBar,
  KeyboardLift,
  NewMessageButton,
  ScrollEdge,
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
import { SidebarToggleContext } from './sidebar-toggle.tsx';
import { usePalette } from './theme.ts';

// How far UIKit floats the toolbar's open search field above the keyboard.
const fieldLift = 10;

/**
 * Search's state and results. Search stays open from focusing its field until
 * Close, so editing the query never shows the Inbox in its place. It searches
 * the shown mailbox or folder, or every Inbox of the Profile when a narrower
 * view widens it.
 */
export function useInboxSearch(
  field: RefObject<TextInputInstance | null>,
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
  readonly field: RefObject<TextInputInstance | null>;
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
  // Searching or filtering acts on the list, so it shows where Mailboxes takes its place (#2193).
  const showList = use(SidebarToggleContext)?.showList;
  const listFilter = {
    ...filter,
    setOn: (on: Parameters<typeof filter.setOn>[0]) => {
      showList?.();
      filter.setOn(on);
    },
    setFilter: (next: Parameters<typeof filter.setFilter>[0]) => {
      showList?.();
      filter.setFilter(next);
    },
  };
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
      centered={filter.on}
      notice={notice}
      listNotice={listNotice}
      bottomInset={bottomInset}
      leading={
        searching || !ready ? null : <InboxFilterButton state={listFilter} />
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
            onFocus={() => {
              showList?.();
              focused();
            }}
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

const toolbarEdge = StyleSheet.create({ edge: { left: 0, right: 0 } });

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
  paused,
}: {
  readonly hidden: boolean;
  readonly ready: boolean;
  readonly search: ReturnType<typeof useInboxSearch>;
  readonly filter: ReturnType<typeof useInboxFilter>;
  readonly onCompose: (id: string) => void;
  readonly scope: string | undefined;
  readonly notice: ReactNode;
  readonly listNotice?: ReactNode;
  // Gmail's usage limit paused synchronization: the toolbar shows the capsule in Filter's place.
  readonly paused?:
    | Readonly<{
        label: string;
        detail?: string;
        spoken?: string;
        onOpen: () => void;
      }>
    | undefined;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const message = useNewMessage({
    onCompose,
    scope,
    registerCommand: !searching,
  });
  const { open: openPalette } = useCommandPalette();
  const bottomInset = useBarBottomInset();
  return (
    <>
      {message?.command}
      {/* Rows fade out over the window's last 72pt, beneath the toolbar's glass. */}
      <ScrollEdge
        style={[toolbarEdge.edge, { display: hidden ? 'none' : 'flex' }]}
      />
      {/* The safe area ends a spacing above the toolbar's glass, so notices sit on it. Above the
          keyboard, search's field takes the bar's place, floated above the keyboard by UIKit. */}
      <KeyboardLift opened={bottomInset - barHeight - spacing.m - fieldLift}>
        <BarNotices
          bottom={bottomInset}
          hidden={hidden}>
          {listNotice}
          {notice}
        </BarNotices>
      </KeyboardLift>
      <InboxFilterButton
        state={filter}
        renderControl={({ label, onToggle, onOpen }) => (
          <SearchToolbar
            accent={colors.accentFill}
            accentInk={colors.accentInk}
            accentOnFill={colors.accentOnFill}
            composeEnabled={message !== undefined && !message.disabled}
            composeLabel={t('drafts.newMessage')}
            covered={hidden}
            filterHint={t('filters.openHint')}
            filterLabel={t('filters.filter')}
            filterSummary={label}
            filterSummaryLabel={
              label === undefined
                ? undefined
                : t('filters.filteredByLabel', { label })
            }
            filteredBy={t('filters.filteredBy')}
            filtered={label !== undefined}
            focusRequest={focusRequest}
            onCompose={() => message?.compose()}
            onFilterOpen={onOpen}
            onFilterToggle={onToggle}
            onPalette={() => {
              openPalette();
            }}
            onSearchClose={close}
            onSearchFocus={focused}
            onSearchText={({ nativeEvent: { text } }) => {
              setQuery(text);
            }}
            paletteLabel={t('commands.openPalette')}
            pausedCaption={paused?.label}
            pausedDetail={paused?.detail}
            pausedHint={t('syncStatus.showDetails')}
            pausedLabel={paused?.spoken}
            pausedTint={colors.statusWarning}
            onPausedOpen={() => paused?.onOpen()}
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

// A mail server search that failed, left IMAP folders out or has another page has not answered
// whether nothing matches.
const searchIncomplete = (search: ReturnType<typeof useGmailSearch>) =>
  search.found !== undefined &&
  (search.found.failures.length > 0 ||
    search.found.limited.length > 0 ||
    search.found.next.size > 0);

// What Searching names. iPhone names the shown scope, as its approved frames do. iPad names what the
// mail servers search, as the Mac does: a single mailbox by its address and several as All
// Mailboxes. Only ready mailboxes that search their server are asked, as the search store does, and
// More from Mail Servers asks only those with another page.
function searchingScope(
  t: Translate,
  {
    searchesAll,
    searched,
    scopeName,
    more,
  }: Readonly<{
    searchesAll: boolean;
    // The mailboxes the online search was given.
    searched: readonly InboxMailbox[];
    scopeName: string;
    more: Readonly<{ next: ReadonlyMap<string, string> }> | undefined;
  }>,
) {
  if (!ipad) {
    return searchesAll ? t('inbox.allInboxes') : scopeName;
  }
  const asked = searched.filter(
    ({ id, state, inbox }) =>
      state.kind === 'ready' &&
      'searchGmail' in inbox &&
      inbox.searchGmail !== undefined &&
      (more === undefined || more.next.has(id)),
  );
  const [only] = asked;
  return asked.length > 1
    ? t('search.allMailboxes')
    : (only?.address ?? scopeName);
}

// Gmail's own search, asked for explicitly below the results saved on this device, which it never
// replaces. Each mailbox that Gmail could not search says why. While the mail servers are searched,
// Searching names the scope.
function OnlineResults({
  search,
  query,
  scope,
}: {
  readonly search: ReturnType<typeof useGmailSearch>;
  readonly query: string;
  readonly scope: string;
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
    <View style={searching ? styles.fill : undefined}>
      {found?.results.length === 0 && !searchIncomplete(search) ? (
        <Text style={[styles.notice, { color: colors.textSecondary }]}>
          {t('search.onlineEmpty', { query })}
        </Text>
      ) : null}
      {searching ? (
        <View
          accessible
          accessibilityRole="progressbar"
          style={styles.searchState}>
          <ActivityIndicator style={styles.searchingIndicator} />
          <Text
            style={[
              styles.emptyText,
              styles.searchStateText,
              { color: colors.textSecondary },
            ]}>
            {t('search.searchingScope', { scope })}
          </Text>
        </View>
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

// Below the results: No Results when neither saved mail nor a complete mail server answer matches,
// which VoiceOver hears once as it appears, then the mail server search. iPhone draws No Results
// with the Profile Locked recipe's icon tile and the saved-search line; iPad, as the Mac, names the
// scope and the query.
export function SearchFooter({
  search: { online: search, searched: query, results, searchesAll },
  mailboxes,
  shown,
  ready,
  unlisted,
  scopeName,
  folderName,
}: {
  readonly search: ReturnType<typeof useInboxSearch>;
  // What search widened to every Inbox covers; undefined while that is unknown, so it has not answered.
  readonly mailboxes: readonly InboxMailbox[] | undefined;
  readonly shown: readonly InboxMailbox[];
  readonly ready: boolean;
  // The listed folder or view is still opening or could not be read, so it has not answered.
  readonly unlisted: boolean;
  readonly scopeName: string;
  readonly folderName: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // Search widened to every Inbox has answered once each of them has listed.
  const answered =
    ready &&
    results?.length === 0 &&
    !(searchesAll
      ? mailboxes === undefined ||
        mailboxes.some(({ state }) => inboxUnlisted(state))
      : unlisted);
  const noResults =
    answered &&
    !search.searching &&
    !search.found?.results.length &&
    !searchIncomplete(search);
  const title = t('search.noResults');
  useOutcomeAnnouncement(noResults ? title : undefined, true);
  const online = (
    <OnlineResults
      query={query}
      search={search}
      scope={searchingScope(t, {
        searchesAll,
        searched: searchesAll ? (mailboxes ?? []) : shown,
        scopeName,
        more: search.found,
      })}
    />
  );
  if (!noResults) {
    return online;
  }
  return (
    <View style={[styles.searchState, styles.noResults]}>
      <View
        style={
          ipad
            ? styles.noResultsGlyph
            : [styles.noResultsTile, { backgroundColor: colors.fillQuiet }]
        }>
        <SFSymbol
          name="magnifyingglass"
          size={ipad ? 34 : 36}
          color={ipad ? colors.textSecondary : colors.textPrimary}
        />
      </View>
      <Text
        accessibilityRole="header"
        style={[
          styles.emptyTitle,
          styles.noResultsTitle,
          { color: colors.textPrimary },
        ]}>
        {title}
      </Text>
      <Text
        style={[
          styles.emptyText,
          styles.searchStateText,
          { color: colors.textSecondary },
        ]}>
        {ipad
          ? t('search.noResultsDetail', {
              scope: searchesAll
                ? t('inbox.allInboxes')
                : (folderName ?? scopeName),
              query,
            })
          : t('search.empty', { query })}
      </Text>
      {online}
    </View>
  );
}
