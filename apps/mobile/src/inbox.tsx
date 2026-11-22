import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { Draft } from '@private-email/mail-core/drafts';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { GmailMessage } from '@private-email/mail-core/inbox-store';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { MailProvider } from '@private-email/mail-core/registration';
import type {
  ComponentProps,
  ContextType,
  ReactElement,
  ReactNode,
} from 'react';
import type { TextInputInstance } from 'react-native';

import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
import { buttonStyle, controlSize, tint } from '@expo/ui/swift-ui/modifiers';
import { lastUpdated } from '@private-email/localization';
import { commandTarget } from '@private-email/mail-core/commands';
import { draftsOf, profileDrafts } from '@private-email/mail-core/drafts';
import {
  leavesView,
  paletteOnly,
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
  sectionShown,
} from '@private-email/mail-core/mailboxes';
import { profileName } from '@private-email/mail-core/profile-windows';
import { spacing } from '@private-email/mail-core/theme';
import {
  use,
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
} from 'react';
import { SectionList, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { RowAction } from './inbox-rows.tsx';
import type { useGmailSearch } from './mailbox.tsx';
import type { InboxMailbox } from './private-storage.ts';
import type { MailboxView } from './sidebar.tsx';

import { PaletteHint } from './command-palette.tsx';
import {
  DraftHeading,
  DraftList,
  DraftRow,
  useOpenDraft,
} from './composer.tsx';
import { Button, Notice, SFSymbol } from './design.tsx';
import { ErrorReportingContext } from './error-reporting.tsx';
import { FolderChoice } from './folder-choice.tsx';
import {
  KeyboardLift,
  useBarIndicatorInsets,
  useListBottomInset,
  WindowBarContext,
} from './inbox-bar.tsx';
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
  InboxToolbar,
  SearchFooter,
  SearchHeading,
  useInboxSearch,
} from './inbox-search.tsx';
import { emptySymbolSize, ipad, styles } from './inbox-styles.ts';
import {
  InboxPreferencesContext,
  usePreferencesUnreadable,
  useReadSections,
} from './list-density.tsx';
import { useLocalization } from './localization.ts';
import { useListedMailbox } from './mailbox-folders.tsx';
import { useNow } from './mailbox-state.ts';
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
  OutboxRow,
  forgetRetired,
  useOutboxActions,
  useOutboxView,
} from './outbox.tsx';
import { usePinAction, usePinned } from './pins.tsx';
import { AccountContext } from './registration-gate.tsx';
import {
  SyncStatusCapsule,
  useToolbarPause,
  checking,
  offline,
  refused,
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
  // Each new value ends a search and scrolls to the top of the Outbox, as when View in Outbox shows
  // it.
  readonly outboxShown?: object | undefined;
  // Whether the composer, expanded to the regular-width window, covers the list.
  readonly covered?: boolean;
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

// All Inboxes' preferences could not be read, so it lists no connection until Try Again reads them;
// the Outbox lists its own messages and says nothing of them.
function PreferencesNotice({
  unreadable,
  outbox,
}: Readonly<{ unreadable: boolean; outbox: boolean }>) {
  const { t } = useLocalization();
  const preferences = use(InboxPreferencesContext);
  return unreadable && !outbox ? (
    <Notice
      icon="exclamationmark.triangle"
      message={t('mailboxes.preferencesFailed')}
      messageRole="alert">
      <Button
        label={t('common.retry')}
        onPress={() => {
          void preferences.load();
        }}
      />
    </Notice>
  ) : null;
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
    everyHidden,
    gmail,
    waiting,
  }: Readonly<{
    // Whether the list is a Unified Mailbox, which spans every mailbox.
    unified: boolean;
    several: boolean;
    // Whether the Profile hides every connection, so All Inboxes names none, not even its provider.
    everyHidden: boolean;
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
  if (several || everyHidden) {
    return t('inbox.allInboxes');
  }
  return gmail ? t('inbox.gmail') : t('inbox.subtitle');
}

// The provider of a shown connection that needs sign-in again. iPad's subtitle names it after the
// count, in place of the scope and update time, as the frames draw it; a chosen connection waiting
// for authorization already says so in its status.
const signInOf = (
  shown: readonly InboxMailbox[],
  {
    waiting,
    chosen,
  }: Readonly<{
    waiting: ReadonlyArray<Readonly<{ provider: MailProvider }>>;
    // Whether the list shows a chosen connection waiting for authorization.
    chosen: boolean;
  }>,
): MailProvider | undefined =>
  ipad && !chosen
    ? [
        ...shown.flatMap(({ provider, state }) =>
          refused(state) ? [provider ?? 'gmail'] : [],
        ),
        ...waiting.map(({ provider }) => provider),
      ][0]
    : undefined;

// The heading's scope and status. A Mail Profile without mailboxes says so instead; iPad's sidebar
// Profile Switcher names the Profile, and iPhone's heading names it too.
const subtitleOf = (
  t: Translate,
  unconnected: Readonly<{ name: string }> | undefined,
  {
    signIn,
    title,
    ...label
  }: Readonly<{
    scope: string;
    status: string;
    signIn: MailProvider | undefined;
    title: string;
  }>,
) => {
  if (signIn !== undefined) {
    return t('inbox.statusSignIn', {
      status: label.status,
      provider: t(`mailProviders.${signIn}`),
    });
  }
  if (unconnected === undefined) {
    // The heading already names a scope it shares, as iPad's All Inboxes does.
    return label.scope === title
      ? label.status
      : t('inbox.subtitleLabel', label);
  }
  return ipad
    ? t('profiles.noMailboxes')
    : t('inbox.subtitleLabel', {
        scope: unconnected.name,
        status: t('profiles.noMailboxes'),
      });
};

// The subtitle's status: checking the server, cut off from it, how much of All Mail's history has
// downloaded, or how much is unread and, on iPad, when the shown Inboxes were last brought up to
// date. iPhone's one-line heading has no room for it; its Sync Status details show it instead.
function statusOf(
  t: Translate,
  shown: readonly InboxMailbox[],
  {
    unread,
    searchOffline,
    waiting,
    downloading,
    now,
    inbox,
    signIn,
  }: Readonly<{
    unread: number;
    // An explicit online search that found a mail server unreachable.
    searchOffline: boolean;
    // The chosen connection while it waits for authorization, whose unread mail is unknown.
    waiting: Readonly<{ provider: MailProvider }> | undefined;
    downloading: string | undefined;
    now: number;
    // Whether the Inbox is listed; another folder or view was not necessarily brought up to date.
    inbox: boolean;
    // Whether the subtitle names a connection that needs sign-in, in place of the update time.
    signIn: boolean;
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
  // iPhone's short heading says All read, as its frames draw it; iPad's keeps the Mac wording.
  const status =
    unread === 0
      ? t(ipad ? 'inbox.noUnread' : 'inbox.allRead')
      : t('inbox.unread', { count: unread });
  if (!ipad || !inbox || signIn) {
    return status;
  }
  const updated = lastUpdated(
    t,
    shown.flatMap(({ state }) =>
      state.kind === 'ready' &&
      'synchronizedAt' in state &&
      state.synchronizedAt !== undefined
        ? [state.synchronizedAt]
        : [],
    ),
    now,
  );
  return updated === undefined
    ? status
    : t('inbox.statusUpdated', { status, updated });
}

type OnlineSections<T> = Readonly<{
  found?:
    | Readonly<{
        results: readonly T[];
        failures: readonly unknown[];
        limited: readonly unknown[];
      }>
    | undefined;
}>;

// Section data lets the native list virtualize online pages together with saved rows. The section
// and its heading hold mail server rows and the connections it could not search; Searching and No
// Results stand alone beneath the saved results.
const searchSections = <T,>(
  saved: ReadonlyArray<Readonly<{ key: string; data: readonly T[] }>>,
  { found }: OnlineSections<T>,
) => [
  ...saved,
  ...(found !== undefined &&
  (found.results.length > 0 ||
    found.failures.length > 0 ||
    found.limited.length > 0)
    ? [{ key: 'gmail', data: found.results }]
    : []),
];

// The Outbox view shows its own heading over the Outbox alone, with no older mail or footer.
const withOutboxView = (
  outboxView: Readonly<{ title: string; subtitle: string }> | undefined,
  list: Readonly<{
    title: string;
    subtitle: string;
    onEndReached: () => void;
    footer: ReactElement;
  }>,
) =>
  outboxView === undefined
    ? list
    : {
        title: outboxView.title,
        subtitle: outboxView.subtitle,
        onEndReached: undefined,
        footer: undefined,
      };

// The Outbox view lists the Outbox alone. Otherwise Drafts come before received mail, and a search
// lists matching messages alone.
function inboxSections<M>({
  outbox,
  drafts,
  messages,
  online,
  searching,
}: Readonly<{
  // The Outbox view, while it shows the Outbox's messages.
  outbox: Readonly<{ entries: readonly OutboxSnapshotEntry[] }> | undefined;
  drafts: readonly Draft[];
  messages: ReadonlyArray<Readonly<{ key: string; data: readonly M[] }>>;
  online: OnlineSections<M>;
  searching: boolean;
}>) {
  if (outbox !== undefined) {
    return [
      {
        key: 'outbox',
        data: outbox.entries.map((entry): OutboxItem | DraftItem | M => ({
          outbox: entry,
        })),
      },
    ];
  }
  const draftRows = searching
    ? []
    : drafts.map((draft): OutboxItem | DraftItem | M => ({ draft }));
  return [
    ...(draftRows.length === 0 ? [] : [{ key: 'drafts', data: draftRows }]),
    ...(searching
      ? searchSections<OutboxItem | DraftItem | M>(messages, online)
      : messages),
  ];
}

// Whether the list's mailboxes have listed and are checking their servers. A connection All Inboxes
// leaves out, hidden or not yet known to be shown, says neither, as its mail is not listed: while
// the preferences are read, All Inboxes is loading, and with every connection hidden, even one
// waiting for sign-in, there is no mail to wait for.
const listState = (
  searched: readonly InboxMailbox[],
  preferences: Readonly<{ everyHidden: boolean; reading: boolean }>,
) => {
  if (preferences.everyHidden) {
    return { ready: true, syncing: false };
  }
  if (preferences.reading) {
    return { ready: false, syncing: true };
  }
  return {
    ready: searched.some(({ state }) => state.kind === 'ready'),
    syncing: searched.some(({ state }) => checking(state)),
  };
};

const hasNoMail = ({
  ready,
  syncing,
  count,
}: Readonly<{ ready: boolean; syncing: boolean; count: number }>) =>
  ready && !syncing && count === 0;

// A signed-in window's Profile that owns no mailbox has no Inbox, only a way to manage Profiles.
const unconnectedProfile = (
  t: Translate,
  account: ContextType<typeof AccountContext>,
  profile: string,
) =>
  account === undefined ||
  profileMailboxes(account.mailboxes, profile).length > 0
    ? undefined
    : {
        name: profileName(t, profile, account.profiles),
        manage: () => {
          account.openAccount('profiles');
        },
      };

// The empty Inbox: no mail arrived or Filter hides it all, or its Profile has no mailbox to list.
function EmptyInbox({
  detail,
  unconnected,
}: {
  readonly detail: string;
  readonly unconnected: ReturnType<typeof unconnectedProfile>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={styles.empty}>
      <View style={styles.emptyIcon}>
        <SFSymbol
          name="tray.2"
          size={emptySymbolSize}
          color={colors.textSecondary}
        />
      </View>
      <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>
        {unconnected === undefined ? t('inbox.empty') : t('inbox.noMailboxes')}
      </Text>
      <Text style={[styles.emptyText, { color: colors.textSecondary }]}>
        {unconnected === undefined
          ? detail
          : t('inbox.noMailboxesDetail', { profile: unconnected.name })}
      </Text>
      {unconnected === undefined ? null : (
        <View style={styles.emptyAction}>
          <Host matchContents>
            <SwiftUIButton
              label={t('profiles.manage')}
              // A Secondary button: the quiet fill with primary text, not the system blue tint.
              modifiers={[
                buttonStyle('bordered'),
                controlSize('large'),
                tint(colors.textPrimary),
              ]}
              onPress={() => {
                unconnected.manage();
              }}
            />
          </Host>
        </View>
      )}
    </View>
  );
}

// A mail server an explicit online search could not reach, which the subtitle reports as Offline.
const searchOffline = (search: ReturnType<typeof useGmailSearch>) =>
  search.found?.failures.some(({ reason }) => reason === 'offline') === true;

// Below the Inbox: its empty state, loading rows and the storage note.
function InboxFooter({
  unconnected,
  empty,
  syncing,
  connected,
  limited,
  downloading,
  oldest,
  now,
  children,
}: {
  // A Profile without mailboxes shows only its empty state, with no mail to wait for or keep.
  readonly unconnected: boolean;
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
  if (unconnected) {
    return children;
  }
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

// Asks again for the access a mailbox's provider refused, as its notice does: IMAP enters the
// password in Settings, and Gmail synchronizes again once access is authorized.
const authorizer = (
  account: ContextType<typeof AccountContext>,
  load: (loaded: readonly InboxMailbox[]) => () => Promise<void>,
) =>
  account === undefined
    ? undefined
    : (mailbox: InboxMailbox) => {
        if (mailbox.provider === 'imap') {
          account.openAccount('mailboxes');
          return;
        }
        void (async () => {
          await account.authorizeMailbox(mailbox.id);
          await load([mailbox])();
        })();
      };

// All Inboxes, its sign-in notices, and search there or widened to every Inbox, leave out every
// connection the Profile hides, and every one until the Profile's preferences are read: `unhidden`
// keeps the others, `inboxes` also the one the view scopes to, `reading` and
// `unreadable` say All Inboxes waits for the preferences or could not read them, `everyHidden` that
// the Profile hides every connection All Inboxes could show, `waiting` is what of `waiting` the list names, and `searched` is what of `shown` the list lists and refreshes, search covers,
// Filters offers, the heading names and the list reports the state of.
function useShownInboxes<W extends Readonly<{ id: string }>>({
  mailboxes,
  shown,
  waiting,
  profile,
  scope,
  unified,
}: Readonly<{
  mailboxes: readonly InboxMailbox[];
  shown: readonly InboxMailbox[];
  waiting: readonly W[];
  profile: string;
  scope: string | undefined;
  unified: MailboxView['unified'];
}>) {
  const sections = useReadSections(profile);
  const unreadable = usePreferencesUnreadable();
  const preferences = use(InboxPreferencesContext);
  // All Inboxes lists no connection until the preferences are read.
  const waits =
    unified === undefined &&
    scope === undefined &&
    sections === undefined &&
    mailboxes.length + waiting.length > 0;
  const inboxes = useMemo(
    () =>
      mailboxes.filter(
        ({ id }) =>
          id === scope ||
          (sections !== undefined && sectionShown(sections, id)),
      ),
    [mailboxes, scope, sections],
  );
  const unhidden = useMemo(
    () =>
      inboxes.filter(
        ({ id }) => sections !== undefined && sectionShown(sections, id),
      ),
    [inboxes, sections],
  );
  const named =
    unified === undefined
      ? waiting.filter(
          ({ id }) =>
            id === scope ||
            (sections !== undefined && sectionShown(sections, id)),
        )
      : waiting;
  const searched =
    unified === undefined
      ? shown.filter((mailbox) => inboxes.includes(mailbox))
      : shown;
  return {
    inboxes,
    unhidden,
    // The Inboxes search widened to every Inbox covers; undefined until the preferences are read.
    searchable: sections === undefined ? undefined : unhidden,
    reading: waits && !unreadable,
    unreadable: waits && unreadable,
    // A pull while All Inboxes waits for the preferences reads them again, and refreshes the
    // mailboxes they then show.
    reread: async () => {
      if (!waits) {
        return searched;
      }
      await preferences.load();
      const read = preferences.sections(profile);
      return read === undefined
        ? []
        : shown.filter(({ id }) => sectionShown(read, id));
    },
    everyHidden:
      unified === undefined &&
      sections !== undefined &&
      mailboxes.length + waiting.length > 0 &&
      inboxes.length === 0 &&
      named.length === 0,
    waiting: named,
    searched,
  };
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
  outboxShown,
  covered,
}: InboxProps) {
  const reporting = use(ErrorReportingContext);
  const mailboxes = useMailboxes();
  const pinned = usePinned(mailboxes.map(({ id }) => id));
  const pinAction = usePinAction();
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
  const { t, settings } = useLocalization();
  const profile = useProfile();
  const search = useRef<TextInputInstance>(null);
  const insets = useSafeAreaInsets();
  const inWindow = use(WindowBarContext) !== undefined;
  const listInset = useListBottomInset(visible !== false);
  const toolbar = usesToolbar(bar, onCompose);
  const indicatorInsets = useBarIndicatorInsets(toolbar);
  const connections = profileMailboxes(account?.mailboxes ?? [], profile);
  // Connections waiting for provider authorization have no Inbox until it is given again.
  const {
    keepsChoice,
    chosenWaiting,
    waiting: allWaiting,
  } = inboxChoice({
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
  const unconnected = unconnectedProfile(t, account, profile);
  // With more than one mailbox, every row and notice names its own.
  const several = (account === undefined ? mailboxes : connections).length > 1;
  const gmail = account !== undefined;
  const {
    inboxes,
    unhidden,
    searchable,
    reading,
    unreadable,
    reread,
    everyHidden,
    waiting,
    searched: searchedMailboxes,
  } = useShownInboxes({
    mailboxes,
    shown,
    waiting: allWaiting,
    profile,
    scope,
    unified: view.unified,
  });
  const inboxListed = useMemo(
    () => inboxMessages(inboxes, scoped),
    [inboxes, scoped],
  );
  const {
    folder,
    title: folderName,
    listed,
    unlisted,
    failure,
    limited,
    downloading,
    missing,
    folderOf: listedFolder,
    showOlder,
  } = useListedMailbox(searchedMailboxes, inboxListed, { view, onView });
  const searchState = useInboxSearch(search, {
    mailboxes: unhidden,
    shown: searchedMailboxes,
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
  const filtering = useInboxFilter({
    scope,
    mailboxes: searchedMailboxes,
    listed,
    now,
  });
  const inboxRows = filtering.rows;
  // Search keeps iPad's day groups beneath Top Results; iPhone lists matches without dividers.
  const dated = useMemo(
    () =>
      searching
        ? [
            { key: 'saved', data: ipad ? [] : (results ?? []) },
            ...(ipad && (results?.length ?? 0) > 0
              ? messageDateSections(results ?? [], now, settings.timeZone)
              : []),
          ]
        : messageDateSections(inboxRows, now, settings.timeZone),
    [searching, results, inboxRows, now, settings.timeZone],
  );
  const outboxView = useOutboxView({
    chosen: view.outbox === true,
    onEmptied: () => {
      onView(allInboxes);
    },
    canCompose: onCompose !== undefined,
    searching,
  });
  const sections = inboxSections({
    drafts: profileDrafts({ drafts, outbox: [], account, profile }).drafts,
    outbox: outboxView,
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
      outboxView === undefined,
      searching,
      searched,
      searchState.searchesAll,
      filtering.on,
      filtering.filter,
      // Hiding a connection, or a failed read, leaves its rows out at once.
      ...searchedMailboxes.map(({ inbox }) => inbox),
      ...searchedMailboxes.map(({ state }) => state.kind === 'ready'),
    ],
    keyOf: rowKey,
    contentOf: rowContent,
    selected,
    ...organizingWork(searchedMailboxes),
    visible: visible !== false,
  });
  // The rows the list shows, with leaving rows beside their former neighbours.
  const placed = motion.place();
  const list =
    useRef<
      SectionList<
        (typeof placed)[number]['data'][number],
        (typeof placed)[number]
      >
    >(null);
  // View in Outbox ends a search, which lists mail instead, then scrolls to the top of the Outbox.
  const scrolledFor = useRef(outboxShown);
  const closeSearch = useEffectEvent(() => {
    searchState.close();
  });
  const scrollToOutbox = useEffectEvent(() => {
    if (placed.length > 0) {
      list.current?.scrollToLocation({ sectionIndex: 0, itemIndex: 0 });
    }
  });
  useEffect(() => {
    if (outboxShown === undefined || scrolledFor.current === outboxShown) {
      return;
    }
    if (searching) {
      closeSearch();
      return;
    }
    scrolledFor.current = outboxShown;
    scrollToOutbox();
  }, [outboxShown, searching]);
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(
    () => ({ selected, saved, composing }),
    [selected, saved, composing],
  );
  const { ready, syncing } = listState(searchedMailboxes, {
    everyHidden,
    reading,
  });
  // A hidden connection's name stays out of All Inboxes, as its mail does.
  const scopeName = scopeOf(t, searchedMailboxes, {
    unified: view.unified !== undefined,
    several,
    everyHidden,
    gmail,
    waiting: chosenWaiting,
  });
  const signIn = signInOf(searchedMailboxes, {
    waiting,
    chosen: chosenWaiting !== undefined,
  });
  const status = statusOf(t, searchedMailboxes, {
    unread: listed.filter(({ message }) => message.unread).length,
    searchOffline: searchOffline(online),
    waiting: chosenWaiting,
    downloading,
    now,
    inbox: view.unified === undefined && folder === inboxFolder,
    signIn: signIn !== undefined,
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
  // Synchronizing clears a recovered connection's status; a listed IMAP folder is read again after
  // it, since the folder read hides an evicted folder's rows from the synchronization's body prune.
  const load = (loaded: readonly InboxMailbox[]) => async () => {
    await Promise.allSettled(
      loaded.map(async ({ inbox }) => {
        await inbox.load();
        if (folder !== inboxFolder && 'openFolder' in inbox) {
          await inbox.openFolder(folder);
        }
      }),
    );
  };
  const refresh = async () => {
    setRefreshing(true);
    try {
      const loadShown = load(await reread());
      await (account === undefined
        ? loadShown()
        : account.refreshInbox(loadShown));
    } catch {
      // The Sync Status Capsule reports a failure, and the list keeps its saved mail.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    setRefreshing(false);
  };
  // Try Again synchronizes only the mailboxes that need attention, and like a pull shows its
  // progress at once.
  const tryAgain = async (loaded: readonly InboxMailbox[]) => {
    try {
      await (account === undefined
        ? load(loaded)()
        : account.refreshInbox(load(loaded)));
    } catch {
      // The Sync Status Capsule reports a failure, and the list keeps its saved mail.
    }
  };
  const { details, paused } = useToolbarPause(searchedMailboxes, toolbar);
  const syncCapsule = (
    <SyncStatusCapsule
      shown={searchedMailboxes}
      refreshing={refreshing}
      now={now}
      onTryAgain={tryAgain}
      onAuthorize={authorizer(account, load)}
      toolbar={details}
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
    const pin = pinAction(mailbox.id, message, pinned(mailbox.id, message));
    if ('openFolder' in inbox && 'imap' in state && 'folder' in message) {
      return [
        pin,
        ...imapQuickActions(t, message, state).map(
          ({ name, label, action }) => ({
            name,
            label,
            run: () => {
              leaving('destination' in action);
              void inbox.organize(message, action);
            },
          }),
        ),
      ];
    }
    if (
      'resolvePending' in inbox &&
      'organize' in state &&
      state.organize &&
      'threadId' in message
    ) {
      return [
        pin,
        ...quickActions(t, message, {
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
        })),
      ];
    }
    return [pin];
  };
  const empty = (
    <EmptyInbox
      unconnected={unconnected}
      detail={
        filtering.hidesAll
          ? t('filters.emptyDetail')
          : t('inbox.emptyDetail', { scope: folderName ?? scopeName })
      }
    />
  );
  const { onEndReached, footer, ...heading } = withOutboxView(outboxView, {
    title,
    subtitle: subtitleOf(t, unconnected, {
      scope: scopeName,
      status,
      signIn,
      title,
    }),
    onEndReached: showOlder,
    footer: searching ? (
      <SearchFooter
        search={searchState}
        mailboxes={searchable}
        shown={searchedMailboxes}
        ready={ready}
        unlisted={unlisted}
        scopeName={scopeName}
        folderName={folderName}
      />
    ) : (
      <InboxFooter
        unconnected={unconnected !== undefined}
        connected={gmail}
        limited={limited}
        downloading={downloading}
        oldest={listed.at(-1)}
        now={now}
        empty={hasNoMail({ ready, syncing, count: inboxRows.length })}
        syncing={syncing}>
        {empty}
      </InboxFooter>
    ),
  });
  return (
    // The surface fills the safe area's margins too, behind the status bar and home indicator.
    <View
      testID="inbox-surface"
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <SafeAreaView
        edges={{ top: true, bottom: inWindow, left: true }}
        style={styles.fill}>
        <View style={styles.fill}>
          <InboxHeading
            account={account}
            detail={selected !== undefined || composing !== undefined}
            onClose={onClose}
            bar={bar}
            searching={searching}
            onLeave={leave}
            onSearch={ready ? searchState.open : undefined}
            onView={onView}
            covered={covered}>
            <SearchHeading search={searchState}>
              <HeadingTitle
                bar={bar}
                title={heading.title}
                subtitle={heading.subtitle}
              />
            </SearchHeading>
          </InboxHeading>
          <SectionList
            ref={list}
            accessibilityLabel={t('inbox.messages')}
            automaticallyAdjustKeyboardInsets
            maintainVisibleContentPosition={keepPosition}
            onScrollBeginDrag={() => {
              motion.interrupt();
            }}
            onScroll={({ nativeEvent }) => {
              setKeepPosition(
                nativeEvent.contentOffset.y > 0 ? keepTopRow : undefined,
              );
            }}
            contentContainerStyle={[
              styles.list,
              { paddingBottom: styles.list.paddingBottom + listInset },
            ]}
            scrollIndicatorInsets={indicatorInsets}
            refreshing={refreshing}
            onRefresh={() => {
              void refresh();
            }}
            onEndReached={onEndReached}
            sections={placed}
            stickySectionHeadersEnabled={false}
            renderSectionHeader={({ section }) => {
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
            ListHeaderComponent={
              // The one-time hint and notices scroll with the messages, so larger text never
              // leaves the list without room.
              <>
                <View style={styles.listLead}>
                  <PaletteHint />
                  <View style={styles.notices}>
                    {failure === undefined ? null : (
                      <Notice
                        icon="exclamationmark.triangle"
                        iconColor={colors.statusWarning}
                        message={failure}
                        messageRole="alert"
                      />
                    )}
                    {missing.map(({ mailbox, detail }) => (
                      <Notice
                        key={`missing\n${mailbox.id}`}
                        icon="exclamationmark.triangle.fill"
                        iconColor={colors.statusWarning}
                        message={t('mailboxes.notIncluded', {
                          mailbox: mailbox.address ?? mailbox.id,
                        })}
                        detail={t(detail, {
                          view: folderName,
                          ...(ipad ? {} : { context: 'iphone' }),
                        })}>
                        {account !== undefined &&
                        detail === 'mailboxes.notIncludedSpamTrash' &&
                        mailbox.state.kind === 'ready' &&
                        'folders' in mailbox.state ? (
                          <FolderChoice
                            address={mailbox.address ?? mailbox.state.address}
                            folders={mailbox.state.folders}
                            marked={mailbox.state.marked}
                            saved={
                              account.mailboxes.find(
                                ({ id }) => id === mailbox.id,
                              )?.folders
                            }
                            onSave={(chosen) =>
                              account.chooseFolders(mailbox.id, chosen)
                            }
                          />
                        ) : null}
                      </Notice>
                    ))}
                    <PreferencesNotice
                      unreadable={unreadable}
                      outbox={outboxView !== undefined}
                    />
                    {searchedMailboxes.map((mailbox) => (
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
                </View>
                {onCompose === undefined ? null : <DraftList />}
              </>
            }
            ListFooterComponent={footer}
            ListFooterComponentStyle={styles.listFooter}
            renderItem={({ item, section, index }) => {
              if ('outbox' in item) {
                const { draft, invitation } = item.outbox;
                return (
                  <OutboxRow
                    actions={outboxActions.actions}
                    entry={item.outbox}
                    onOpenInvitation={
                      invitation === undefined
                        ? undefined
                        : () => {
                            void select({
                              mailbox: draft.connection,
                              id: invitation.message,
                            });
                          }
                    }
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
                    pinned={pinned(item.mailbox.id, item.message)}
                    actions={
                      // A server result offers only Pin, which needs no provider access.
                      section.key === 'gmail'
                        ? [
                            pinAction(
                              item.mailbox.id,
                              item.message,
                              pinned(item.mailbox.id, item.message),
                            ),
                          ]
                        : rowActions(item.mailbox, item.message).filter(
                            ({ name }) => !paletteOnly(name),
                          )
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
                    reader={
                      selected?.mailbox === item.mailbox.id &&
                      selected.id === item.message.id
                        ? commandTarget(item.mailbox.id, item.message)
                        : undefined
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
          <InboxControls
            toolbar={toolbar}
            sticky={!inWindow}
            stickyOffset={insets.bottom + spacing.xs - spacing.m}
            listNotice={syncCapsule}
            paused={paused}
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
    </View>
  );
}

// The system toolbar holds New Message, so it needs onCompose (#1534).
function usesToolbar(bar: boolean | undefined, onCompose: unknown) {
  return bar === true && onCompose !== undefined;
}

// iPhone's single column uses the system toolbar and its search (#1534). Elsewhere the floating bar
// rides on the software keyboard while its search field is in use, moving with it frame by frame.
// It sits 4pt above the home indicator's safe area and 12pt above the keyboard, as the frames show.
// The window bar already lifts the regular layout's capsule, so it doesn't follow the keyboard.
function InboxControls({
  toolbar,
  sticky,
  stickyOffset,
  paused,
  ...props
}: Parameters<typeof InboxBar>[0] & {
  readonly toolbar: boolean;
  readonly sticky: boolean;
  readonly stickyOffset: number;
  readonly paused: Parameters<typeof InboxToolbar>[0]['paused'];
}) {
  if (toolbar && props.onCompose !== undefined) {
    return (
      <InboxToolbar
        {...props}
        paused={paused}
        onCompose={props.onCompose}
      />
    );
  }
  return (
    <KeyboardLift
      enabled={sticky}
      opened={stickyOffset}
      testID="keyboard-bar">
      <InboxBar {...props} />
    </KeyboardLift>
  );
}
