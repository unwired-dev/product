import type { ViewScope } from '@private-email/mail-core/mailboxes';
import type { ReactNode, RefObject } from 'react';
import type { TextInput } from 'react-native';

import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  inboxMessages,
  searchMessages,
} from '@private-email/mail-core/mailboxes';
import { useDeferredValue, useEffect, useMemo, useState } from 'react';
import { Keyboard } from 'react-native';

import type { useInboxFilter } from './inbox-filters.tsx';
import type { InboxMailbox } from './private-storage.ts';

import {
  BarButton,
  BarSpacer,
  FloatingBar,
  NewMessageButton,
  SearchField,
} from './inbox-bar.tsx';
import { InboxFilterButton } from './inbox-filters.tsx';
import { SearchScope } from './inbox-heading.tsx';
import { useLocalization } from './localization.ts';
import { useGmailSearch } from './mailbox.tsx';

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
    open: () => {
      setOpened(true);
      field.current?.focus();
    },
    close: () => {
      setQuery('');
      setOpened(false);
      setAll(false);
      Keyboard.dismiss();
    },
  };
}

// The floating bar. Unfiltered: Filter, the search field and New Message. Filtered: what the Inbox
// is filtered by, then Search and New Message. Searching: the field and Close. The field keeps its
// place in each, so focusing it never remounts it.
export function InboxBar({
  hidden,
  ready,
  field,
  search: { searching, query, setQuery, focused, open, close },
  filter,
  onCompose,
  scope,
}: {
  readonly hidden: boolean;
  readonly ready: boolean;
  readonly field: RefObject<TextInput | null>;
  readonly search: ReturnType<typeof useInboxSearch>;
  readonly filter: ReturnType<typeof useInboxFilter>;
  readonly onCompose: ((id: string) => void) | undefined;
  readonly scope: string | undefined;
}) {
  const { t } = useLocalization();
  const compact = filter.on && !searching;
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
    <FloatingBar hidden={hidden}>
      {searching || !ready ? null : <InboxFilterButton state={filter} />}
      {compact ? <BarSpacer /> : null}
      {compact ? (
        <BarButton
          icon="magnifyingglass"
          label={t('search.title')}
          onPress={open}
        />
      ) : (
        <SearchField
          onFocus={focused}
          onQuery={setQuery}
          query={query}
          ready={ready}
          search={field}
        />
      )}
      {trailing}
    </FloatingBar>
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
