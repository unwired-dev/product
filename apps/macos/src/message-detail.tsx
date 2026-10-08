import type { ReactNode } from 'react';

import { spacing } from '@private-email/mail-core/theme';
import { use, useLayoutEffect, useRef } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { SavedAttachment } from './message-body.tsx';

import { useLocalization, useMessageDateFormat } from './localization.ts';
import {
  MailboxScope,
  useComposerNavigation,
  useDraftStore,
  useInbox,
  useInboxActions,
  useMailbox,
} from './mailbox.tsx';
import {
  AttachContext,
  GmailMessageBody,
  LinkConfirmationProvider,
} from './message-body.tsx';
import { MessageActions } from './organize.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    padding: spacing.extraLarge,
  },
  subject: {
    fontSize: 28,
    lineHeight: 36,
    fontWeight: '600',
    letterSpacing: -0.5,
  },
  metadata: {
    gap: 5,
    marginTop: spacing.large,
    paddingBottom: spacing.large,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  sender: { fontSize: 16, fontWeight: '600' },
  secondary: { fontSize: 14, lineHeight: 21 },
  body: { fontSize: 17, lineHeight: 28, marginTop: spacing.large },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.extraLarge,
    gap: spacing.small,
  },
  emptyTitle: { fontSize: 22, fontWeight: '500', textAlign: 'center' },
  emptyDescription: { fontSize: 16, textAlign: 'center' },
});

// Nothing selected, or a message that is not in any open mailbox.
function EmptyDetail({ id }: { readonly id: string | undefined }) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={[styles.fill, { backgroundColor: colors.background }]}>
      <View
        accessible
        accessibilityRole="text"
        accessibilityLabel={
          id ? t('message.unavailableLabel') : t('message.select')
        }
        style={styles.empty}>
        <Text
          accessibilityRole="header"
          style={[styles.emptyTitle, { color: colors.foreground }]}>
          {id ? t('message.unavailable') : t('message.empty')}
        </Text>
        <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
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
  const navigation = useComposerNavigation();
  const account = use(AccountContext);
  const mailbox = useMailbox();
  const mounted = useRef(true);
  const attaching = useRef(false);
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
    try {
      const draft = await navigation.attachReceived(store, {
        mailbox: mailbox.id,
        mailboxes: account?.mailboxes ?? [],
        saved,
      });
      if (mounted.current && draft !== undefined) {
        onCompose(draft);
      }
    } catch {
      // Keep the reader usable if an unexpected host operation rejects.
    }
    // Not in `finally`: React Compiler cannot compile a finally clause, and the catch above
    // handles every rejection.
    attaching.current = false;
  };
  return (
    <AttachContext
      value={(saved) => {
        void attach(saved);
      }}>
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
  if (mailbox === undefined || id === undefined) {
    return <EmptyDetail id={id} />;
  }
  const message = (
    <MailboxMessage
      id={id}
      onClose={onClose}
    />
  );
  return (
    <MailboxScope
      id={mailbox}
      fallback={<EmptyDetail id={id} />}>
      {onCompose === undefined ? (
        message
      ) : (
        <AttachToNewMessage
          key={`${mailbox}/${id}`}
          onCompose={onCompose}>
          {message}
        </AttachToNewMessage>
      )}
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

function MailboxMessage({
  id,
  onClose,
}: {
  readonly id: string;
  readonly onClose: (() => void) | undefined;
}) {
  const state = useInbox();
  const actions = useInboxActions();
  const address = useMailbox()?.address;
  const colors = usePalette();
  const { t } = useLocalization();
  const dateFormat = useMessageDateFormat(true);
  const message = shownMessage(state, id);
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
          style={[styles.emptyDescription, { color: colors.foreground }]}>
          {state.kind === 'locked' ? t('storage.locked') : t('storage.failed')}
        </Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void actions.load();
          }}>
          <Text style={[styles.secondary, { color: colors.accent }]}>
            {t('common.retry')}
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={[styles.fill, { backgroundColor: colors.background }]}>
      {message === undefined ? (
        <View
          accessible
          accessibilityRole="text"
          accessibilityLabel={t('message.unavailableLabel')}
          style={styles.empty}>
          <Text
            accessibilityRole="header"
            style={[styles.emptyTitle, { color: colors.foreground }]}>
            {t('message.unavailable')}
          </Text>
          <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
            {t('message.chooseAnother')}
          </Text>
        </View>
      ) : (
        <LinkConfirmationProvider
          inbox={actions}
          id={message.id}>
          <ScrollView contentContainerStyle={styles.content}>
            {'setUnread' in actions ? (
              <Pressable
                accessibilityRole="button"
                onPress={() => {
                  void actions.setUnread(message.id, !message.unread);
                }}>
                <Text style={[styles.secondary, { color: colors.accent }]}>
                  {message.unread
                    ? t('message.markRead')
                    : t('message.markUnread')}
                </Text>
              </Pressable>
            ) : (
              <MessageActions
                id={message.id}
                onClose={onClose}
              />
            )}
            <Text
              accessibilityRole="header"
              selectable
              style={[styles.subject, { color: colors.foreground }]}>
              {message.subject}
            </Text>
            <View
              style={[
                styles.metadata,
                { borderBottomColor: colors.separator },
              ]}>
              <Text
                selectable
                style={[styles.sender, { color: colors.foreground }]}>
                {message.sender}
              </Text>
              <Text
                selectable
                style={[styles.secondary, { color: colors.secondary }]}>
                {message.address}
              </Text>
              <Text style={[styles.secondary, { color: colors.secondary }]}>
                {t('message.received', {
                  date: dateFormat.format(new Date(message.receivedAt)),
                })}
              </Text>
              {address === undefined ? null : (
                <Text style={[styles.secondary, { color: colors.secondary }]}>
                  {t('inbox.inMailbox', { mailbox: address })}
                </Text>
              )}
              {labelNames.length === 0 ? null : (
                <Text style={[styles.secondary, { color: colors.secondary }]}>
                  {t('message.labels', { labels: labelNames.join(', ') })}
                </Text>
              )}
            </View>
            {'readMessage' in actions ? (
              <GmailMessageBody
                key={message.id}
                id={message.id}
                inbox={actions}
              />
            ) : (
              <Text
                selectable
                style={[styles.body, { color: colors.foreground }]}>
                {'body' in message ? message.body : message.preview}
              </Text>
            )}
          </ScrollView>
        </LinkConfirmationProvider>
      )}
    </View>
  );
}
