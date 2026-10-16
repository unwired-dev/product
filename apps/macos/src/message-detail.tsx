import type { CommandTarget } from '@private-email/mail-core/commands';
import type { ResponseKind } from '@private-email/mail-core/responses';
import type { Dispatch, ReactNode, SetStateAction } from 'react';

import {
  commandTarget,
  expectedCommands,
  responseCommands,
} from '@private-email/mail-core/commands';
import { messageContextMenu } from '@private-email/mail-core/context-menu';
import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { listedMessage } from '@private-email/mail-core/gmail-inbox';
import { startResponse } from '@private-email/mail-core/responses';
import { spacing } from '@private-email/mail-core/theme';
import Clipboard from '@react-native-clipboard/clipboard';
import {
  createContext,
  use,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { SavedAttachment } from './message-body.tsx';
import type { InboxStore } from './private-storage.ts';

import { RegisterCommands, useMessageCommands } from './command-palette.tsx';
import { ContextMenu, GlassGroup, ToolbarButton } from './design.tsx';
import { ImapMessageBody } from './imap-message-body.tsx';
import { useLocalization, useMessageDateFormat } from './localization.ts';
import { ReaderMailAssistanceGate } from './mail-assistance.tsx';
import {
  MailboxScope,
  useComposerNavigation,
  useDraftStore,
  useDrafts,
  useInbox,
  useInboxActions,
  useMailbox,
  useProfile,
} from './mailbox.tsx';
import {
  AttachContext,
  GmailMessageBody,
  ReaderScrollView,
} from './message-body.tsx';
import { MessageSummary } from './message-summary.tsx';
import { MessageActions, MessageActionsNotice } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // The fixed reader toolbar: glass groups at the pane's trailing edge, content below them.
  toolbar: {
    height: 36 + spacing.m,
    zIndex: 1,
    alignItems: 'flex-end',
    paddingTop: spacing.m,
    paddingHorizontal: spacing.l,
    gap: spacing.s,
  },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    paddingHorizontal: 40,
    paddingTop: spacing.xl,
    paddingBottom: 40,
    gap: spacing.l,
  },
  subject: { ...textStyles.reading.subject },
  metadata: {
    gap: 2,
    paddingBottom: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  from: { flexDirection: 'row', gap: spacing.m, alignItems: 'flex-start' },
  fromText: { flex: 1, minHeight: 28 },
  sender: { ...textStyles.bodyEmphasized },
  address: { ...textStyles.body },
  control: { minHeight: 28, minWidth: 28, justifyContent: 'center' },
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  secondary: { ...textStyles.subheadline },
  body: { ...textStyles.reading.body },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    gap: spacing.s,
  },
  emptyTitle: { ...textStyles.title3Emphasized, textAlign: 'center' },
  emptyDescription: { ...textStyles.body, textAlign: 'center' },
});

// Nothing selected, or a message that is not in any open mailbox.
function EmptyDetail({ id }: { readonly id: string | undefined }) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <View
        accessible
        accessibilityRole="text"
        accessibilityLabel={
          id ? t('message.unavailableLabel') : t('message.select')
        }
        style={styles.empty}>
        <Text
          accessibilityRole="header"
          style={[styles.emptyTitle, { color: colors.textPrimary }]}>
          {id ? t('message.unavailable') : t('message.empty')}
        </Text>
        <Text
          style={[styles.emptyDescription, { color: colors.textSecondary }]}>
          {id ? t('message.chooseAnother') : t('message.select')}
        </Text>
      </View>
    </View>
  );
}

// Starts a Draft from the reader's mailbox when it can send, or the first one that can, with a
// copy of a Downloaded Attachment. The Draft keeps the bytes, never the mailbox they came from.
function AttachToNewMessage({
  onCompose,
  children,
}: {
  readonly onCompose: (id: string) => void;
  readonly children: ReactNode;
}) {
  const store = useDraftStore();
  const drafts = useDrafts();
  const navigation = useComposerNavigation();
  const account = use(AccountContext);
  const mailbox = useMailbox();
  const { t } = useLocalization();
  const colors = usePalette();
  const mounted = useRef(true);
  const attaching = useRef(false);
  const [failed, setFailed] = useState(false);
  // Only open Draft storage and an eligible sender in the reader's Mail Profile can start a new
  // message.
  const mailboxes = account?.mailboxes ?? [];
  const canSend =
    sendingMailboxes(mailboxes, profileOf(mailbox?.id, mailboxes)).length > 0;
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const attach = async (saved: SavedAttachment) => {
    if (!mounted.current || attaching.current) {
      return;
    }
    if (mailbox === undefined) {
      return;
    }
    attaching.current = true;
    setFailed(false);
    try {
      const draft = await navigation.attachReceived(store, {
        mailbox: mailbox.id,
        mailboxes,
        saved,
      });
      if (mounted.current && draft !== undefined) {
        onCompose(draft);
      }
    } catch {
      // Keep the reader usable if an unexpected host operation rejects, and say so. An undefined
      // result can mean a later destination was chosen, the open composer stayed open, or its
      // Draft/account disappeared. Non-ready storage has its own subscribed feedback below.
      if (mounted.current) {
        setFailed(true);
      }
    }
    // Not in `finally`: React Compiler cannot compile a finally clause, and the catch above
    // handles every rejection.
    attaching.current = false;
  };
  return (
    <AttachContext
      value={
        canSend && drafts.kind === 'ready'
          ? (saved) => {
              void attach(saved);
            }
          : undefined
      }>
      {canSend && (drafts.kind === 'locked' || drafts.kind === 'failed') ? (
        <View>
          <View
            accessible
            accessibilityLabel={
              drafts.kind === 'locked'
                ? t('drafts.listLocked')
                : t('drafts.listFailed')
            }
            accessibilityLiveRegion="polite"
            accessibilityRole="alert">
            <Text style={[styles.secondary, { color: colors.textPrimary }]}>
              {drafts.kind === 'locked'
                ? t('drafts.listLocked')
                : t('drafts.listFailed')}
            </Text>
          </View>
          <Pressable
            style={styles.control}
            accessibilityRole="button"
            accessibilityLabel={t('common.retry')}
            onPress={() => {
              void store.load();
            }}>
            <Text style={[styles.secondary, { color: colors.accentInk }]}>
              {t('common.retry')}
            </Text>
          </Pressable>
        </View>
      ) : null}
      {failed ? (
        <View
          accessible
          accessibilityLabel={t('attachment.attachFailed')}
          accessibilityLiveRegion="polite"
          accessibilityRole="alert">
          <Text style={[styles.secondary, { color: colors.textPrimary }]}>
            {t('attachment.attachFailed')}
          </Text>
        </View>
      ) : null}
      {children}
    </AttachContext>
  );
}

export function MessageDetail({
  mailbox,
  id,
  folder,
  onClose,
  onCompose,
}: {
  // The mailbox the message belongs to; Gmail message IDs are unique only within it.
  readonly mailbox: string | undefined;
  readonly id: string | undefined;
  // The Gmail view the message was chosen in, when not the Inbox.
  readonly folder?: string | undefined;
  // Leaves the reader after its message leaves the Inbox.
  readonly onClose?: (() => void) | undefined;
  // Opens a Draft the reader started, such as one with a received attachment.
  readonly onCompose?: ((id: string) => void) | undefined;
}) {
  const profile = useProfile();
  if (mailbox === undefined || id === undefined) {
    return <EmptyDetail id={id} />;
  }
  const message = (
    <MailboxMessage
      id={id}
      folder={folder}
      onClose={onClose}
      onCompose={onCompose}
    />
  );
  return (
    <MailboxScope
      id={mailbox}
      fallback={<EmptyDetail id={id} />}>
      <ReaderMailAssistanceGate profile={profile}>
        {onCompose === undefined ? (
          message
        ) : (
          <AttachToNewMessage
            key={`${mailbox}/${id}`}
            onCompose={onCompose}>
            {message}
          </AttachToNewMessage>
        )}
      </ReaderMailAssistanceGate>
    </MailboxScope>
  );
}

// A listed message, or an online search result, which opens here though the Inbox does not list it.
const shownMessage = (state: ReturnType<typeof useInbox>, id: string) => {
  if (state.kind !== 'ready') {
    return undefined;
  }
  return (
    ('sync' in state
      ? listedMessage(state, id)
      : state.messages.find((item) => item.id === id)) ??
    ('found' in state ? state.found?.find((item) => item.id === id) : undefined)
  );
};

// The response controls live in the fixed toolbar; their progress and failure show in the
// reader's scrolling content, for the message they belong to.
type ResponseStatus =
  | Readonly<{ id: string; kind: 'preparingForward' | 'failed' }>
  | undefined;
const ResponseStatusContext = createContext<
  Dispatch<SetStateAction<ResponseStatus>> | undefined
>(undefined);

function ResponseStatusNotice({
  status,
  id,
}: {
  readonly status: ResponseStatus;
  // The shown message; a status reported for another one stays hidden.
  readonly id: string;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (status === undefined || status.id !== id) {
    return null;
  }
  return status.kind === 'failed' ? (
    <View
      accessible
      accessibilityLabel={t('message.respondFailed')}
      accessibilityLiveRegion="polite"
      accessibilityRole="alert">
      <Text style={[styles.secondary, { color: colors.textPrimary }]}>
        {t('message.respondFailed')}
      </Text>
    </View>
  ) : (
    <View
      accessible
      accessibilityLabel={t('message.preparingForward')}
      accessibilityLiveRegion="polite">
      <Text style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('message.preparingForward')}
      </Text>
    </View>
  );
}

// Reply, Reply All and Forward, once an opened Gmail message's body and headers are read. A
// response always sends from the reader's own mailbox; one that cannot send offers none.
function ResponseActions({
  message,
  onCompose,
}: {
  readonly message: NonNullable<ReturnType<typeof shownMessage>>;
  readonly onCompose: ((id: string) => void) | undefined;
}) {
  const inbox = useInboxActions();
  const store = useDraftStore();
  const drafts = useDrafts();
  const navigation = useComposerNavigation();
  const account = use(AccountContext);
  const mailbox = useMailbox();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const mounted = useRef(true);
  const starting = useRef(false);
  const [pending, setPending] = useState<ResponseKind | undefined>();
  const report = use(ResponseStatusContext);
  const source = useSyncExternalStore(inbox.subscribe, () =>
    'responseSource' in inbox ? inbox.responseSource(message.id) : undefined,
  );
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const mailboxes = account?.mailboxes ?? [];
  const sender = sendingMailboxes(
    mailboxes,
    profileOf(mailbox?.id, mailboxes),
  ).find(({ id }) => id === mailbox?.id);
  if (
    !('responseSource' in inbox) ||
    !('threadId' in message) ||
    onCompose === undefined ||
    sender === undefined ||
    source === undefined ||
    drafts.kind !== 'ready'
  ) {
    return null;
  }
  const received = t('message.received', {
    date: dateFormat.format(new Date(message.receivedAt)),
  });
  const start = async (kind: ResponseKind) => {
    if (
      !mounted.current ||
      starting.current ||
      inbox.responseSource(message.id) !== source
    ) {
      return;
    }
    starting.current = true;
    setPending(kind);
    report?.(
      kind === 'forward'
        ? { id: message.id, kind: 'preparingForward' }
        : undefined,
    );
    try {
      const draft = await startResponse(
        { navigation, drafts: store, inbox },
        t,
        {
          kind,
          mailbox: sender,
          message,
          received,
          mailboxes: account?.mailboxes ?? [sender],
          current: () => mounted.current,
        },
      );
      if (mounted.current && draft !== undefined) {
        onCompose(draft);
      }
    } catch {
      // The reader stays usable when an unexpected host operation rejects, and says so.
      if (mounted.current) {
        report?.({ id: message.id, kind: 'failed' });
      }
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    starting.current = false;
    if (mounted.current) {
      setPending(undefined);
      report?.((status) =>
        status?.id === message.id && status.kind === 'preparingForward'
          ? undefined
          : status,
      );
    }
  };
  const actions = [
    ['reply', 'arrowshape.turn.up.left', t('message.reply')],
    ['replyAll', 'arrowshape.turn.up.left.2', t('message.replyAll')],
    ['forward', 'arrowshape.turn.up.right', t('message.forward')],
  ] as const;
  return (
    <>
      <RegisterCommands
        offer={() =>
          responseCommands(t, commandTarget(mailbox?.id, message), {
            start,
            starting: pending !== undefined,
          })
        }
      />
      <GlassGroup>
        {actions.map(([kind, icon, label]) => (
          <ToolbarButton
            key={kind}
            icon={icon}
            label={label}
            disabled={pending !== undefined}
            onPress={() => {
              void start(kind);
            }}
          />
        ))}
      </GlassGroup>
    </>
  );
}

// The reader for the message's store: an IMAP or Gmail body, or the preview fixture's text.
function ReaderBody({
  inbox,
  message,
  connection,
}: {
  readonly inbox: InboxStore;
  readonly message: NonNullable<ReturnType<typeof shownMessage>>;
  readonly connection: string | undefined;
}) {
  const colors = usePalette();
  if ('openFolder' in inbox) {
    return (
      <ImapMessageBody
        id={message.id}
        inbox={inbox}
        subject={message.subject}
        connection={connection}
      />
    );
  }
  if ('responseSource' in inbox) {
    return (
      <GmailMessageBody
        id={message.id}
        inbox={inbox}
        subject={message.subject}
        connection={connection}
      />
    );
  }
  return (
    <>
      <View style={styles.assistance}>
        <MessageSummary
          source={inbox}
          id={message.id}
          subject={message.subject}
          body={'body' in message ? message.body : message.preview}
        />
        <MessageTranslation
          source={inbox}
          id={message.id}
          body={'body' in message ? message.body : message.preview}
        />
      </View>
      <Text
        selectable
        style={[styles.body, { color: colors.textPrimary }]}>
        {'body' in message ? message.body : message.preview}
      </Text>
    </>
  );
}

// The open message's context menu: the commands its reader offers, grouped as the design orders
// them, with Delete Message last.
function MessageMenu({
  target,
  children,
}: {
  readonly target: CommandTarget;
  readonly children: ReactNode;
}) {
  const { t } = useLocalization();
  const commands = useMessageCommands(target);
  return (
    <ContextMenu sections={messageContextMenu(t, target, commands)}>
      {children}
    </ContextMenu>
  );
}

function MailboxMessage({
  id,
  folder,
  onClose,
  onCompose,
}: {
  readonly id: string;
  readonly folder: string | undefined;
  readonly onClose: (() => void) | undefined;
  readonly onCompose: ((id: string) => void) | undefined;
}) {
  const state = useInbox();
  const actions = useInboxActions();
  const mailbox = useMailbox();
  const address = mailbox?.address;
  const [responseStatus, setResponseStatus] = useState<ResponseStatus>();
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  // An IMAP message can come from any folder this mailbox has read, not only its Inbox.
  const folderMessage = useSyncExternalStore(actions.subscribe, () =>
    'openFolder' in actions ? actions.message(id) : undefined,
  );
  const message = folderMessage ?? shownMessage(state, id);
  const applied = new Set(
    message !== undefined && 'labels' in message ? message.labels : [],
  );
  const labelNames =
    state.kind === 'ready' && 'labels' in state
      ? state.labels
          .filter((label) => applied.has(label.id))
          .map((label) => label.name)
      : [];

  if (state.kind === 'loading') {
    return (
      <ActivityIndicator
        accessibilityLabel={t('message.loading')}
        style={styles.fill}
      />
    );
  }

  if (state.kind === 'locked' || state.kind === 'failed') {
    return (
      <View style={styles.empty}>
        <Text
          accessibilityRole="alert"
          style={[styles.emptyDescription, { color: colors.textPrimary }]}>
          {state.kind === 'locked' ? t('storage.locked') : t('storage.failed')}
        </Text>
        <Pressable
          style={styles.control}
          accessibilityRole="button"
          onPress={() => {
            void actions.load();
          }}>
          <Text style={[styles.secondary, { color: colors.accentInk }]}>
            {t('common.retry')}
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <ResponseStatusContext value={setResponseStatus}>
      <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
        {message === undefined ? (
          <View
            accessible
            accessibilityRole="text"
            accessibilityLabel={t('message.unavailableLabel')}
            style={styles.empty}>
            <Text
              accessibilityRole="header"
              style={[styles.emptyTitle, { color: colors.textPrimary }]}>
              {t('message.unavailable')}
            </Text>
            <Text
              style={[
                styles.emptyDescription,
                { color: colors.textSecondary },
              ]}>
              {t('message.chooseAnother')}
            </Text>
          </View>
        ) : (
          <>
            <RegisterCommands
              offer={() =>
                expectedCommands(t, {
                  target: commandTarget(mailbox?.id, message),
                  disabled: t('commands.unavailable'),
                })
              }
            />
            <View style={styles.toolbar}>
              <MessageActions
                id={message.id}
                folder={folder}
                onClose={onClose}>
                <ResponseActions
                  key={`${address}:${message.id}`}
                  message={message}
                  onCompose={onCompose}
                />
              </MessageActions>
            </View>
            <ReaderScrollView contentContainerStyle={styles.content}>
              <Text
                accessibilityRole="header"
                selectable
                style={[styles.subject, { color: colors.textPrimary }]}>
                {message.subject}
              </Text>
              <MessageMenu target={commandTarget(mailbox?.id, message)}>
                <View
                  style={[
                    styles.metadata,
                    { borderBottomColor: colors.separator },
                  ]}>
                  <View style={styles.from}>
                    <ContextMenu
                      accessible
                      accessibilityRole="text"
                      accessibilityLabel={`${message.sender}, ${message.address}`}
                      accessibilityActions={[
                        { name: 'copy', label: t('contextMenu.copyAddress') },
                      ]}
                      onAccessibilityAction={({ nativeEvent }) => {
                        if (nativeEvent.actionName === 'copy') {
                          Clipboard.setString(message.address);
                        }
                      }}
                      style={styles.fromText}
                      sections={[
                        {
                          items: [
                            {
                              key: `copy\n${message.address}`,
                              title: t('contextMenu.copyAddress'),
                              symbol: 'doc.on.doc',
                              run: () => {
                                Clipboard.setString(message.address);
                              },
                            },
                          ],
                        },
                      ]}>
                      <Text style={{ color: colors.textSecondary }}>
                        <Text
                          style={[
                            styles.sender,
                            { color: colors.textPrimary },
                          ]}>
                          {message.sender}
                        </Text>
                        <Text
                          style={styles.address}>{`  ${message.address}`}</Text>
                      </Text>
                    </ContextMenu>
                    <View
                      accessible
                      accessibilityRole="text"
                      accessibilityLabel={t('message.received', {
                        date: dateFormat.format(new Date(message.receivedAt)),
                      })}>
                      <Text
                        style={[
                          styles.secondary,
                          { color: colors.textSecondary },
                        ]}>
                        {t('message.received', {
                          date: dateFormat.format(new Date(message.receivedAt)),
                        })}
                      </Text>
                    </View>
                  </View>
                  {address === undefined ? null : (
                    <Text
                      style={[
                        styles.secondary,
                        { color: colors.textSecondary },
                      ]}>
                      {t('inbox.inMailbox', { mailbox: address })}
                    </Text>
                  )}
                  {labelNames.length === 0 ? null : (
                    <Text
                      style={[
                        styles.secondary,
                        { color: colors.textSecondary },
                      ]}>
                      {t('message.labels', { labels: labelNames.join(', ') })}
                    </Text>
                  )}
                </View>
              </MessageMenu>
              <MessageActionsNotice id={message.id} />
              <ResponseStatusNotice
                status={responseStatus}
                id={message.id}
              />
              <ReaderBody
                key={message.id}
                inbox={actions}
                message={message}
                connection={mailbox?.id}
              />
            </ReaderScrollView>
          </>
        )}
      </View>
    </ResponseStatusContext>
  );
}
