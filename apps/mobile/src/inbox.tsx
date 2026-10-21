import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { Draft } from '@private-email/mail-core/drafts';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { MailProvider } from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';
import type { TextInput } from 'react-native';

import { draftsOf, profileDrafts } from '@private-email/mail-core/drafts';
import {
  leavesView,
  quickActions,
} from '@private-email/mail-core/gmail-actions';
import { imapQuickActions } from '@private-email/mail-core/imap-actions';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  gmailViewName,
  inboxChoice,
  inboxMessages,
  messageDateSections,
  profileMailboxes,
  resultKey,
} from '@private-email/mail-core/mailboxes';
import { use, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { KeyboardAvoidingView, SectionList, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { RowAction } from './inbox-rows.tsx';
import type { useGmailSearch } from './mailbox.tsx';
import type { InboxMailbox } from './private-storage.ts';
import type { MailboxView } from './sidebar.tsx';

import {
  DraftHeading,
  DraftList,
  DraftRow,
  useOpenDraft,
} from './composer.tsx';
import { Button, Notice, SFSymbol } from './design.tsx';
import { ErrorReportingContext } from './error-reporting.tsx';
import { useInboxFilter } from './inbox-filters.tsx';
import { HeadingTitle, InboxHeading } from './inbox-heading.tsx';
import { DateDivider, MessageRow, SkeletonRows } from './inbox-rows.tsx';
import {
  InboxBar,
  OnlineResults,
  SearchHeading,
  useInboxSearch,
} from './inbox-search.tsx';
import { emptySymbolSize, ipad, styles } from './inbox-styles.ts';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxFolder } from './mailbox-folders.tsx';
import {
  MailboxScope,
  useDrafts,
  useInbox,
  useInboxActions,
  useLeaveComposer,
  useMailbox,
  useProviderName,
  useMailboxes,
  useOutboxEntries,
  useProfile,
  useReloadMailboxes,
  useSavedBodies,
} from './mailbox.tsx';
import { OrganizeStatus } from './organize-status.tsx';
import { OutboxHeading, OutboxRow } from './outbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

// The open-Draft callback for an Inbox without Drafts, stable so Draft rows stay memoized.
const composeNothing = () => undefined;

// A Draft as a row of the Inbox list, apart from received mail.
type DraftItem = Readonly<{ draft: Draft }>;
type OutboxItem = Readonly<{ outbox: OutboxSnapshotEntry }>;

// The Drafts an Inbox lists: none where it offers no composer.
const listedDrafts = (
  state: Parameters<typeof draftsOf>[0],
  composing: boolean,
): readonly Draft[] => (composing ? draftsOf(state) : []);

// A message in a mailbox; Gmail message IDs are unique only within their mailbox.
// A Gmail message also names the view it was chosen in, which its actions can take it out of.
export type Selection = Readonly<{
  mailbox: string;
  id: string;
  folder?: string;
}>;

interface InboxProps {
  readonly selected: Selection | undefined;
  readonly onSelect: (selection: Selection) => void;
  // A collapsed overlay keeps editing while the reader's selection changes beneath it.
  readonly onSelectBehindComposer?:
    | ((selection: Selection) => void)
    | undefined;
  // Closes the reader when a row action takes its message out of the Inbox.
  readonly onClose?: (() => void) | undefined;
  // Returns to Mailboxes on iPhone, where the list replaces the native navigation bar.
  readonly onBack?: (() => void) | undefined;
  // Opens a Draft in the composer; without it the Inbox offers no Drafts.
  readonly onCompose?: ((id: string) => void) | undefined;
  readonly composing?: string | undefined;
  // The mailbox or folder the list shows; every mailbox of the Profile without one.
  readonly view?: MailboxView;
  readonly onView?: (view: MailboxView) => void;
}

const allInboxes: MailboxView = {};
const keepView = () => undefined;

// The minute the list reads its dividers and times by, so a day ends at midnight while it is open.
const minute = 60_000;
const subscribeMinute = (notify: () => void) => {
  const timer = setInterval(notify, minute);
  return () => {
    clearInterval(timer);
  };
};
const useNow = () =>
  useSyncExternalStore(
    subscribeMinute,
    () => Math.floor(Date.now() / minute) * minute,
  );

// Names the mailbox a notice is about when the Inbox holds more than one.
const about = (t: Translate, address: string | undefined, text: string) =>
  address === undefined ? text : t('inbox.about', { address, text });

// Synchronization keeps the cached list visible and says why the provider may be behind; the
// heading's subtitle says while it is being checked.
function SyncNotice({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const mailbox = useMailbox();
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = useProviderName();
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    state.sync === 'current' ||
    state.sync === 'syncing'
  ) {
    return null;
  }
  // Synchronizes again once access for this mailbox is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  if (state.sync === 'authentication') {
    return (
      <Notice
        announce="polite"
        icon="person.crop.circle.badge.exclamationmark"
        iconColor={colors.statusWarning}
        message={about(
          t,
          address,
          t('gmailSync.authentication', { provider }),
        )}>
        {account !== undefined && mailbox !== undefined ? (
          <Button
            fill="accent"
            label={t('common.allowAccess', { provider })}
            onPress={() => {
              void handleAllowGmail(() => account.authorizeMailbox(mailbox.id));
            }}
          />
        ) : null}
      </Notice>
    );
  }
  return (
    <Notice
      announce="polite"
      icon="wifi.slash"
      message={about(t, address, t('gmailSync.retry', { provider }))}>
      <Button
        label={t('common.retry')}
        onPress={() => {
          void (account === undefined
            ? actions.load()
            : account.refreshInbox(actions.load));
        }}
      />
    </Notice>
  );
}

// One mailbox's storage, synchronization and organizing status.
function MailboxStatus({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const { t } = useLocalization();
  return (
    <>
      {state.kind === 'failed' || state.kind === 'locked' ? (
        <Notice
          icon={state.kind === 'locked' ? 'lock' : 'exclamationmark.triangle'}
          message={about(
            t,
            address,
            state.kind === 'locked' ? t('storage.locked') : t('storage.failed'),
          )}
          messageRole="alert">
          <Button
            label={t('common.retry')}
            onPress={() => {
              void actions.load();
            }}
          />
        </Notice>
      ) : null}
      <SyncNotice address={address} />
      <ImapNotice address={address} />
      <OrganizeStatus />
    </>
  );
}

// An IMAP mailbox says when the server could not be read and keeps its saved mail; a refused
// password is entered again in Settings.
function ImapNotice({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const mailbox = useMailbox();
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  if (
    state.kind !== 'ready' ||
    !('imap' in state) ||
    state.status === 'current' ||
    state.status === 'syncing'
  ) {
    return null;
  }
  if (state.status === 'authentication') {
    return (
      <Notice
        announce="polite"
        icon="person.crop.circle.badge.exclamationmark"
        iconColor={colors.statusWarning}
        message={about(t, address, t('imapSync.authentication'))}>
        {account === undefined ? null : (
          <Button
            fill="accent"
            label={t('mailboxes.enterPassword', {
              address: mailbox?.address ?? state.address,
            })}
            onPress={() => {
              account.openAccount('mailboxes');
            }}
          />
        )}
      </Notice>
    );
  }
  return (
    <Notice
      announce="polite"
      icon="wifi.slash"
      message={about(t, address, t('imapSync.retry'))}
    />
  );
}

// A Gmail or IMAP Inbox still checking its server.
const checking = (state: InboxMailbox['state']) =>
  state.kind === 'loading' ||
  (state.kind === 'ready' &&
    (('sync' in state && state.sync === 'syncing') ||
      ('status' in state && state.status === 'syncing')));

// A connection whose grant its provider refused has no Inbox until it is authorized again.
function AuthorizationNeeded({
  address,
  provider: mailProvider,
  onAllow,
}: {
  readonly address: string;
  readonly provider: MailProvider;
  readonly onAllow: () => Promise<void>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = t(`mailProviders.${mailProvider}`);
  return (
    <Notice
      announce="polite"
      icon="person.crop.circle.badge.exclamationmark"
      iconColor={colors.statusWarning}
      message={about(t, address, t('gmailSync.authentication', { provider }))}>
      <Button
        fill="accent"
        label={t('mailboxes.allow', { address, provider })}
        onPress={() => {
          void onAllow();
        }}
      />
    </Notice>
  );
}

// A saved IMAP connection needs its own password, independently of Gmail consent.
function ImapAuthorizationNeeded({
  address,
  onRepair,
}: {
  readonly address: string;
  readonly onRepair: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Notice
      announce="polite"
      icon="person.crop.circle.badge.exclamationmark"
      iconColor={colors.statusWarning}
      message={about(t, address, t('imapSync.authentication'))}>
      <Button
        fill="accent"
        label={t('mailboxes.enterPassword', { address })}
        onPress={onRepair}
      />
    </Notice>
  );
}

// A search result's saved state, once known.
const savedStatus = (t: Translate, saved: boolean | undefined) => {
  if (saved === undefined) {
    return undefined;
  }
  return saved ? t('search.saved') : t('search.download');
};

// The online section announces its source and each connection's failure before its rows.
function OnlineHeading({
  search,
  several,
}: {
  readonly search: ReturnType<typeof useGmailSearch>;
  readonly several: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { found } = search;
  return (
    <View>
      <Text
        accessibilityRole="header"
        style={[styles.footer, { color: colors.textSecondary }]}>
        {t('search.onlineHeading')}
      </Text>
      {found?.failures.map(({ mailbox, reason }) => (
        <Text
          key={mailbox.id}
          accessibilityLiveRegion="polite"
          style={[styles.footer, { color: colors.textSecondary }]}>
          {about(
            t,
            several ? mailbox.address : undefined,
            t(`search.unavailable.${reason}`),
          )}
        </Text>
      ))}
      {found?.limited.map((mailbox) => (
        <Text
          key={`limited\n${mailbox.id}`}
          style={[styles.footer, { color: colors.textSecondary }]}>
          {about(
            t,
            several ? mailbox.address : undefined,
            t('search.foldersLimited'),
          )}
        </Text>
      ))}
    </View>
  );
}

// The shown mailbox's address, or what the list holds when it shows several or none.
function scopeOf(
  t: Translate,
  shown: readonly InboxMailbox[],
  {
    several,
    gmail,
    waiting,
  }: Readonly<{
    several: boolean;
    gmail: boolean;
    // The chosen connection while it waits for authorization, which has no Inbox to show.
    waiting: Readonly<{ address: string }> | undefined;
  }>,
) {
  if (waiting !== undefined) {
    return waiting.address;
  }
  const [only] = shown;
  if (shown.length === 1 && only?.address !== undefined) {
    return only.address;
  }
  if (several) {
    return t('inbox.allInboxes');
  }
  return gmail ? t('inbox.gmail') : t('inbox.subtitle');
}

// A mailbox whose server could not be reached shows the mail saved on this device.
const offline = (state: InboxMailbox['state']) =>
  state.kind === 'ready' &&
  (('sync' in state && state.sync === 'retry') ||
    ('status' in state && state.status === 'retry'));

// The subtitle's status: checking the server, cut off from it, or how much is unread.
function statusOf(
  t: Translate,
  shown: readonly InboxMailbox[],
  {
    unread,
    searchOffline,
    waiting,
  }: Readonly<{
    unread: number;
    // An explicit online search that found a mail server unreachable.
    searchOffline: boolean;
    // The chosen connection while it waits for authorization, whose unread mail is unknown.
    waiting: Readonly<{ provider: MailProvider }> | undefined;
  }>,
) {
  if (waiting !== undefined) {
    return waiting.provider === 'imap'
      ? t('mailboxes.states.imap-authorization')
      : t('mailboxes.states.authorization', {
          provider: t(`mailProviders.${waiting.provider}`),
        });
  }
  if (shown.some(({ state }) => checking(state))) {
    return t('inbox.syncing');
  }
  if (searchOffline || shown.some(({ state }) => offline(state))) {
    return t('inbox.offline');
  }
  return unread === 0
    ? t('inbox.noUnread')
    : t('inbox.unread', { count: unread });
}

// Section data lets the native list virtualize online pages together with saved rows.
const searchSections = <T,>(
  saved: ReadonlyArray<Readonly<{ key: string; data: readonly T[] }>>,
  online: Readonly<{
    searching: boolean;
    found?: Readonly<{ results: readonly T[] }> | undefined;
  }>,
) => [
  ...saved,
  ...(online.found === undefined && !online.searching
    ? []
    : [{ key: 'gmail', data: online.found?.results ?? [] }]),
];

// Outbox and Drafts come before received mail; a search lists matching messages alone.
function inboxSections<M>({
  outbox,
  canCompose,
  drafts,
  messages,
  online,
  searching,
}: Readonly<{
  outbox: readonly OutboxSnapshotEntry[];
  canCompose: boolean;
  drafts: readonly Draft[];
  messages: ReadonlyArray<Readonly<{ key: string; data: readonly M[] }>>;
  online: Readonly<{
    searching: boolean;
    found?: Readonly<{ results: readonly M[] }> | undefined;
  }>;
  searching: boolean;
}>) {
  const outboxRows =
    searching || !canCompose
      ? []
      : outbox.map((entry): OutboxItem | DraftItem | M => ({ outbox: entry }));
  const draftRows = searching
    ? []
    : drafts.map((draft): OutboxItem | DraftItem | M => ({ draft }));
  return [
    ...(outboxRows.length === 0 ? [] : [{ key: 'outbox', data: outboxRows }]),
    ...(draftRows.length === 0 ? [] : [{ key: 'drafts', data: draftRows }]),
    ...(searching
      ? searchSections<OutboxItem | DraftItem | M>(messages, online)
      : messages),
  ];
}

const hasNoMail = ({
  ready,
  syncing,
  count,
}: Readonly<{ ready: boolean; syncing: boolean; count: number }>) =>
  ready && !syncing && count === 0;

// A mail server an explicit online search could not reach, which the subtitle reports as Offline.
const searchOffline = (search: ReturnType<typeof useGmailSearch>) =>
  search.found?.failures.some(({ reason }) => reason === 'offline') === true;

// Below the Inbox: its empty state, loading rows, the Language control and the storage note.
function InboxFooter({
  empty,
  syncing,
  connected,
  limited,
  children,
}: {
  readonly empty: boolean;
  readonly syncing: boolean;
  // Whether a signed-in account's mail, rather than sample messages, is listed.
  readonly connected: boolean;
  // Whether the listed Gmail view keeps only its newest messages.
  readonly limited: boolean;
  // The empty state.
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      {empty ? children : null}
      {syncing ? <SkeletonRows /> : null}
      <LanguageSelector />
      {limited ? (
        <Text style={[styles.footer, { color: colors.textSecondary }]}>
          {t('inbox.footerView', { provider: t('mailProviders.gmail') })}
        </Text>
      ) : null}
      <Text style={[styles.footer, { color: colors.textSecondary }]}>
        {connected ? t('inbox.footerConnected') : t('inbox.footer')}
      </Text>
    </>
  );
}

export function Inbox({
  selected,
  onSelect,
  onSelectBehindComposer,
  onClose,
  onBack,
  onCompose,
  composing,
  view = allInboxes,
  onView = keepView,
}: InboxProps) {
  const reporting = use(ErrorReportingContext);
  const mailboxes = useMailboxes();
  const leave = useLeaveComposer();
  const select = async (selection: Selection) => {
    if (onSelectBehindComposer !== undefined) {
      reporting.breadcrumb({ operation: 'reader', stage: 'open' });
      onSelectBehindComposer(selection);
      return;
    }
    if (await leave()) {
      reporting.breadcrumb({ operation: 'reader', stage: 'open' });
      onSelect(selection);
    }
  };
  const draftState = useDrafts();
  const outbox = useOutboxEntries();
  const drafts = listedDrafts(draftState, onCompose !== undefined);
  const openDraft = useOpenDraft(composing, onCompose ?? composeNothing);
  const reload = useReloadMailboxes();
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const profile = useProfile();
  const search = useRef<TextInput>(null);
  const insets = useSafeAreaInsets();
  const connections = profileMailboxes(account?.mailboxes ?? [], profile);
  // Connections waiting for provider authorization have no Inbox until it is given again.
  const { keepsChoice, chosenWaiting, waiting } = inboxChoice({
    mailboxes,
    connections,
    view,
  });
  // A plain conditional of the view, so React Compiler can preserve the memo below.
  const scope = keepsChoice ? view.mailbox : undefined;
  const scoped = useMemo(() => ({ profile, mailbox: scope }), [profile, scope]);
  const shown = mailboxes.filter(
    ({ id }) => scope === undefined || id === scope,
  );
  // With more than one mailbox, every row and notice names its own.
  const several = (account === undefined ? mailboxes : connections).length > 1;
  const gmail = account !== undefined;
  const inboxListed = useMemo(
    () => inboxMessages(mailboxes, scoped),
    [mailboxes, scoped],
  );
  const {
    folder,
    selection,
    title: folderName,
    listed,
    failure,
    limited,
  } = useMailboxFolder(shown, inboxListed, {
    view,
    onView,
  });
  const searchState = useInboxSearch(search, {
    mailboxes,
    shown,
    listed,
    profile,
    scoped,
    several,
    folder,
  });
  const { searching, searched, results, online } = searchState;
  // Search widened to every Inbox lists Inbox mail, whatever view the list shows.
  const origin = searchState.searchesAll
    ? { view: inboxFolder, selection: {} }
    : { view: folder, selection };
  // Asked again when a result is opened or the reader closes, since opening saves the body.
  const saved = useSavedBodies(
    results,
    selected === undefined ? '' : `${selected.mailbox}\n${selected.id}`,
  );
  const now = useNow();
  const filtering = useInboxFilter({ scope, mailboxes, listed, now });
  const inboxRows = filtering.rows;
  // Search keeps iPad's day groups beneath Top Results; iPhone lists matches without dividers.
  const dated = useMemo(
    () =>
      searching
        ? [
            { key: 'saved', data: ipad ? [] : (results ?? []) },
            ...(ipad && (results?.length ?? 0) > 0
              ? messageDateSections(results ?? [], now)
              : []),
          ]
        : messageDateSections(inboxRows, now),
    [searching, results, inboxRows, now],
  );
  const sections = inboxSections({
    ...profileDrafts({
      drafts,
      outbox,
      account,
      profile,
    }),
    canCompose: onCompose !== undefined,
    messages: dated,
    online,
    searching,
  });
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(
    () => ({ selected, saved, composing }),
    [selected, saved, composing],
  );
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(({ state }) => checking(state));
  const scopeName = scopeOf(t, shown, {
    several,
    gmail,
    waiting: chosenWaiting,
  });
  const status = statusOf(t, shown, {
    unread: listed.filter(({ message }) => message.unread).length,
    searchOffline: searchOffline(online),
    waiting: chosenWaiting,
  });
  const title =
    folderName ??
    t(ipad && scope === undefined ? 'inbox.unifiedTitle' : 'inbox.title');
  // Pulling down synchronizes the shown mailboxes' listed view after registration verifies, as Try
  // again does. The control ignores further pulls until it settles, so they start no duplicate work.
  const [refreshing, setRefreshing] = useState(false);
  const loadShown = async () => {
    await Promise.all(
      shown.map(({ inbox }) =>
        folder !== inboxFolder && 'openFolder' in inbox
          ? inbox.openFolder(folder)
          : inbox.load(),
      ),
    );
  };
  const refresh = async () => {
    setRefreshing(true);
    try {
      await (account === undefined
        ? loadShown()
        : account.refreshInbox(loadShown));
    } catch {
      // Each mailbox reports its own failure above the list, which keeps its saved mail.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    setRefreshing(false);
  };

  // A listed message's actions at its provider; one that takes the open message away closes it.
  const rowActions = (
    mailbox: InboxMailbox,
    message: Message | GmailMessage | ImapMessage,
  ): readonly RowAction[] => {
    const { state, inbox } = mailbox;
    const leaving = (away: boolean) => {
      if (
        away &&
        selected?.mailbox === mailbox.id &&
        message.id === selected.id
      ) {
        onClose?.();
      }
    };
    if (state.kind !== 'ready') {
      return [];
    }
    if ('openFolder' in inbox && 'imap' in state && 'folder' in message) {
      return imapQuickActions(t, message, state).map(
        ({ name, label, action }) => ({
          name,
          label,
          run: () => {
            leaving(action.kind !== 'read' && action.kind !== 'unread');
            void inbox.organize(message, action);
          },
        }),
      );
    }
    if (
      'resolvePending' in inbox &&
      'organize' in state &&
      state.organize &&
      'threadId' in message
    ) {
      return quickActions(t, message, {
        provider: mailbox.provider ?? 'gmail',
        unavailableActions: state.unavailableActions,
        view: origin.view,
      }).map(({ name, label, action }) => ({
        name,
        label,
        run: () => {
          leaving(
            leavesView(
              gmailViewName(state, selected?.folder ?? inboxFolder),
              message.labels ?? [],
              action,
            ),
          );
          void inbox.organize(message, action);
        },
      }));
    }
    return [];
  };
  const empty = (
    <View style={styles.empty}>
      <View style={styles.emptyIcon}>
        <SFSymbol
          name="tray.2"
          size={emptySymbolSize}
          color={colors.textSecondary}
        />
      </View>
      <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>
        {t('inbox.empty')}
      </Text>
      <Text style={[styles.emptyText, { color: colors.textSecondary }]}>
        {filtering.hidesAll
          ? t('filters.emptyDetail')
          : t('inbox.emptyDetail', { scope: folderName ?? scopeName })}
      </Text>
    </View>
  );
  return (
    // The floating bar rises above the software keyboard while its search field is in use. The safe
    // area keeps its bottom inset as a margin, so the keyboard's overlap discounts it. The surface
    // fills those margins too, behind the status bar and home indicator.
    <KeyboardAvoidingView
      behavior="padding"
      keyboardVerticalOffset={-insets.bottom}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <SafeAreaView
        edges={{ top: true, bottom: true, left: true }}
        style={styles.fill}>
        <View style={styles.fill}>
          <InboxHeading
            account={account}
            detail={selected !== undefined || composing !== undefined}
            onClose={onClose}
            onBack={onBack}
            onLeave={leave}
            onSearch={ready ? searchState.open : undefined}>
            <SearchHeading search={searchState}>
              <HeadingTitle
                onBack={onBack}
                title={title}
                subtitle={t('inbox.subtitleLabel', {
                  scope: scopeName,
                  status,
                })}
              />
            </SearchHeading>
          </InboxHeading>
          <View style={styles.notices}>
            {failure === undefined ? null : (
              <Notice
                icon="exclamationmark.triangle"
                iconColor={colors.statusWarning}
                message={failure}
                messageRole="alert"
              />
            )}
            {shown.map((mailbox) => (
              <MailboxScope
                key={mailbox.id}
                id={mailbox.id}>
                <MailboxStatus
                  address={several ? mailbox.address : undefined}
                />
              </MailboxScope>
            ))}
            {waiting.map((mailbox) =>
              mailbox.provider === 'imap' ? (
                <ImapAuthorizationNeeded
                  key={mailbox.id}
                  address={mailbox.address}
                  onRepair={() => {
                    account?.openAccount('mailboxes');
                  }}
                />
              ) : (
                <AuthorizationNeeded
                  key={mailbox.id}
                  address={mailbox.address}
                  provider={mailbox.provider}
                  onAllow={async () => {
                    await account?.authorizeMailbox(mailbox.id);
                    await reload();
                  }}
                />
              ),
            )}
          </View>
          <SectionList
            accessibilityLabel={t('inbox.messages')}
            contentContainerStyle={styles.list}
            refreshing={refreshing}
            onRefresh={() => {
              void refresh();
            }}
            sections={sections}
            stickySectionHeadersEnabled={false}
            renderSectionHeader={({ section }) => {
              if (section.key === 'outbox') {
                return <OutboxHeading />;
              }
              if (section.key === 'drafts') {
                return <DraftHeading />;
              }
              if (section.key === 'gmail') {
                return (
                  <OnlineHeading
                    search={online}
                    several={several}
                  />
                );
              }
              const [first] = section.data;
              if (searching && section.key === 'saved') {
                const count =
                  (results?.length ?? 0) + (online.found?.results.length ?? 0);
                return count > 0 ? (
                  <Text
                    accessibilityLabel={t('search.topResultsLabel', {
                      count,
                      scope: searchState.searchesAll
                        ? t('inbox.allInboxes')
                        : scopeName,
                    })}
                    accessibilityLiveRegion="polite"
                    accessibilityRole="header"
                    style={[
                      styles.resultsHeader,
                      { color: colors.textSecondary },
                    ]}>
                    {t('search.topResults')}
                  </Text>
                ) : null;
              }
              return section.key === 'saved' ||
                first === undefined ||
                !('message' in first) ? null : (
                <DateDivider
                  receivedAt={first.message.receivedAt}
                  now={now}
                />
              );
            }}
            extraData={rows}
            keyExtractor={(item) => {
              if ('outbox' in item) {
                return `outbox\n${item.outbox.id}`;
              }
              return 'draft' in item
                ? `draft\n${item.draft.id}`
                : resultKey(item);
            }}
            ListHeaderComponent={onCompose === undefined ? null : <DraftList />}
            ListFooterComponent={
              searching ? (
                <OnlineResults
                  query={searched}
                  search={online}
                />
              ) : (
                <InboxFooter
                  connected={gmail}
                  limited={limited}
                  empty={hasNoMail({ ready, syncing, count: inboxRows.length })}
                  syncing={syncing}>
                  {empty}
                </InboxFooter>
              )
            }
            ListFooterComponentStyle={styles.listFooter}
            renderSectionFooter={({ section }) =>
              searching &&
              section.key === 'saved' &&
              ready &&
              results?.length === 0 ? (
                <Text style={[styles.notice, { color: colors.textSecondary }]}>
                  {t('search.empty', { query: searched })}
                </Text>
              ) : null
            }
            renderItem={({ item, section }) => {
              if ('outbox' in item) {
                return (
                  <OutboxRow
                    entry={item.outbox}
                    onOpen={openDraft}
                  />
                );
              }
              return 'draft' in item ? (
                <DraftRow
                  draft={item.draft}
                  onOpen={openDraft}
                  selected={composing === item.draft.id}
                />
              ) : (
                <MessageRow
                  mailbox={several ? item.mailbox.address : undefined}
                  message={item.message}
                  actions={
                    section.key === 'gmail'
                      ? undefined
                      : rowActions(item.mailbox, item.message)
                  }
                  now={now}
                  query={searching ? searched : undefined}
                  onSelect={() => {
                    void select({
                      mailbox: item.mailbox.id,
                      id: item.message.id,
                      ...(section.key === 'gmail' ? {} : origin.selection),
                    });
                  }}
                  selected={
                    selected?.mailbox === item.mailbox.id &&
                    selected.id === item.message.id
                  }
                  status={
                    section.key === 'gmail' || !searching
                      ? undefined
                      : savedStatus(t, saved?.get(resultKey(item)))
                  }
                />
              );
            }}
          />
          <InboxBar
            field={search}
            filter={filtering}
            hidden={composing !== undefined}
            onCompose={onCompose}
            ready={ready}
            scope={scope}
            search={searchState}
          />
        </View>
      </SafeAreaView>
    </KeyboardAvoidingView>
  );
}
