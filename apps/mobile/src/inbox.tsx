import type { Translate } from '@private-email/localization';
import type { Message } from '@private-email/mail-core';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';

import {
  quickActions,
  restoreAfter,
} from '@private-email/mail-core/gmail-actions';
import {
  inboxMessages,
  resultKey,
  searchMessages,
} from '@private-email/mail-core/mailboxes';
import { spacing } from '@private-email/mail-core/theme';
import { use, useDeferredValue, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  SectionList,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { InboxMailbox } from './private-storage.ts';

import { LanguageSelector } from './language-selector.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
import {
  MailboxScope,
  useGmailSearch,
  useInbox,
  useInboxActions,
  useMailbox,
  useMailboxes,
  useReloadMailboxes,
  useSavedBodies,
} from './mailbox.tsx';
import { OrganizeStatus } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    padding: spacing.large,
    paddingBottom: spacing.medium,
  },
  headingText: { flex: 1 },
  account: { fontSize: 16, paddingVertical: 8 },
  title: { fontSize: 34, fontWeight: '700', letterSpacing: -0.8 },
  subtitle: { fontSize: 14, marginTop: 4 },
  list: { paddingHorizontal: spacing.small, gap: 4 },
  row: {
    minHeight: 116,
    padding: 14,
    borderWidth: 2,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  rowHeading: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: spacing.small,
  },
  sender: { flex: 1, fontSize: 16, fontWeight: '600' },
  date: { fontSize: 12 },
  subjectLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 5,
  },
  subject: { flex: 1, fontSize: 15, fontWeight: '500' },
  unread: { width: 6, height: 6, borderRadius: 3 },
  preview: { fontSize: 14, lineHeight: 20, marginTop: 5 },
  footer: { fontSize: 12, padding: spacing.large },
  notice: { padding: spacing.large, fontSize: 16 },
  mailbox: { fontSize: 12, marginTop: 5 },
  search: {
    minHeight: 44,
    marginHorizontal: spacing.large,
    marginBottom: spacing.medium,
    paddingHorizontal: 12,
    fontSize: 16,
    borderWidth: 1,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  scopes: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.small,
    paddingHorizontal: spacing.large,
    paddingBottom: spacing.medium,
  },
  scope: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: 12,
    borderWidth: 2,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
});

// A message in a mailbox; Gmail message IDs are unique only within their mailbox.
export type Selection = Readonly<{ mailbox: string; id: string }>;

interface InboxProps {
  readonly selected: Selection | undefined;
  readonly onSelect: (selection: Selection) => void;
  // Closes the reader when a row action takes its message out of the Inbox.
  readonly onClose?: (() => void) | undefined;
}

function MessageRow({
  message,
  mailbox,
  status,
  selected,
  onSelect,
  onOrganize,
}: {
  readonly message: Message | GmailMessage;
  // Shown when the Inbox holds more than one mailbox.
  readonly mailbox: string | undefined;
  // Whether a search result's body is saved on this device, once known.
  readonly status: string | undefined;
  readonly selected: boolean;
  readonly onSelect: () => void;
  // Present when the message can be organized in Gmail.
  readonly onOrganize?:
    | ((message: GmailMessage, action: GmailAction) => void)
    | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat();
  const [focused, setFocused] = useState(false);
  const organizing =
    onOrganize !== undefined && 'threadId' in message
      ? quickActions(t, message)
      : [];
  return (
    <Pressable
      accessibilityActions={organizing.map(({ name, label }) => ({
        name,
        label,
      }))}
      accessibilityLabel={[
        t(message.unread ? 'inbox.unreadRow' : 'inbox.row', {
          sender: message.sender,
          subject: message.subject,
        }),
        mailbox === undefined ? undefined : t('inbox.inMailbox', { mailbox }),
        status,
      ]
        .filter((part) => part !== undefined)
        .join('. ')}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      focusable
      onAccessibilityAction={({ nativeEvent }) => {
        const chosen = organizing.find(
          ({ name }) => name === nativeEvent.actionName,
        );
        if (chosen !== undefined && 'threadId' in message) {
          onOrganize?.(message, chosen.action);
        }
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
  if (
    state.kind !== 'ready' ||
    !('sync' in state) ||
    state.sync === 'current'
  ) {
    return null;
  }
  // Synchronizes again once Gmail access for this mailbox is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  return (
    <>
      <Text
        accessibilityLiveRegion="polite"
        style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t(`gmailSync.${state.sync}`))}
      </Text>
      {state.sync === 'authentication' &&
      account !== undefined &&
      mailbox !== undefined ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void handleAllowGmail(() => account.authorizeGmail(mailbox.id));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            {t('common.allowGmail')}
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
      <OrganizeStatus />
    </>
  );
}

// A connection whose Gmail grant was refused has no Inbox until Gmail is authorized again.
function AuthorizationNeeded({
  address,
  onAllow,
}: {
  readonly address: string;
  readonly onAllow: () => Promise<void>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View>
      <Text
        accessibilityLiveRegion="polite"
        style={[styles.footer, { color: colors.secondary }]}>
        {about(t, address, t('gmailSync.authentication'))}
      </Text>
      <Pressable
        accessibilityRole="button"
        onPress={() => {
          void onAllow();
        }}>
        <Text style={[styles.notice, { color: colors.accent }]}>
          {t('mailboxes.allow', { address })}
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

export function Inbox({ selected, onSelect, onClose }: InboxProps) {
  const mailboxes = useMailboxes();
  const reload = useReloadMailboxes();
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const [chosen, setChosen] = useState<string>();
  // A removed mailbox's view falls back to every mailbox.
  const scope = mailboxes.some(({ id }) => id === chosen) ? chosen : undefined;
  const shown = mailboxes.filter(
    ({ id }) => scope === undefined || id === scope,
  );
  // Connections waiting for Gmail authorization have no Inbox until it is given again.
  const waiting =
    scope === undefined
      ? (account?.mailboxes ?? []).filter(
          ({ state }) => state === 'authorization',
        )
      : [];
  // With more than one mailbox, every row and notice names its own.
  const several = (account?.mailboxes.length ?? mailboxes.length) > 1;
  const gmail = account !== undefined;
  const [query, setQuery] = useState('');
  // Typing stays responsive while the list catches up with the latest query.
  const searched = useDeferredValue(query.trim());
  const listed = useMemo(
    () => inboxMessages(mailboxes, scope),
    [mailboxes, scope],
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
  const online = useGmailSearch(shown, searched, scope);
  const messages = results ?? listed;
  const sections = searchSections(messages, online);
  // Rows render again when the selection or a result's saved state changes.
  const rows = useMemo(() => ({ selected, saved }), [selected, saved]);
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(
    ({ state }) =>
      state.kind === 'loading' ||
      (state.kind === 'ready' && 'sync' in state && state.sync === 'syncing'),
  );
  const subtitle = subtitleOf(t, shown, { several, gmail });
  const organize =
    (mailbox: InboxMailbox) => (message: GmailMessage, action: GmailAction) => {
      if (
        selected?.mailbox === mailbox.id &&
        message.id === selected.id &&
        restoreAfter(action) !== undefined
      ) {
        onClose?.();
      }
      if ('organize' in mailbox.inbox) {
        void mailbox.inbox.organize(message, action);
      }
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
                account.openAccount();
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
        {waiting.map((mailbox) => (
          <AuthorizationNeeded
            key={mailbox.id}
            address={mailbox.address}
            onAllow={async () => {
              await account?.authorizeGmail(mailbox.id);
              await reload();
            }}
          />
        ))}
        {ready ? (
          <SectionList
            accessibilityLabel={t('inbox.messages')}
            contentContainerStyle={styles.list}
            sections={sections}
            stickySectionHeadersEnabled={false}
            renderSectionHeader={({ section }) =>
              section.key === 'gmail' ? (
                <OnlineHeading
                  search={online}
                  several={several}
                />
              ) : null
            }
            extraData={rows}
            keyExtractor={resultKey}
            ListFooterComponent={
              <OnlineResults
                query={searched}
                search={online}
              />
            }
            renderSectionFooter={({ section }) =>
              section.key === 'saved' && messages.length === 0 ? empty : null
            }
            renderItem={({ item, section }) => (
              <MessageRow
                mailbox={several ? item.mailbox.address : undefined}
                message={item.message}
                onOrganize={
                  section.key === 'saved' &&
                  item.mailbox.state.kind === 'ready' &&
                  'organize' in item.mailbox.state &&
                  item.mailbox.state.organize
                    ? organize(item.mailbox)
                    : undefined
                }
                onSelect={() => {
                  onSelect({ mailbox: item.mailbox.id, id: item.message.id });
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
            )}
          />
        ) : null}
        <LanguageSelector />
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {gmail ? t('inbox.footerGmail') : t('inbox.footer')}
        </Text>
      </View>
    </SafeAreaView>
  );
}
