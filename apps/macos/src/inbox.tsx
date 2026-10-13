import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { Draft, OutboxEntry } from '@private-email/mail-core/drafts';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { MailProvider } from '@private-email/mail-core/registration';

import { draftsOf } from '@private-email/mail-core/drafts';
import {
  quickActions,
  restoreAfter,
} from '@private-email/mail-core/gmail-actions';
import { imapQuickActions } from '@private-email/mail-core/imap-actions';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  inboxMessages,
  messageDateSections,
  profileMailboxes,
  resultKey,
  searchMessages,
} from '@private-email/mail-core/mailboxes';
import {
  use,
  useDeferredValue,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  SectionList,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native';

import type { RowAction } from './inbox-rows.tsx';
import type { InboxMailbox } from './private-storage.ts';

import {
  DraftHeading,
  DraftList,
  DraftRow,
  useOpenDraft,
} from './composer.tsx';
import { Button, Chip, Notice, SFSymbol } from './design.tsx';
import { FolderPicker, useImapFolder } from './imap-folders.tsx';
import { DateDivider, MessageRow, SkeletonRows } from './inbox-rows.tsx';
import { styles } from './inbox-styles.ts';
import { Label } from './label.tsx';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization } from './localization.ts';
import {
  MailboxScope,
  useDrafts,
  useGmailSearch,
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
import { OrganizeStatus } from './organize.tsx';
import { OutboxHeading, OutboxRow } from './outbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

// The open-Draft callback for an Inbox without Drafts, stable so Draft rows stay memoized.
const composeNothing = () => undefined;

// A Draft as a row of the Inbox list, apart from received mail.
type DraftItem = Readonly<{ draft: Draft }>;
type OutboxItem = Readonly<{ outbox: OutboxEntry }>;

// The Drafts an Inbox lists: none where it offers no composer.
const listedDrafts = (
  state: Parameters<typeof draftsOf>[0],
  composing: boolean,
): readonly Draft[] => (composing ? draftsOf(state) : []);

// A message in a mailbox; Gmail message IDs are unique only within their mailbox.
export type Selection = Readonly<{ mailbox: string; id: string }>;

interface InboxProps {
  readonly selected: Selection | undefined;
  readonly onSelect: (selection: Selection) => void;
  // Closes the reader when a row action takes its message out of the Inbox.
  readonly onClose?: (() => void) | undefined;
  // Opens a Draft in the composer; without it the Inbox offers no Drafts.
  readonly onCompose?: ((id: string) => void) | undefined;
  readonly composing?: string | undefined;
}

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
// password is entered again on the account page.
function ImapNotice({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const mailbox = useMailbox();
  const account = use(AccountContext);
  const leave = useLeaveComposer();
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
  const openAccount = async () => {
    if (await leave()) {
      account?.openAccount();
    }
  };
  if (state.status === 'authentication') {
    return (
      <Notice
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
              void openAccount();
            }}
          />
        )}
      </Notice>
    );
  }
  return (
    <Notice
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

// Chooses every mailbox together, or one on its own.
function ScopePicker({
  mailboxes,
  scope,
  onScope,
}: {
  readonly mailboxes: readonly InboxMailbox[];
  readonly scope: string | undefined;
  readonly onScope: (scope: string | undefined) => void;
}) {
  const { t } = useLocalization();
  const choices = [
    { id: undefined, label: t('inbox.allInboxes') },
    ...mailboxes.map(({ id, address }) => ({ id, label: address ?? id })),
  ];
  return (
    <View style={styles.scopes}>
      {choices.map(({ id, label }) => (
        <Chip
          key={id ?? 'all'}
          icon={id === undefined ? 'tray.2' : 'tray'}
          label={label}
          selected={id === scope}
          onPress={() => {
            onScope(id);
          }}
        />
      ))}
    </View>
  );
}

// A search result's saved state, once known.
const savedStatus = (t: Translate, saved: boolean | undefined) => {
  if (saved === undefined) {
    return undefined;
  }
  return saved ? t('search.saved') : t('search.download');
};

// Gmail's own search, asked for explicitly below the results saved on this device, which it never
// replaces. Each mailbox that Gmail could not search says why.
function OnlineResults({
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
      <Pressable
        accessibilityLabel={t('search.online', { query })}
        accessibilityRole="button"
        onPress={() => {
          void search.search();
        }}>
        <Text style={[styles.notice, { color: colors.accentInk }]}>
          {t('search.online', { query })}
        </Text>
      </Pressable>
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
        <Pressable
          accessibilityLabel={t('search.more')}
          accessibilityRole="button"
          onPress={() => {
            void search.more();
          }}>
          <Text style={[styles.notice, { color: colors.accentInk }]}>
            {t('search.more')}
          </Text>
        </Pressable>
      ) : null}
      {!searching && found !== undefined && found.failures.length > 0 ? (
        <Pressable
          accessibilityLabel={t('search.retry')}
          accessibilityRole="button"
          onPress={() => {
            void search.search();
          }}>
          <Text style={[styles.notice, { color: colors.accentInk }]}>
            {t('search.retry')}
          </Text>
        </Pressable>
      ) : null}
    </View>
  );
}

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
  { several, gmail }: Readonly<{ several: boolean; gmail: boolean }>,
) {
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
  unread: number,
) {
  if (shown.some(({ state }) => checking(state))) {
    return t('inbox.syncing');
  }
  if (shown.some(({ state }) => offline(state))) {
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
  outbox: readonly OutboxEntry[];
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
    ...searchSections<OutboxItem | DraftItem | M>(messages, online),
  ];
}

const hasNoMail = ({
  ready,
  syncing,
  count,
}: Readonly<{ ready: boolean; syncing: boolean; count: number }>) =>
  ready && !syncing && count === 0;

function headingOf(
  t: Translate,
  {
    scope,
    folder,
    scopeName,
    status,
    shown,
    results,
    search,
  }: Readonly<{
    scope: string | undefined;
    folder: string | undefined;
    scopeName: string;
    status: string;
    shown: readonly InboxMailbox[];
    results: readonly unknown[] | undefined;
    search: ReturnType<typeof useGmailSearch>;
  }>,
) {
  const title =
    results === undefined
      ? (folder ??
        t(scope === undefined ? 'inbox.unifiedTitle' : 'inbox.title'))
      : t('search.title');
  const subtitle =
    results === undefined ||
    shown.some(({ state }) => checking(state) || offline(state))
      ? t('inbox.subtitleLabel', { scope: scopeName, status })
      : t('search.subtitleRegular', {
          count: results.length + (search.found?.results.length ?? 0),
          scope: scopeName,
        });
  return { title, subtitle, emptyScope: folder ?? scopeName };
}

export function Inbox({
  selected,
  onSelect,
  onClose,
  onCompose,
  composing,
}: InboxProps) {
  const mailboxes = useMailboxes();
  const leave = useLeaveComposer();
  const select = async (selection: Selection) => {
    if (await leave()) {
      onSelect(selection);
    }
  };
  // The account page replaces the Inbox, so an open composer is left first.
  const openAccount = async (open: () => void) => {
    if (await leave()) {
      open();
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
  const [chosen, setChosen] = useState<string>();
  // A removed mailbox's view falls back to every mailbox of the Profile.
  const scope = mailboxes.some(({ id }) => id === chosen) ? chosen : undefined;
  const view = useMemo(() => ({ profile, mailbox: scope }), [profile, scope]);
  const shown = mailboxes.filter(
    ({ id }) => scope === undefined || id === scope,
  );
  const connections = profileMailboxes(account?.mailboxes ?? [], profile);
  // Connections waiting for provider authorization have no Inbox until it is given again.
  const waiting =
    scope === undefined
      ? connections.filter(({ state }) => state === 'authorization')
      : [];
  // With more than one mailbox, every row and notice names its own.
  const several = (account === undefined ? mailboxes : connections).length > 1;
  const gmail = account !== undefined;
  const [query, setQuery] = useState('');
  // Typing stays responsive while the list catches up with the latest query.
  const searched = useDeferredValue(query.trim());
  const inboxListed = useMemo(
    () => inboxMessages(mailboxes, view),
    [mailboxes, view],
  );
  const { imap, folder, listed, failed, chooseFolder } = useImapFolder(
    shown,
    inboxListed,
  );
  // Searches only the mail saved on this device, so it works offline and asks Gmail nothing.
  const results = useMemo(
    () => (searched === '' ? undefined : searchMessages(listed, searched)),
    [listed, searched],
  );
  // Asked again when a result is opened or the reader closes, since opening saves the body.
  const saved = useSavedBodies(
    results,
    selected === undefined ? '' : `${selected.mailbox}\n${selected.id}`,
  );
  const online = useGmailSearch(shown, searched, view);
  const messages = results ?? listed;
  const now = useNow();
  const dated = useMemo(
    () => messageDateSections(messages, now),
    [messages, now],
  );
  const sections = inboxSections({
    outbox,
    canCompose: onCompose !== undefined,
    drafts,
    messages: dated,
    online,
    searching: results !== undefined,
  });
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(
    () => ({ selected, saved, composing }),
    [selected, saved, composing],
  );
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(({ state }) => checking(state));
  const scopeName = scopeOf(t, shown, { several, gmail });
  const status = statusOf(
    t,
    shown,
    listed.filter(({ message }) => message.unread).length,
  );
  const { title, subtitle, emptyScope } = headingOf(t, {
    scope,
    folder: folder === inboxFolder ? undefined : folder,
    scopeName,
    status,
    shown,
    results,
    search: online,
  });
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
      }).map(({ name, label, action }) => ({
        name,
        label,
        run: () => {
          leaving(restoreAfter(action) !== undefined);
          void inbox.organize(message, action);
        },
      }));
    }
    return [];
  };
  const empty =
    results === undefined ? (
      <View style={styles.empty}>
        <View style={styles.emptyIcon}>
          <SFSymbol
            name="tray.2"
            size={36}
            color={colors.textSecondary}
          />
        </View>
        <Label style={[styles.emptyTitle, { color: colors.textSecondary }]}>
          {t('inbox.empty')}
        </Label>
        <Label style={[styles.emptyText, { color: colors.textSecondary }]}>
          {t('inbox.emptyDetail', { scope: emptyScope })}
        </Label>
      </View>
    ) : (
      <Text style={[styles.notice, { color: colors.textSecondary }]}>
        {t('search.empty', { query: searched })}
      </Text>
    );
  return (
    <View style={styles.fill}>
      <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
        <View style={styles.headingRow}>
          <View
            accessible
            accessibilityRole="header"
            accessibilityLabel={t('inbox.heading', {
              title,
              subtitle,
            })}
            style={styles.heading}>
            <Text
              accessibilityRole="header"
              numberOfLines={1}
              style={[styles.title, { color: colors.textPrimary }]}>
              {title}
            </Text>
            <View style={styles.subtitle}>
              <Text
                accessibilityLiveRegion="polite"
                numberOfLines={1}
                style={[styles.subtitleText, { color: colors.textSecondary }]}>
                {subtitle}
              </Text>
            </View>
          </View>
          {account === undefined ? null : (
            <Pressable
              accessibilityLabel={t('inbox.account')}
              accessibilityRole="button"
              onPress={() => {
                void openAccount(account.openAccount);
              }}>
              <Text style={[styles.account, { color: colors.accentInk }]}>
                {t('inbox.account')}
              </Text>
            </Pressable>
          )}
        </View>
        {mailboxes.length > 1 ? (
          <ScopePicker
            mailboxes={mailboxes}
            onScope={setChosen}
            scope={scope}
          />
        ) : null}
        <FolderPicker
          mailbox={imap}
          folder={folder}
          failed={failed}
          onFolder={chooseFolder}
        />
        {ready ? (
          <TextInput
            accessibilityLabel={t('search.label')}
            accessibilityRole="search"
            autoCapitalize="none"
            autoComplete="off"
            autoCorrect={false}
            onChangeText={setQuery}
            placeholder={t('search.label')}
            placeholderTextColor={colors.textSecondary}
            returnKeyType="search"
            style={[
              styles.search,
              { borderColor: colors.separator, color: colors.textPrimary },
            ]}
            value={query}
          />
        ) : null}
        <View style={styles.notices}>
          {shown.map((mailbox) => (
            <MailboxScope
              key={mailbox.id}
              id={mailbox.id}>
              <MailboxStatus address={several ? mailbox.address : undefined} />
            </MailboxScope>
          ))}
          {waiting.map((mailbox) =>
            mailbox.provider === 'imap' ? (
              <ImapAuthorizationNeeded
                key={mailbox.id}
                address={mailbox.address}
                onRepair={() => {
                  if (account !== undefined) {
                    void openAccount(account.openAccount);
                  }
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
          ListHeaderComponent={
            onCompose === undefined ? null : (
              <DraftList
                onCompose={onCompose}
                scope={scope}
              />
            )
          }
          ListFooterComponent={
            <>
              {results === undefined &&
              hasNoMail({ ready, syncing, count: messages.length })
                ? empty
                : null}
              {results === undefined && syncing ? <SkeletonRows /> : null}
              <OnlineResults
                query={searched}
                search={online}
              />
            </>
          }
          ListFooterComponentStyle={styles.listFooter}
          renderSectionFooter={({ section }) =>
            section.key === 'saved' && ready && results !== undefined
              ? empty
              : null
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
                onSelect={() => {
                  void select({
                    mailbox: item.mailbox.id,
                    id: item.message.id,
                  });
                }}
                selected={
                  selected?.mailbox === item.mailbox.id &&
                  selected.id === item.message.id
                }
                status={
                  section.key === 'gmail' || results === undefined
                    ? undefined
                    : savedStatus(t, saved?.get(resultKey(item)))
                }
              />
            );
          }}
        />
        <LanguageSelector />
        <Text style={[styles.footer, { color: colors.textSecondary }]}>
          {gmail ? t('inbox.footerConnected') : t('inbox.footer')}
        </Text>
      </View>
    </View>
  );
}
