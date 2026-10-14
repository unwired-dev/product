import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type { ResponseKind } from '@private-email/mail-core/responses';
import type { ReactNode } from 'react';

import {
  commandTarget,
  expectedCommands,
  responseCommands,
} from '@private-email/mail-core/commands';
import { profileOf, sendingMailboxes } from '@private-email/mail-core/drafts';
import { threadMessages } from '@private-email/mail-core/gmail-inbox';
import { startResponse } from '@private-email/mail-core/responses';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  use,
  useLayoutEffect,
  useMemo,
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
import { SafeAreaView } from 'react-native-screens/experimental';

import type { SavedAttachment } from './message-body.tsx';
import type { InboxStore } from './private-storage.ts';

import {
  CommandInput,
  CommandInputRow,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
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
  LinkConfirmationProvider,
  QuotedHistoryContext,
  ReaderScrollView,
  useReaderScrollTo,
} from './message-body.tsx';
import { MessageSummary } from './message-summary.tsx';
import { MessageActions } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    padding: spacing.xl,
  },
  // Under the fixed header, the first Thread message keeps its own top margin.
  threadContent: { paddingTop: 0 },
  header: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.xl,
  },
  headerText: { flex: 1 },
  subject: { ...textStyles.reading.subject },
  metadata: {
    gap: 5,
    marginTop: spacing.xl,
    paddingBottom: spacing.xl,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  sender: { ...textStyles.headline },
  control: { minHeight: 44, minWidth: 44, justifyContent: 'center' },
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  responses: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.xl,
    marginTop: spacing.xl,
  },
  secondary: { ...textStyles.subheadline },
  body: { ...textStyles.reading.body, marginTop: spacing.xl },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    gap: spacing.s,
  },
  emptyTitle: { ...textStyles.headline, textAlign: 'center' },
  emptyDescription: { ...textStyles.body, textAlign: 'center' },
  threadMessage: {
    gap: 5,
    marginTop: spacing.xl,
    paddingTop: spacing.xl,
    paddingHorizontal: spacing.l,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderRadius: radius.card,
  },
  // A bar beside the opened message, so it stands out without relying on color.
  openedMessage: { borderLeftWidth: 4 },
});

// Keeps the message being read in place while bodies above it load.
const keepVisibleMessage = { minIndexForVisible: 0 };

// Nothing selected, or a message that is not in any open mailbox.
function EmptyDetail({ id }: { readonly id: string | undefined }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <CommandInputRow />
      <View
        style={styles.empty}
        {...header.swipe}>
        <Text
          accessibilityRole="header"
          style={[styles.emptyTitle, { color: colors.textPrimary }]}
          {...header.action}>
          {id ? t('message.unavailable') : t('message.empty')}
        </Text>
        <Text
          style={[styles.emptyDescription, { color: colors.textSecondary }]}>
          {id ? t('message.chooseAnother') : t('message.select')}
        </Text>
      </View>
    </SafeAreaView>
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
  onClose,
  onCompose,
}: {
  // The mailbox the message belongs to; Gmail message IDs are unique only within it.
  readonly mailbox: string | undefined;
  readonly id: string | undefined;
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
    state.messages.find((item) => item.id === id) ??
    ('found' in state ? state.found?.find((item) => item.id === id) : undefined)
  );
};

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
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const mounted = useRef(true);
  const starting = useRef(false);
  const [pending, setPending] = useState<ResponseKind | undefined>();
  const [failed, setFailed] = useState(false);
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
    setFailed(false);
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
        setFailed(true);
      }
    }
    // Not in `finally`: React Compiler cannot compile a finally clause.
    starting.current = false;
    if (mounted.current) {
      setPending(undefined);
    }
  };
  const actions = [
    ['reply', t('message.reply')],
    ['replyAll', t('message.replyAll')],
    ['forward', t('message.forward')],
  ] as const;
  return (
    <View>
      <RegisterCommands
        offer={() =>
          responseCommands(t, commandTarget(mailbox?.id, message), start)
        }
      />
      <View style={styles.responses}>
        {actions.map(([kind, label]) => (
          <Pressable
            style={styles.control}
            key={kind}
            accessibilityRole="button"
            accessibilityLabel={label}
            accessibilityState={{ disabled: pending !== undefined }}
            disabled={pending !== undefined}
            onPress={() => {
              void start(kind);
            }}>
            <Text style={[styles.secondary, { color: colors.accentInk }]}>
              {label}
            </Text>
          </Pressable>
        ))}
      </View>
      {pending === 'forward' ? (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('message.preparingForward')}
        </Text>
      ) : null}
      {failed ? (
        <Text
          accessibilityLiveRegion="polite"
          accessibilityRole="alert"
          style={[styles.secondary, { color: colors.textPrimary }]}>
          {t('message.respondFailed')}
        </Text>
      ) : null}
    </View>
  );
}

// The scoped mailbox's storage could not open; retrying opens it again.
function StorageProblem({ kind }: { readonly kind: 'locked' | 'failed' }) {
  const actions = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={styles.fill}>
      <CommandInputRow />
      <View
        style={styles.empty}
        {...header.swipe}>
        <Text
          accessibilityRole="alert"
          style={[styles.emptyDescription, { color: colors.textPrimary }]}
          {...header.action}>
          {kind === 'locked' ? t('storage.locked') : t('storage.failed')}
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
    </SafeAreaView>
  );
}

// The scoped mailbox's storage is still opening. ActivityIndicator sizes its native view to the
// spinner and leaves it out of the accessibility tree unless `accessible`, so the swipe goes on a
// full-size wrapper and the action on the now accessible spinner.
function ReaderLoading() {
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={styles.fill}>
      <CommandInputRow />
      <View
        style={styles.fill}
        {...header.swipe}>
        <ActivityIndicator
          accessible
          accessibilityLabel={t('message.loading')}
          style={styles.fill}
          {...header.action}
        />
      </View>
    </SafeAreaView>
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

// The reader's subject, which stays put while the body scrolls: it is the screen's header, which
// opens the Command Palette by a downward swipe, its accessibility action or, on iPad, its command
// input. It also lists the message's expected commands, disabled until a section offers them.
function ReaderHeader({
  message,
}: {
  readonly message: Readonly<{ id: string; subject: string }>;
}) {
  const mailbox = useMailbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  return (
    <>
      <RegisterCommands
        offer={() =>
          expectedCommands(t, {
            target: commandTarget(mailbox?.id, message),
            disabled: t('commands.unavailable'),
          })
        }
      />
      <View
        style={styles.header}
        {...header.swipe}>
        <View
          accessible
          accessibilityLabel={message.subject}
          accessibilityRole="header"
          style={styles.headerText}
          {...header.action}>
          <Text
            selectable
            style={[styles.subject, { color: colors.textPrimary }]}>
            {message.subject}
          </Text>
        </View>
        <CommandInput />
      </View>
    </>
  );
}

function MailboxMessage({
  id,
  onClose,
  onCompose,
}: {
  readonly id: string;
  readonly onClose: (() => void) | undefined;
  readonly onCompose: ((id: string) => void) | undefined;
}) {
  const state = useInbox();
  const actions = useInboxActions();
  const mailbox = useMailbox();
  const address = mailbox?.address;
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
    return <ReaderLoading />;
  }

  if (state.kind === 'locked' || state.kind === 'failed') {
    return <StorageProblem kind={state.kind} />;
  }

  if (message === undefined) {
    return <EmptyDetail id={id} />;
  }

  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <LinkConfirmationProvider
        inbox={actions}
        ids={[message.id]}>
        <ReaderHeader message={message} />
        <ReaderScrollView contentContainerStyle={styles.content}>
          <MessageActions
            id={message.id}
            onClose={onClose}
          />
          <View
            style={[styles.metadata, { borderBottomColor: colors.separator }]}>
            <Text
              selectable
              style={[styles.sender, { color: colors.textPrimary }]}>
              {message.sender}
            </Text>
            <Text
              selectable
              style={[styles.secondary, { color: colors.textSecondary }]}>
              {message.address}
            </Text>
            <Text style={[styles.secondary, { color: colors.textSecondary }]}>
              {t('message.received', {
                date: dateFormat.format(new Date(message.receivedAt)),
              })}
            </Text>
            {address === undefined ? null : (
              <Text style={[styles.secondary, { color: colors.textSecondary }]}>
                {t('inbox.inMailbox', { mailbox: address })}
              </Text>
            )}
            {labelNames.length === 0 ? null : (
              <Text style={[styles.secondary, { color: colors.textSecondary }]}>
                {t('message.labels', { labels: labelNames.join(', ') })}
              </Text>
            )}
          </View>
          <ResponseActions
            key={`${address}:${message.id}`}
            message={message}
            onCompose={onCompose}
          />
          <ReaderBody
            key={message.id}
            inbox={actions}
            message={message}
            connection={mailbox?.id}
          />
        </ReaderScrollView>
      </LinkConfirmationProvider>
    </SafeAreaView>
  );
}

// A Thread: every locally cached message of the opened message's Gmail thread, newest at the top,
// opened scrolled to that message and highlighting it, with quoted history collapsed.
export function ThreadView({
  mailbox,
  id,
}: {
  // The mailbox the message belongs to; Gmail message IDs are unique only within it.
  readonly mailbox: string | undefined;
  readonly id: string | undefined;
}) {
  const profile = useProfile();
  if (mailbox === undefined || id === undefined) {
    return <EmptyDetail id={id} />;
  }
  return (
    <MailboxScope
      id={mailbox}
      fallback={<EmptyDetail id={id} />}>
      <ReaderMailAssistanceGate profile={profile}>
        <ThreadMessages
          key={`${mailbox}/${id}`}
          id={id}
        />
      </ReaderMailAssistanceGate>
    </MailboxScope>
  );
}

function ThreadMessages({ id }: { readonly id: string }) {
  const state = useInbox();
  const inbox = useInboxActions();
  const colors = usePalette();
  const messages = useMemo(
    () =>
      state.kind === 'ready' && 'labels' in state
        ? threadMessages(state, id)
        : [],
    [state, id],
  );
  if (state.kind === 'loading') {
    return <ReaderLoading />;
  }
  if (state.kind === 'locked' || state.kind === 'failed') {
    return <StorageProblem kind={state.kind} />;
  }
  const opened = shownMessage(state, id);
  if (
    state.kind !== 'ready' ||
    opened === undefined ||
    !('threadId' in opened) ||
    !('responseSource' in inbox)
  ) {
    return <EmptyDetail id={id} />;
  }
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <QuotedHistoryContext value="collapsible">
        <LinkConfirmationProvider
          inbox={inbox}
          ids={messages.map((message) => message.id)}>
          <ReaderHeader message={opened} />
          <ReaderScrollView
            contentContainerStyle={[styles.content, styles.threadContent]}
            maintainVisibleContentPosition={keepVisibleMessage}>
            {messages.map((message) => (
              <ThreadMessage
                key={message.id}
                inbox={inbox}
                message={message}
                highlighted={message.id === id}
              />
            ))}
          </ReaderScrollView>
        </LinkConfirmationProvider>
      </QuotedHistoryContext>
    </SafeAreaView>
  );
}

function ThreadMessage({
  inbox,
  message,
  highlighted,
}: {
  readonly inbox: GmailInbox;
  readonly message: Readonly<{
    id: string;
    sender: string;
    subject: string;
    receivedAt: string;
  }>;
  // The opened message, which the Thread scrolls to once it is laid out.
  readonly highlighted: boolean;
}) {
  const mailbox = useMailbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const scrollTo = useReaderScrollTo();
  const scrolled = useRef(false);
  return (
    <View
      onLayout={({ nativeEvent }) => {
        if (highlighted && !scrolled.current) {
          scrolled.current = true;
          scrollTo?.(nativeEvent.layout.y);
        }
      }}
      style={[
        styles.threadMessage,
        { borderTopColor: colors.separator },
        highlighted
          ? [
              styles.openedMessage,
              {
                backgroundColor: colors.accentSelectionSubtle,
                borderLeftColor: colors.accentInk,
              },
            ]
          : null,
      ]}>
      <Text
        accessibilityState={highlighted ? { selected: true } : undefined}
        selectable
        style={[styles.sender, { color: colors.textPrimary }]}>
        {message.sender}
      </Text>
      <Text style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('message.received', {
          date: dateFormat.format(new Date(message.receivedAt)),
        })}
      </Text>
      <GmailMessageBody
        inbox={inbox}
        id={message.id}
        subject={message.subject}
        connection={mailbox?.id}
      />
    </View>
  );
}
