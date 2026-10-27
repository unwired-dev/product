import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { Draft } from '@private-email/mail-core/drafts';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { MailProvider } from '@private-email/mail-core/registration';
import type { ComponentProps, ReactNode } from 'react';
import type { TextInput } from 'react-native';

import { draftsOf, profileDrafts } from '@private-email/mail-core/drafts';
import {
  allMail,
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
  motionIdentityOf,
  organizingWork,
  profileMailboxes,
  resultKey,
} from '@private-email/mail-core/mailboxes';
import {
  use,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
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
import {
  DateDivider,
  DownloadingOlder,
  MessageRow,
  SkeletonRows,
} from './inbox-rows.tsx';
import {
  InboxBar,
  OnlineResults,
  SearchHeading,
  useInboxSearch,
} from './inbox-search.tsx';
import { emptySymbolSize, ipad, styles } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { useListedMailbox } from './mailbox-folders.tsx';
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
import { MovingRow, useRowMotion } from './organize-motion.tsx';
import { OrganizeStatus } from './organize-status.tsx';
import {
  OutboxHeading,
  OutboxRow,
  forgetRetired,
  useOutboxActions,
} from './outbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import {
  SyncStatusCapsule,
  checking,
  failed,
  offline,
  syncStatusOf,
} from './sync-status.tsx';
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
  // The native list column has finished appearing.
  readonly visible?: boolean;
  readonly selected: Selection | undefined;
  readonly onSelect: (selection: Selection) => void;
  // A collapsed overlay keeps editing while the reader's selection changes beneath it.
  readonly onSelectBehindComposer?:
    | ((selection: Selection) => void)
    | undefined;
  // Closes the reader when a row action takes its message out of the Inbox.
  readonly onClose?: (() => void) | undefined;
  // iPhone's single column, whose navigation bar shows the title and returns to Mailboxes.
  readonly bar?: boolean;
  // Opens a Draft in the composer; without it the Inbox offers no Drafts.
  readonly onCompose?: ((id: string) => void) | undefined;
  readonly composing?: string | undefined;
  // The mailbox or folder the list shows; every mailbox of the Profile without one.
  readonly view?: MailboxView;
  readonly onView?: (view: MailboxView) => void;
}

const allInboxes: MailboxView = {};
const keepView = () => undefined;
// While the list is scrolled, synchronization keeps its topmost visible row in place; at the top,
// new mail, Drafts and the Outbox appear above what was shown.
const keepTopRow = { minIndexForVisible: 0 };

// A list row's identity, which a row keeps while it leaves and when it returns.
const rowKey = (
  item:
    | Readonly<{ outbox: OutboxSnapshotEntry }>
    | Readonly<{ draft: Draft }>
    | Parameters<typeof motionIdentityOf>[0],
) => {
  if ('outbox' in item) {
    return `outbox\n${item.outbox.id}`;
  }
  return 'draft' in item ? `draft\n${item.draft.id}` : motionIdentityOf(item);
};

// The displayed content is stable even when a Draft or Outbox row wrapper is recreated.
const rowContent = (item: Parameters<typeof rowKey>[0]) => {
  if ('outbox' in item) {
    return item.outbox;
  }
  return 'draft' in item ? item.draft : item.message;
};

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

// A Gmail mailbox whose grant was refused asks for access again; the Sync Status Capsule reports
// progress and other failures.
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
    state.sync !== 'authentication'
  ) {
    return null;
  }
  // Synchronizes again once access for this mailbox is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  return (
    <Notice
      announce="polite"
      icon="person.crop.circle.badge.exclamationmark"
      iconColor={colors.statusWarning}
      message={about(t, address, t('gmailSync.authentication', { provider }))}>
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

// An IMAP mailbox whose password was refused enters it again in Settings.
function ImapNotice({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const mailbox = useMailbox();
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  if (
    state.kind !== 'ready' ||
    !('imap' in state) ||
    state.status !== 'authentication'
  ) {
    return null;
  }
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
    unified,
    several,
    gmail,
    waiting,
  }: Readonly<{
    // Whether the list is a Unified Mailbox, which spans every mailbox.
    unified: boolean;
    several: boolean;
    gmail: boolean;
    // The chosen connection while it waits for authorization, which has no Inbox to show.
    waiting: Readonly<{ address: string }> | undefined;
  }>,
) {
  if (unified) {
    return t('mailboxes.allMailboxes');
  }
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

// The subtitle's status: checking the server, cut off from it, how much of All Mail's history has
// downloaded, or how much is unread.
function statusOf(
  t: Translate,
  shown: readonly InboxMailbox[],
  {
    unread,
    searchOffline,
    waiting,
    downloading,
  }: Readonly<{
    unread: number;
    // An explicit online search that found a mail server unreachable.
    searchOffline: boolean;
    // The chosen connection while it waits for authorization, whose unread mail is unknown.
    waiting: Readonly<{ provider: MailProvider }> | undefined;
    downloading: string | undefined;
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
  if (downloading !== undefined) {
    return downloading;
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

// Below the Inbox: its empty state, loading rows and the storage note.
function InboxFooter({
  empty,
  syncing,
  connected,
  limited,
  downloading,
  oldest,
  now,
  children,
}: {
  readonly empty: boolean;
  readonly syncing: boolean;
  // Whether a signed-in account's mail, rather than sample messages, is listed.
  readonly connected: boolean;
  // Says that the listed view keeps only its newest messages.
  readonly limited: string | undefined;
  // All Mail's history progress while its older mail downloads.
  readonly downloading: string | undefined;
  readonly oldest: ComponentProps<typeof DownloadingOlder>['oldest'];
  readonly now: number;
  // The empty state.
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      {empty ? children : null}
      {syncing ? <SkeletonRows /> : null}
      {downloading === undefined ? null : (
        <DownloadingOlder
          oldest={oldest}
          now={now}
        />
      )}
      {limited === undefined ? null : (
        <Text style={[styles.footer, { color: colors.textSecondary }]}>
          {limited}
        </Text>
      )}
      <Text style={[styles.footer, { color: colors.textSecondary }]}>
        {connected ? t('inbox.footerConnected') : t('inbox.footer')}
      </Text>
    </>
  );
}

export function Inbox({
  visible,
  selected,
  onSelect,
  onSelectBehindComposer,
  onClose,
  bar,
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
  useEffect(() => {
    forgetRetired(outbox);
  }, [outbox]);
  const drafts = listedDrafts(draftState, onCompose !== undefined);
  const openDraft = useOpenDraft(composing, onCompose ?? composeNothing);
  const outboxActions = useOutboxActions(openDraft);
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
    title: folderName,
    listed,
    failure,
    limited,
    downloading,
    missing,
    folderOf: listedFolder,
    showOlder,
  } = useListedMailbox(shown, inboxListed, { view, onView });
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
  // Search widened to every Inbox lists Inbox mail, whatever view the list shows; in a Unified
  // Mailbox each row is otherwise listed in its own connection's folder or view.
  const folderOf = (mailbox: string, id: string) =>
    searchState.searchesAll ? inboxFolder : listedFolder(mailbox, id);
  const selectionOf = (mailbox: string, id: string) => {
    const listedIn = folderOf(mailbox, id);
    return listedIn === inboxFolder ? {} : { folder: listedIn };
  };
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
  // Rows an organizing outcome takes away keep leaving, and rows it brings back return.
  const motion = useRowMotion({
    sections,
    scope: [
      profile,
      scope,
      folder,
      view.unified,
      searching,
      searched,
      searchState.searchesAll,
      filtering.on,
      filtering.filter,
      ...shown.map(({ inbox }) => inbox),
      ...shown.map(({ state }) => state.kind === 'ready'),
    ],
    keyOf: rowKey,
    contentOf: rowContent,
    selected,
    ...organizingWork(shown),
    visible: visible !== false,
  });
  // The rows the list shows, with leaving rows beside their former neighbours.
  const placed = motion.place();
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(
    () => ({ selected, saved, composing }),
    [selected, saved, composing],
  );
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(({ state }) => checking(state));
  const scopeName = scopeOf(t, shown, {
    unified: view.unified !== undefined,
    several,
    gmail,
    waiting: chosenWaiting,
  });
  const status = statusOf(t, shown, {
    unread: listed.filter(({ message }) => message.unread).length,
    searchOffline: searchOffline(online),
    waiting: chosenWaiting,
    downloading,
  });
  const title =
    folderName ??
    t(ipad && scope === undefined ? 'inbox.unifiedTitle' : 'inbox.title');
  // Set while the list is scrolled from its top, so synchronization keeps the reading position.
  const [keepPosition, setKeepPosition] = useState<typeof keepTopRow>();
  // Pulling down synchronizes the shown mailboxes' listed view after registration verifies, as Try
  // Again does. The control ignores further pulls until it settles, so they start no duplicate work.
  const [refreshing, setRefreshing] = useState(false);
  // Settles every mailbox, so one failing early cannot end the indicator while others still load.
  const load = (loaded: readonly InboxMailbox[]) => async () => {
    await Promise.allSettled(
      loaded.map(({ inbox }) =>
        folder !== inboxFolder && 'openFolder' in inbox
          ? inbox.openFolder(folder)
          : inbox.load(),
      ),
    );
  };
  const loadShown = load(shown);
  const refresh = async () => {
    setRefreshing(true);
    try {
      await (account === undefined
        ? loadShown()
        : account.refreshInbox(loadShown));
    } catch {
      // The Sync Status Capsule reports a failure, and the list keeps its saved mail.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    setRefreshing(false);
  };
  // Try Again synchronizes only the mailboxes whose server could not be reached, and like a pull
  // shows its progress at once.
  const [retrying, setRetrying] = useState(false);
  const tryAgain = async () => {
    setRetrying(true);
    const loadFailed = load(shown.filter(({ state }) => failed(state)));
    try {
      await (account === undefined
        ? loadFailed()
        : account.refreshInbox(loadFailed));
    } catch {
      // The Sync Status Capsule reports a failure, and the list keeps its saved mail.
    }
    setRetrying(false);
  };
  const syncCapsule = (
    <SyncStatusCapsule
      status={syncStatusOf(shown)}
      started={refreshing || retrying}
      onTryAgain={() => {
        void tryAgain();
      }}
    />
  );

  // A listed message's actions at its provider; one that takes the open message away closes it.
  const rowActions = (
    mailbox: InboxMailbox,
    message: Message | GmailMessage | ImapMessage,
  ): readonly RowAction[] => {
    const { state, inbox } = mailbox;
    const listedIn = folderOf(mailbox.id, message.id);
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
            leaving('destination' in action);
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
        view: listedIn,
      }).map(({ name, label, action }) => ({
        name,
        label,
        run: () => {
          leaving(
            leavesView(
              gmailViewName(
                state,
                selected?.folder ?? inboxFolder,
                mailbox.provider,
              ),
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
            bar={bar}
            searching={searching}
            onLeave={leave}
            onSearch={ready ? searchState.open : undefined}>
            <SearchHeading search={searchState}>
              <HeadingTitle
                bar={bar}
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
            {missing.map((mailbox) => (
              <Notice
                key={`missing\n${mailbox.id}`}
                icon="exclamationmark.triangle.fill"
                iconColor={colors.statusWarning}
                message={t('mailboxes.notIncluded', {
                  mailbox: mailbox.address ?? mailbox.id,
                })}
                detail={t(
                  view.unified === allMail
                    ? 'mailboxes.notIncludedAllMail'
                    : 'mailboxes.notIncludedDetail',
                  { view: folderName, ...(ipad ? {} : { context: 'iphone' }) },
                )}
              />
            ))}
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
            maintainVisibleContentPosition={keepPosition}
            onScrollBeginDrag={() => {
              motion.interrupt();
            }}
            onScroll={({ nativeEvent }) => {
              setKeepPosition(
                nativeEvent.contentOffset.y > 0 ? keepTopRow : undefined,
              );
            }}
            contentContainerStyle={styles.list}
            refreshing={refreshing}
            onRefresh={() => {
              void refresh();
            }}
            onEndReached={showOlder}
            sections={placed}
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
            keyExtractor={rowKey}
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
                  downloading={downloading}
                  oldest={listed.at(-1)}
                  now={now}
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
            renderItem={({ item, section, index }) => {
              if ('outbox' in item) {
                return (
                  <OutboxRow
                    actions={outboxActions.actions}
                    entry={item.outbox}
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
                <MovingRow
                  motion={motion.motionOf(rowKey(item))}
                  onSettled={() => {
                    motion.settle(rowKey(item));
                  }}>
                  <MessageRow
                    mailbox={
                      several || view.unified !== undefined
                        ? item.mailbox.address
                        : undefined
                    }
                    message={item.message}
                    actions={
                      section.key === 'gmail'
                        ? undefined
                        : rowActions(item.mailbox, item.message)
                    }
                    now={now}
                    // The next day's divider follows a day's last row.
                    beforeDivider={
                      index === section.data.length - 1 &&
                      placed[placed.indexOf(section) + 1]?.key.startsWith(
                        'saved\n',
                      ) === true
                    }
                    query={searching ? searched : undefined}
                    onSelect={() => {
                      motion.interrupt();
                      void select({
                        mailbox: item.mailbox.id,
                        id: item.message.id,
                        ...(section.key === 'gmail'
                          ? {}
                          : selectionOf(item.mailbox.id, item.message.id)),
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
                </MovingRow>
              );
            }}
          />
          <InboxBar
            listNotice={syncCapsule}
            field={search}
            filter={filtering}
            hidden={composing !== undefined}
            notice={outboxActions.toast}
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
