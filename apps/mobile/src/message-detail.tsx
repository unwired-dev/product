import type { GmailInbox } from '@private-email/mail-core/gmail-inbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type { ResponseKind } from '@private-email/mail-core/responses';
import type { Dispatch, ReactNode, SetStateAction } from 'react';

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
  createContext,
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  Modal,
  Platform,
  ScrollView,
  Pressable,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import Animated from 'react-native-reanimated';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { SavedAttachment } from './message-body.tsx';
import type { InboxStore } from './private-storage.ts';

import {
  CommandInput,
  CommandInputRow,
  RegisterCommands,
  usePaletteHeader,
} from './command-palette.tsx';
import {
  Glass,
  GlassGroup,
  growEntering,
  Monogram,
  SFSymbol,
  ToolbarButton,
  useEntering,
} from './design.tsx';
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
import { MessageActions, MessageActionsNotice } from './organize.tsx';
import { MessageCount, MessageHeader, ReaderHeader } from './reader-chrome.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

// On iPhone the reader is a pushed screen with its own header and bottom toolbar, in every
// orientation; on iPad the toolbar sits at the top like the Mac's.
const compact = Platform.OS === 'ios' && !Platform.isPad;
const replySheetWidth = 500;
const responseIcons = {
  reply: 'arrowshape.turn.up.left',
  replyAll: 'arrowshape.turn.up.left.2',
  forward: 'arrowshape.turn.up.right',
} as const;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // iPhone's Reply sheet floats inside the screen edges and grows out of the Reply button.
  replyBackdrop: { flex: 1, justifyContent: 'flex-end', padding: spacing.s },
  replySheet: {
    width: '100%',
    maxWidth: replySheetWidth,
    maxHeight: '100%',
    alignSelf: 'center',
    borderRadius: radius.sheet,
    borderCurve: 'continuous',
  },
  replyContent: { gap: spacing.l, padding: spacing.l },
  replyHeader: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  replyFrom: { flex: 1 },
  replySender: { ...textStyles.headline },
  replyClose: {
    width: 44,
    height: 44,
    borderRadius: 22,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  replyTiles: { flexDirection: 'row', gap: spacing.s },
  replyTile: {
    flex: 1,
    minHeight: 64,
    gap: spacing.xs,
    paddingHorizontal: spacing.xs,
    paddingVertical: spacing.s,
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  replyLabel: { ...textStyles.subheadline, textAlign: 'center' },
  // The regular-width toolbar: glass groups at the pane's trailing edge.
  topToolbar: {
    height: 52 + spacing.m,
    zIndex: 1,
    alignItems: 'flex-end',
    paddingTop: spacing.m,
    paddingHorizontal: spacing.l,
  },
  // The compact toolbar floats over the content's bottom edge.
  bottomToolbar: {
    position: 'absolute',
    left: spacing.l,
    right: spacing.l,
    bottom: spacing.l,
    flexDirection: 'row',
    alignItems: 'flex-end',
    justifyContent: 'space-between',
    gap: spacing.s,
  },
  bottomActions: {
    flexShrink: 1,
    flexDirection: 'column-reverse',
    gap: spacing.s,
  },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.s,
    gap: spacing.l,
  },
  compactContent: { paddingBottom: 52 + 2 * spacing.l },
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
    gap: 2,
    paddingBottom: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  control: { minHeight: 44, minWidth: 44, justifyContent: 'center' },
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  secondary: { ...textStyles.footnote },
  body: { ...textStyles.reading.body },
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
    gap: 10,
    paddingVertical: 14,
    paddingHorizontal: spacing.l,
    borderBottomWidth: StyleSheet.hairlineWidth,
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

// The reader's header where the compact Back header is absent: the subject, the iPad command
// input, and the gestures that open the Command Palette.
function RegularHeader({ subject }: { readonly subject: string }) {
  const colors = usePalette();
  const header = usePaletteHeader();
  return (
    <View
      style={styles.header}
      {...header.swipe}>
      <View
        accessible
        accessibilityLabel={subject}
        accessibilityRole="header"
        style={styles.headerText}
        {...header.action}>
        <Text
          selectable
          style={[styles.subject, { color: colors.textPrimary }]}>
          {subject}
        </Text>
      </View>
      <CommandInput />
    </View>
  );
}

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
    <Text
      accessibilityLiveRegion="polite"
      accessibilityRole="alert"
      style={[styles.secondary, { color: colors.textPrimary }]}>
      {t('message.respondFailed')}
    </Text>
  ) : (
    <Text
      accessibilityLiveRegion="polite"
      style={[styles.secondary, { color: colors.textSecondary }]}>
      {t('message.preparingForward')}
    </Text>
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
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const mounted = useRef(true);
  const starting = useRef(false);
  const [pending, setPending] = useState<ResponseKind | undefined>();
  const report = use(ResponseStatusContext);
  const [focused, setFocused] = useState<string>();
  const source = useSyncExternalStore(inbox.subscribe, () =>
    'responseSource' in inbox ? inbox.responseSource(message.id) : undefined,
  );
  const [choosing, setChoosing] = useState<typeof source>();
  const [origin, setOrigin] = useState(0);
  const { width } = useWindowDimensions();
  const sheetWidth = Math.min(width - 2 * spacing.s, replySheetWidth);
  const entering = useEntering(growEntering);
  const close = () => {
    setChoosing(undefined);
  };
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
      {compact ? (
        <ToolbarButton
          icon="arrowshape.turn.up.left"
          label={t('message.reply')}
          disabled={pending !== undefined}
          expanded={choosing === source}
          onPress={(event) => {
            // Keyboard activation reports no touch; grow from the middle then.
            setOrigin(event.nativeEvent.pageX || width / 2);
            setChoosing(source);
          }}
        />
      ) : (
        <>
          <ToolbarButton
            icon="arrowshape.turn.up.left"
            label={t('message.reply')}
            disabled={pending !== undefined}
            onPress={() => {
              void start('reply');
            }}
          />
          <ToolbarButton
            icon="arrowshape.turn.up.left.2"
            label={t('message.replyAll')}
            disabled={pending !== undefined}
            onPress={() => {
              void start('replyAll');
            }}
          />
          <ToolbarButton
            icon="arrowshape.turn.up.right"
            label={t('message.forward')}
            disabled={pending !== undefined}
            onPress={() => {
              void start('forward');
            }}
          />
        </>
      )}
      {compact && choosing !== undefined && choosing === source ? (
        <Modal
          visible
          transparent
          animationType="fade"
          onRequestClose={close}
          supportedOrientations={[
            'portrait',
            'portrait-upside-down',
            'landscape-left',
            'landscape-right',
          ]}>
          <View
            style={[
              styles.replyBackdrop,
              { backgroundColor: colors.scrimTouch },
            ]}>
            <Pressable
              accessible={false}
              onPress={close}
              style={StyleSheet.absoluteFill}
            />
            <Animated.View
              accessibilityViewIsModal
              entering={entering}
              onAccessibilityEscape={close}
              style={[
                styles.replySheet,
                {
                  boxShadow: colors.menuGlassShadow,
                  // The sheet grows out of where Reply was pressed.
                  transformOrigin: `${Math.max(0, origin - (width - sheetWidth) / 2)}px 100%`,
                },
              ]}>
              <Glass
                cornerRadius={radius.sheet}
                style={StyleSheet.absoluteFill}
              />
              <ScrollView
                style={{ flexGrow: 0 }}
                contentContainerStyle={styles.replyContent}>
                <View style={styles.replyHeader}>
                  <Monogram name={message.sender} />
                  <View style={styles.replyFrom}>
                    <Text
                      numberOfLines={1}
                      style={[
                        styles.replySender,
                        { color: colors.textPrimary },
                      ]}>
                      {message.sender}
                    </Text>
                    <Text
                      numberOfLines={1}
                      style={[
                        styles.secondary,
                        { color: colors.textSecondary },
                      ]}>
                      {message.preview}
                    </Text>
                  </View>
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel={t('message.closeResponses')}
                    onFocus={() => {
                      setFocused('close');
                    }}
                    onBlur={() => {
                      setFocused(undefined);
                    }}
                    onPress={close}
                    style={({ pressed }) => [
                      styles.replyClose,
                      {
                        backgroundColor: pressed
                          ? colors.accentSelectionSubtle
                          : colors.fillQuiet,
                        borderColor:
                          focused === 'close'
                            ? colors.accentInk
                            : 'transparent',
                      },
                    ]}>
                    <SFSymbol
                      name="xmark"
                      color={colors.textPrimary}
                    />
                  </Pressable>
                </View>
                <View style={styles.replyTiles}>
                  {(['reply', 'replyAll', 'forward'] as const).map((kind) => (
                    <Pressable
                      key={kind}
                      accessibilityRole="button"
                      accessibilityLabel={t(`message.${kind}`)}
                      onFocus={() => {
                        setFocused(kind);
                      }}
                      onBlur={() => {
                        setFocused(undefined);
                      }}
                      onPress={() => {
                        close();
                        void start(kind);
                      }}
                      style={({ pressed }) => [
                        styles.replyTile,
                        {
                          backgroundColor: pressed
                            ? colors.accentSelectionSubtle
                            : colors.fillQuiet,
                          borderColor:
                            focused === kind ? colors.accentInk : 'transparent',
                        },
                      ]}>
                      <SFSymbol
                        name={responseIcons[kind]}
                        size={22}
                        color={colors.textPrimary}
                      />
                      <Text
                        style={[
                          styles.replyLabel,
                          { color: colors.textPrimary },
                        ]}>
                        {t(`message.${kind}`)}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              </ScrollView>
            </Animated.View>
          </View>
        </Modal>
      ) : null}
    </>
  );
}

// Starts a new message from the reader's mailbox, as the Inbox's New Message does.
function ComposeButton({
  mailbox,
  onCompose,
}: {
  readonly mailbox: MailboxConnection;
  readonly onCompose: (id: string) => void;
}) {
  const store = useDraftStore();
  const drafts = useDrafts();
  const navigation = useComposerNavigation();
  const { t } = useLocalization();
  const creating = useRef(false);
  const mounted = useRef(true);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const compose = async () => {
    if (!mounted.current || creating.current) {
      return;
    }
    creating.current = true;
    // Leaving and creating resolve rather than reject, so the press always settles here.
    const id = await navigation.create(store, mailbox);
    creating.current = false;
    if (mounted.current && id !== undefined) {
      onCompose(id);
    }
  };
  return (
    <GlassGroup>
      <ToolbarButton
        icon="square.and.pencil"
        label={t('drafts.newMessage')}
        disabled={drafts.kind !== 'ready'}
        onPress={() => {
          void compose();
        }}
      />
    </GlassGroup>
  );
}

// The reader's actions: read state alone for the preview fixture, otherwise the provider's
// organizing actions around Reply, Reply All and Forward.
function MessageToolbar({
  message,
  onClose,
  onCompose,
}: {
  readonly message: NonNullable<ReturnType<typeof shownMessage>>;
  readonly onClose: (() => void) | undefined;
  readonly onCompose: ((id: string) => void) | undefined;
}) {
  const address = useMailbox()?.address;
  return (
    <MessageActions
      id={message.id}
      onClose={onClose}>
      <ResponseActions
        key={`${address}:${message.id}`}
        message={message}
        onCompose={onCompose}
      />
    </MessageActions>
  );
}

// The opened message's header, mailbox and labels above a hairline.
function MessageMetadata({
  message,
}: {
  readonly message: NonNullable<ReturnType<typeof shownMessage>>;
}) {
  const state = useInbox();
  const address = useMailbox()?.address;
  const colors = usePalette();
  const { t } = useLocalization();
  const applied = new Set('labels' in message ? message.labels : []);
  const labelNames =
    state.kind === 'ready' && 'labels' in state
      ? state.labels
          .filter((label) => applied.has(label.id))
          .map((label) => label.name)
      : [];
  return (
    <View style={[styles.metadata, { borderBottomColor: colors.separator }]}>
      <MessageHeader message={message} />
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
  const account = use(AccountContext);
  const [responseStatus, setResponseStatus] = useState<ResponseStatus>();
  const colors = usePalette();
  const { t } = useLocalization();
  // An IMAP message can come from any folder this mailbox has read, not only its Inbox.
  const folderMessage = useSyncExternalStore(actions.subscribe, () =>
    'openFolder' in actions ? actions.message(id) : undefined,
  );
  const message = folderMessage ?? shownMessage(state, id);
  // A new message sends from the reader's mailbox when it can, or the first one in its Mail
  // Profile that can, as the Inbox's New Message does.
  const mailboxes = account?.mailboxes ?? [];
  const senders = sendingMailboxes(
    mailboxes,
    profileOf(mailbox?.id, mailboxes),
  );
  const sender =
    senders.find(({ id: candidate }) => candidate === mailbox?.id) ??
    senders[0];

  if (state.kind === 'loading') {
    return <ReaderLoading />;
  }

  if (state.kind === 'locked' || state.kind === 'failed') {
    return <StorageProblem kind={state.kind} />;
  }

  if (message === undefined) {
    return <EmptyDetail id={id} />;
  }

  // The compact header carries the subject and Back; without a way back use the regular header.
  const header = compact && onClose !== undefined;
  const toolbar = (
    <MessageToolbar
      message={message}
      onClose={onClose}
      onCompose={onCompose}
    />
  );
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <ResponseStatusContext value={setResponseStatus}>
        <LinkConfirmationProvider
          inbox={actions}
          ids={[message.id]}>
          <RegisterCommands
            offer={() =>
              expectedCommands(t, {
                target: commandTarget(mailbox?.id, message),
                disabled: t('commands.unavailable'),
              })
            }
          />
          {header ? (
            <ReaderHeader
              subject={message.subject}
              onClose={onClose}
            />
          ) : null}
          {compact ? null : <View style={styles.topToolbar}>{toolbar}</View>}
          {header ? null : <RegularHeader subject={message.subject} />}
          <ReaderScrollView
            contentContainerStyle={[
              styles.content,
              compact ? styles.compactContent : null,
            ]}>
            <MessageMetadata message={message} />
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
          {compact ? (
            <View style={styles.bottomToolbar}>
              <View style={styles.bottomActions}>{toolbar}</View>
              {sender === undefined || onCompose === undefined ? null : (
                <View>
                  <ComposeButton
                    mailbox={sender}
                    onCompose={onCompose}
                  />
                </View>
              )}
            </View>
          ) : null}
        </LinkConfirmationProvider>
      </ResponseStatusContext>
    </SafeAreaView>
  );
}

// A Thread: every locally cached message of the opened message's Gmail thread, newest at the top,
// opened scrolled to that message and highlighting it, with quoted history collapsed.
export function ThreadView({
  mailbox,
  id,
  onClose,
}: {
  // The mailbox the message belongs to; Gmail message IDs are unique only within it.
  readonly mailbox: string | undefined;
  readonly id: string | undefined;
  // Leaves the Thread; the compact header's Back.
  readonly onClose?: (() => void) | undefined;
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
          onClose={onClose}
        />
      </ReaderMailAssistanceGate>
    </MailboxScope>
  );
}

function ThreadMessages({
  id,
  onClose,
}: {
  readonly id: string;
  readonly onClose: (() => void) | undefined;
}) {
  const state = useInbox();
  const inbox = useInboxActions();
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
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
  const header = compact && onClose !== undefined;
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <QuotedHistoryContext value="collapsible">
        <LinkConfirmationProvider
          inbox={inbox}
          ids={messages.map((message) => message.id)}>
          <RegisterCommands
            offer={() =>
              expectedCommands(t, {
                target: commandTarget(mailbox?.id, opened),
                disabled: t('commands.unavailable'),
              })
            }
          />
          {header ? (
            <ReaderHeader
              subject={opened.subject}
              onClose={onClose}
            />
          ) : (
            <RegularHeader subject={opened.subject} />
          )}
          <ReaderScrollView
            contentContainerStyle={styles.content}
            maintainVisibleContentPosition={keepVisibleMessage}>
            <MessageCount count={messages.length} />
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
    address: string;
    subject: string;
    receivedAt: string;
  }>;
  // The opened message, which the Thread scrolls to once it is laid out.
  readonly highlighted: boolean;
}) {
  const mailbox = useMailbox();
  const colors = usePalette();
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
        { borderBottomColor: colors.separator },
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
      <MessageHeader
        message={message}
        highlighted={highlighted}
      />
      <GmailMessageBody
        inbox={inbox}
        id={message.id}
        subject={message.subject}
        connection={mailbox?.id}
      />
    </View>
  );
}
