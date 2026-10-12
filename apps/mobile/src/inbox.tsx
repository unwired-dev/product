import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { Draft, OutboxEntry } from '@private-email/mail-core/drafts';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';
import type { ImapMessage } from '@private-email/mail-core/imap-inbox';
import type { MailProvider } from '@private-email/mail-core/registration';

import { draftsOf } from '@private-email/mail-core/drafts';
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import {
  inboxMessages,
  profileMailboxes,
  resultKey,
  searchMessages,
} from '@private-email/mail-core/mailboxes';
import { use, useDeferredValue, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  SectionList,
  Pressable,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { RowAction } from './organize.tsx';
import type { InboxMailbox } from './private-storage.ts';

import {
  DraftHeading,
  DraftList,
  DraftRow,
  useOpenDraft,
} from './composer.tsx';
import { FolderPicker, useImapFolder } from './imap-folders.tsx';
import { InboxCommands } from './inbox-commands.tsx';
import { styles } from './inbox-styles.ts';
import { LanguageSelector } from './language-selector.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
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
import { OrganizeStatus, rowActions } from './organize.tsx';
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
  readonly onInbox?: (() => void) | undefined;
}

const noActions: readonly RowAction[] = [];

function MessageRow({
  message,
  mailbox,
  status,
  selected,
  onSelect,
  actions = noActions,
}: {
  readonly message: Message | GmailMessage | ImapMessage;
  // Shown when the Inbox holds more than one mailbox.
  readonly mailbox: string | undefined;
  // Whether a search result's body is saved on this device, once known.
  readonly status: string | undefined;
  readonly selected: boolean;
  readonly onSelect: () => void;
  // The organizing actions its provider offers, as accessibility actions.
  readonly actions?: readonly RowAction[] | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityActions={actions.map(({ name, label }) => ({
        name,
        label,
      }))}
      accessibilityLabel={t('inbox.rowLabel', {
        context: [
          mailbox === undefined ? undefined : 'mailbox',
          status === undefined ? undefined : 'status',
        ]
          .filter((part) => part !== undefined)
          .join('_'),
        row: t(message.unread ? 'inbox.unreadRow' : 'inbox.row', {
          sender: message.sender,
          subject: message.subject,
        }),
        mailbox,
        status,
      })}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      focusable
      onAccessibilityAction={({ nativeEvent }) => {
        actions.find(({ name }) => name === nativeEvent.actionName)?.run();
      }}
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onSelect}
      style={({ pressed }) => [
        styles.row,
        {
          backgroundColor:
            selected || pressed ? colors.selected : colors.sidebar,
          borderColor: focused ? colors.accent : 'transparent',
        },
      ]}>
      <View style={styles.rowHeading}>
        <Text
          style={[styles.sender, { color: colors.foreground }]}
          numberOfLines={1}>
          {message.sender}
        </Text>
        <Text style={[styles.date, { color: colors.secondary }]}>
          {dateFormat.format(new Date(message.receivedAt))}
        </Text>
      </View>
      <View style={styles.subjectLine}>
        {message.unread ? (
          <View style={[styles.unread, { backgroundColor: colors.accent }]} />
        ) : null}
        <Text
          style={[styles.subject, { color: colors.foreground }]}
          numberOfLines={1}>
          {message.subject}
        </Text>
      </View>
      <Text
        style={[styles.preview, { color: colors.secondary }]}
        numberOfLines={2}>
        {message.preview}
      </Text>
      {mailbox === undefined ? null : (
        <Text
          numberOfLines={1}
          style={[styles.mailbox, { color: colors.secondary }]}>
          {t('inbox.inMailbox', { mailbox })}
        </Text>
      )}
      {status === undefined ? null : (
        <Text
          numberOfLines={1}
          style={[styles.mailbox, { color: colors.secondary }]}>
          {status}
        </Text>
      )}
    </Pressable>
  );
}

// Names the mailbox a notice is about when the Inbox holds more than one.
const about = (t: Translate, address: string | undefined, text: string) =>
  address === undefined ? text : t('inbox.about', { address, text });

// Synchronization keeps the cached list visible and says why Gmail may be behind.
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
    state.sync === 'current'
  ) {
    return null;
  }
  // Synchronizes again once access for this mailbox is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  return (
    <>
      <Text
        accessibilityLiveRegion="polite"
        style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t(`gmailSync.${state.sync}`, { provider }))}
      </Text>
      {state.sync === 'authentication' &&
      account !== undefined &&
      mailbox !== undefined ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void handleAllowGmail(() => account.authorizeMailbox(mailbox.id));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            {t('common.allowAccess', { provider })}
          </Text>
        </Pressable>
      ) : null}
      {state.sync === 'retry' ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void (account === undefined
              ? actions.load()
              : account.refreshInbox(actions.load));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            {t('common.retry')}
          </Text>
        </Pressable>
      ) : null}
    </>
  );
}

// One mailbox's storage, synchronization and organizing status.
function MailboxStatus({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <>
      {state.kind === 'failed' || state.kind === 'locked' ? (
        <>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.foreground }]}>
            {about(
              t,
              address,
              state.kind === 'locked'
                ? t('storage.locked')
                : t('storage.failed'),
            )}
          </Text>
          <Pressable
            accessibilityRole="button"
            onPress={() => {
              void actions.load();
            }}>
            <Text style={[styles.notice, { color: colors.accent }]}>
              {t('common.retry')}
            </Text>
          </Pressable>
        </>
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
    !('receiveOnly' in state) ||
    state.status === 'current'
  ) {
    return null;
  }
  const openAccount = async () => {
    if (await leave()) {
      account?.openAccount();
    }
  };
  return (
    <>
      <Text
        accessibilityLiveRegion="polite"
        style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t(`imapSync.${state.status}`))}
      </Text>
      {state.status === 'authentication' && account !== undefined ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void openAccount();
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            {t('mailboxes.enterPassword', {
              address: mailbox?.address ?? state.address,
            })}
          </Text>
        </Pressable>
      ) : null}
    </>
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
    <View>
      <Text
        accessibilityLiveRegion="polite"
        style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t('gmailSync.authentication', { provider }))}
      </Text>
      <Pressable
        accessibilityRole="button"
        onPress={() => {
          void onAllow();
        }}>
        <Text style={[styles.notice, { color: colors.accent }]}>
          {t('mailboxes.allow', { address, provider })}
        </Text>
      </Pressable>
    </View>
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
    <View>
      <Text style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t('imapSync.authentication'))}
      </Text>
      <Pressable
        accessibilityRole="button"
        onPress={onRepair}>
        <Text style={[styles.notice, { color: colors.accent }]}>
          {t('mailboxes.enterPassword', { address })}
        </Text>
      </Pressable>
    </View>
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
  const colors = usePalette();
  const { t } = useLocalization();
  const choices = [
    { id: undefined, label: t('inbox.allInboxes') },
    ...mailboxes.map(({ id, address }) => ({ id, label: address ?? id })),
  ];
  return (
    <View style={styles.scopes}>
      {choices.map(({ id, label }) => (
        <Pressable
          key={id ?? 'all'}
          accessibilityRole="button"
          accessibilityState={{ selected: id === scope }}
          onPress={() => {
            onScope(id);
          }}
          style={[
            styles.scope,
            {
              backgroundColor: id === scope ? colors.selected : colors.sidebar,
              borderColor: id === scope ? colors.accent : 'transparent',
            },
          ]}>
          <Text style={{ color: colors.foreground }}>{label}</Text>
        </Pressable>
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
        accessibilityRole="button"
        onPress={() => {
          void search.search();
        }}>
        <Text style={[styles.notice, { color: colors.accent }]}>
          {t('search.online', { query })}
        </Text>
      </Pressable>
    );
  }
  return (
    <View>
      {found?.results.length === 0 && found.failures.length === 0 ? (
        <Text style={[styles.notice, { color: colors.secondary }]}>
          {t('search.onlineEmpty', { query })}
        </Text>
      ) : null}
      {searching ? (
        <ActivityIndicator accessibilityLabel={t('search.searching')} />
      ) : null}
      {!searching && found !== undefined && found.next.size > 0 ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void search.more();
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            {t('search.more')}
          </Text>
        </Pressable>
      ) : null}
      {!searching && found !== undefined && found.failures.length > 0 ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void search.search();
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
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
        style={[styles.footer, { color: colors.secondary }]}>
        {t('search.onlineHeading')}
      </Text>
      {found?.failures.map(({ mailbox, reason }) => (
        <Text
          key={mailbox.id}
          accessibilityLiveRegion="polite"
          style={[styles.footer, { color: colors.secondary }]}>
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
          style={[styles.footer, { color: colors.secondary }]}>
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
function subtitleOf(
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

// Section data lets the native list virtualize online pages together with saved rows.
const searchSections = <T,>(
  messages: readonly T[],
  online: Readonly<{
    searching: boolean;
    found?: Readonly<{ results: readonly T[] }> | undefined;
  }>,
) => [
  { key: 'saved', data: messages },
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
  messages: readonly M[];
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

export function Inbox({
  selected,
  onSelect,
  onClose,
  onCompose,
  composing,
  onInbox,
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
  const sections = inboxSections({
    outbox,
    canCompose: onCompose !== undefined,
    drafts,
    messages,
    online,
    searching: results !== undefined,
  });
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(
    () => ({ selected, saved, composing }),
    [selected, saved, composing],
  );
  const selectedMailbox = mailboxes.find(({ id }) => id === selected?.mailbox);
  const selectionMessage =
    selected === undefined || selectedMailbox?.state.kind !== 'ready'
      ? undefined
      : 'openFolder' in selectedMailbox.inbox
        ? selectedMailbox.inbox.message(selected.id)
        : (selectedMailbox.state.messages.find(
            ({ id }) => id === selected.id,
          ) ??
          ('found' in selectedMailbox.state
            ? selectedMailbox.state.found?.find(({ id }) => id === selected.id)
            : undefined));
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(({ state }) => checking(state));
  const subtitle = subtitleOf(t, shown, { several, gmail });
  const goInbox = () => {
    setQuery('');
    chooseFolder(inboxFolder);
    onInbox?.();
  };
  const empty =
    results === undefined && gmail && syncing ? (
      <ActivityIndicator accessibilityLabel={t('inbox.loading')} />
    ) : (
      <Text style={[styles.notice, { color: colors.secondary }]}>
        {results === undefined
          ? t('inbox.empty')
          : t('search.empty', { query: searched })}
      </Text>
    );
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true }}
      style={styles.fill}>
      <View style={[styles.fill, { backgroundColor: colors.sidebar }]}>
        <InboxCommands
          hasSelection={selected !== undefined}
          selectionMailbox={selectedMailbox}
          selectionMessage={selectionMessage}
          stars={(selected === undefined
            ? shown
            : mailboxes.filter(({ id }) => id === selected.mailbox)
          ).some(({ provider }) => (provider ?? 'gmail') === 'gmail')}
          mailboxes={mailboxes}
          onInbox={goInbox}
          onScope={setChosen}
        />
        <View style={styles.heading}>
          <View style={styles.headingText}>
            <Text
              accessibilityRole="header"
              style={[styles.title, { color: colors.foreground }]}>
              {t('inbox.title')}
            </Text>
            <Text style={[styles.subtitle, { color: colors.secondary }]}>
              {subtitle}
            </Text>
          </View>
          {account === undefined ? null : (
            <Pressable
              accessibilityRole="button"
              onPress={() => {
                void openAccount(account.openAccount);
              }}>
              <Text style={[styles.account, { color: colors.accent }]}>
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
            clearButtonMode="while-editing"
            onChangeText={setQuery}
            placeholder={t('search.label')}
            placeholderTextColor={colors.secondary}
            returnKeyType="search"
            style={[
              styles.search,
              { borderColor: colors.separator, color: colors.foreground },
            ]}
            value={query}
          />
        ) : null}
        {shown.some(({ state }) => state.kind === 'loading') ? (
          <ActivityIndicator accessibilityLabel={t('inbox.loading')} />
        ) : null}
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
            return section.key === 'gmail' ? (
              <OnlineHeading
                search={online}
                several={several}
              />
            ) : null;
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
            <OnlineResults
              query={searched}
              search={online}
            />
          }
          renderSectionFooter={({ section }) =>
            section.key === 'saved' && messages.length === 0 && ready
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
                  section.key === 'saved'
                    ? rowActions({
                        t,
                        mailbox: item.mailbox,
                        message: item.message,
                        onLeave: () => {
                          if (
                            selected?.mailbox === item.mailbox.id &&
                            selected.id === item.message.id
                          ) {
                            onClose?.();
                          }
                        },
                      })
                    : undefined
                }
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
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {gmail ? t('inbox.footerConnected') : t('inbox.footer')}
        </Text>
      </View>
    </SafeAreaView>
  );
}
