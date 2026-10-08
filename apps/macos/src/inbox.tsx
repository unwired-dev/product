import type { Message } from '@private-email/mail-core';
import type { GmailAction } from '@private-email/mail-core/gmail-actions';
import type { GmailMessage } from '@private-email/mail-core/gmail-inbox';

import { draftsOf } from '@private-email/mail-core/drafts';
import {
  quickActions,
  restoreAfter,
} from '@private-email/mail-core/gmail-actions';
import { gmailSyncCopy } from '@private-email/mail-core/gmail-inbox';
import { inboxMessages } from '@private-email/mail-core/mailboxes';
import { spacing } from '@private-email/mail-core/theme';
import { use, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { DraftList, DraftRow, useOpenDraft } from './composer.tsx';
import {
  MailboxScope,
  useDrafts,
  useInbox,
  useLeaveComposer,
  useInboxActions,
  useMailbox,
  useMailboxes,
  useReloadMailboxes,
} from './mailbox.tsx';
import { OrganizeStatus } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  headingRow: { flexDirection: 'row', alignItems: 'flex-start' },
  heading: { flex: 1, padding: spacing.large, paddingBottom: spacing.medium },
  account: { fontSize: 15, padding: spacing.large },
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
  // Opens a Draft in the composer; without it the Inbox offers no Drafts.
  readonly onCompose?: ((id: string) => void) | undefined;
  readonly composing?: string | undefined;
}

const dateFormat = new Intl.DateTimeFormat('en', {
  month: 'short',
  day: 'numeric',
  timeZone: 'UTC',
});

function MessageRow({
  message,
  mailbox,
  selected,
  onSelect,
  onOrganize,
}: {
  readonly message: Message | GmailMessage;
  // Shown when the Inbox holds more than one mailbox.
  readonly mailbox: string | undefined;
  readonly selected: boolean;
  readonly onSelect: () => void;
  // Present when the message can be organized in Gmail.
  readonly onOrganize?:
    | ((message: GmailMessage, action: GmailAction) => void)
    | undefined;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  const organizing =
    onOrganize !== undefined && 'threadId' in message
      ? quickActions(message)
      : [];
  return (
    <Pressable
      accessibilityActions={organizing.map(({ name, label }) => ({
        name,
        label,
      }))}
      accessibilityLabel={`${message.unread ? 'Unread. ' : ''}${message.sender}. ${message.subject}${mailbox === undefined ? '' : `. In ${mailbox}`}`}
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
          {`In ${mailbox}`}
        </Text>
      )}
    </Pressable>
  );
}

// Names the mailbox a notice is about when the Inbox holds more than one.
const about = (address: string | undefined, text: string) =>
  address === undefined ? text : `${address}: ${text}`;

// Synchronization keeps the cached list visible and says why Gmail may be behind.
function SyncNotice({ address }: { readonly address: string | undefined }) {
  const state = useInbox();
  const actions = useInboxActions();
  const mailbox = useMailbox();
  const account = use(AccountContext);
  const colors = usePalette();
  if (state.kind !== 'ready' || !('sync' in state)) {
    return null;
  }
  // Synchronizes again once Gmail access for this mailbox is authorized.
  const handleAllowGmail = async (authorize: () => Promise<void>) => {
    await authorize();
    await actions.load();
  };
  const notice = gmailSyncCopy[state.sync];
  if (notice === undefined) {
    return null;
  }
  return (
    <>
      <View
        accessible
        accessibilityLabel={about(address, notice)}
        accessibilityLiveRegion="polite">
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {about(address, notice)}
        </Text>
      </View>
      {state.sync === 'authentication' &&
      account !== undefined &&
      mailbox !== undefined ? (
        <Pressable
          accessibilityLabel="Allow Gmail access"
          accessibilityRole="button"
          onPress={() => {
            void handleAllowGmail(() => account.authorizeGmail(mailbox.id));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            Allow Gmail access
          </Text>
        </Pressable>
      ) : null}
      {state.sync === 'retry' ? (
        <Pressable
          accessibilityLabel="Try again"
          accessibilityRole="button"
          onPress={() => {
            void (account === undefined
              ? actions.load()
              : account.refreshInbox(actions.load));
          }}>
          <Text style={[styles.notice, { color: colors.accent }]}>
            Try again
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
  return (
    <>
      {state.kind === 'failed' || state.kind === 'locked' ? (
        <>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.foreground }]}>
            {about(
              address,
              state.kind === 'locked'
                ? 'Private storage is locked. Unlock your device and try again.'
                : 'Private storage could not be opened or saved. Your stored data has been kept.',
            )}
          </Text>
          <Pressable
            accessibilityLabel="Try again"
            accessibilityRole="button"
            onPress={() => {
              void actions.load();
            }}>
            <Text style={[styles.notice, { color: colors.accent }]}>
              Try again
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
  const notice = about(address, gmailSyncCopy.authentication);
  return (
    <View>
      <View
        accessible
        accessibilityLabel={notice}
        accessibilityLiveRegion="polite">
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {notice}
        </Text>
      </View>
      <Pressable
        accessibilityLabel={`Allow Gmail access for ${address}`}
        accessibilityRole="button"
        onPress={() => {
          void onAllow();
        }}>
        <Text style={[styles.notice, { color: colors.accent }]}>
          {`Allow Gmail access for ${address}`}
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
  const choices = [
    { id: undefined, label: 'All inboxes' },
    ...mailboxes.map(({ id, address }) => ({ id, label: address ?? id })),
  ];
  return (
    <View style={styles.scopes}>
      {choices.map(({ id, label }) => (
        <Pressable
          key={id ?? 'all'}
          accessibilityLabel={label}
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

// The shown mailbox's address, or what the list holds when it shows several or none.
function subtitleOf(
  shown: readonly InboxMailbox[],
  { several, gmail }: Readonly<{ several: boolean; gmail: boolean }>,
) {
  const [only] = shown;
  if (shown.length === 1 && only?.address !== undefined) {
    return only.address;
  }
  if (several) {
    return 'All inboxes';
  }
  return gmail ? 'Gmail' : 'Preview mailbox';
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
  const drafts = onCompose === undefined ? [] : draftsOf(draftState);
  const openDraft = useOpenDraft(composing, onCompose ?? (() => undefined));
  const reload = useReloadMailboxes();
  const account = use(AccountContext);
  const colors = usePalette();
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
  const messages = useMemo(
    () => inboxMessages(mailboxes, scope),
    [mailboxes, scope],
  );
  const ready = shown.some(({ state }) => state.kind === 'ready');
  const syncing = shown.some(
    ({ state }) =>
      state.kind === 'loading' ||
      (state.kind === 'ready' && 'sync' in state && state.sync === 'syncing'),
  );
  const subtitle = subtitleOf(shown, { several, gmail });
  const emptyInbox = () => {
    if (!ready) {
      return null;
    }
    return gmail && syncing ? (
      <ActivityIndicator accessibilityLabel="Loading Inbox" />
    ) : (
      <Text style={[styles.notice, { color: colors.secondary }]}>
        Your inbox is clear.
      </Text>
    );
  };
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
  return (
    <View style={styles.fill}>
      <View style={[styles.fill, { backgroundColor: colors.sidebar }]}>
        <View style={styles.headingRow}>
          <View
            accessible
            accessibilityRole="header"
            accessibilityLabel={`Inbox. ${subtitle}`}
            style={styles.heading}>
            <Text
              accessibilityRole="header"
              style={[styles.title, { color: colors.foreground }]}>
              Inbox
            </Text>
            <Text style={[styles.subtitle, { color: colors.secondary }]}>
              {subtitle}
            </Text>
          </View>
          {account === undefined ? null : (
            <Pressable
              accessibilityLabel="Account"
              accessibilityRole="button"
              onPress={() => {
                void openAccount(account.openAccount);
              }}>
              <Text style={[styles.account, { color: colors.accent }]}>
                Account
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
        {shown.some(({ state }) => state.kind === 'loading') ? (
          <ActivityIndicator accessibilityLabel="Loading Inbox" />
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
        <FlatList
          accessibilityLabel="Inbox messages"
          contentContainerStyle={styles.list}
          data={[
            ...drafts.map((draft) => ({ kind: 'draft', draft }) as const),
            ...messages.map(
              (entry) => ({ kind: 'message', ...entry }) as const,
            ),
          ]}
          extraData={[selected, composing]}
          keyExtractor={(item) =>
            item.kind === 'draft'
              ? `draft\n${item.draft.id}`
              : `${item.mailbox.id}\n${item.message.id}`
          }
          ListHeaderComponent={
            onCompose === undefined ? null : (
              <DraftList
                onCompose={onCompose}
                scope={scope}
              />
            )
          }
          ListEmptyComponent={emptyInbox()}
          // Drafts above an empty Inbox still say the Inbox is clear.
          ListFooterComponent={
            drafts.length > 0 && messages.length === 0 ? emptyInbox() : null
          }
          renderItem={({ item }) =>
            item.kind === 'draft' ? (
              <DraftRow
                draft={item.draft}
                onOpen={openDraft}
                selected={composing === item.draft.id}
              />
            ) : (
              <MessageRow
                mailbox={several ? item.mailbox.address : undefined}
                message={item.message}
                onOrganize={
                  item.mailbox.state.kind === 'ready' &&
                  'organize' in item.mailbox.state &&
                  item.mailbox.state.organize
                    ? organize(item.mailbox)
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
              />
            )
          }
        />
        <Text style={[styles.footer, { color: colors.secondary }]}>
          {gmail
            ? 'Gmail · Encrypted on this device'
            : 'Sample messages · Encrypted on this device'}
        </Text>
      </View>
    </View>
  );
}
