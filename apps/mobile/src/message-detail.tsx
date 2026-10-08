import type { ReactNode } from 'react';

import { sendingMailboxes } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import { use } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { SavedAttachment } from './message-body.tsx';

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

const dateFormat = new Intl.DateTimeFormat('en', {
  dateStyle: 'long',
  timeStyle: 'short',
  timeZone: 'UTC',
});

// Nothing selected, or a message that is not in any open mailbox.
function EmptyDetail({ id }: { readonly id: string | undefined }) {
  const colors = usePalette();
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.background }]}>
      <View style={styles.empty}>
        <Text
          accessibilityRole="header"
          style={[styles.emptyTitle, { color: colors.foreground }]}>
          {id ? 'Message unavailable' : 'A little space for your mail'}
        </Text>
        <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
          {id
            ? 'Choose another message from the Inbox.'
            : 'Select a message to start reading.'}
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
  const navigation = useComposerNavigation();
  const account = use(AccountContext);
  const mailbox = useMailbox();
  const attach = async (saved: SavedAttachment) => {
    const senders = sendingMailboxes(account?.mailboxes ?? []);
    const sender = senders.find(({ id }) => id === mailbox?.id) ?? senders[0];
    if (sender === undefined || mailbox === undefined) {
      return;
    }
    const draft = await navigation.create(store, sender);
    if (draft === undefined) {
      return;
    }
    await store.attach(draft, [
      {
        name: saved.name,
        type: saved.type,
        source: {
          kind: 'received',
          mailbox: {
            connection: mailbox.id,
            address: saved.address,
            generation: saved.generation,
          },
          file: saved.file,
        },
      },
    ]);
    onCompose(draft);
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
        <AttachToNewMessage onCompose={onCompose}>{message}</AttachToNewMessage>
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
        accessibilityLabel="Loading message"
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
          {state.kind === 'locked'
            ? 'Private storage is locked. Unlock your device and try again.'
            : 'Private storage could not be opened or saved. Your stored data has been kept.'}
        </Text>
        <Pressable
          accessibilityRole="button"
          onPress={() => {
            void actions.load();
          }}>
          <Text style={[styles.secondary, { color: colors.accent }]}>
            Try again
          </Text>
        </Pressable>
      </View>
    );
  }

  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.background }]}>
      {message === undefined ? (
        <View style={styles.empty}>
          <Text
            accessibilityRole="header"
            style={[styles.emptyTitle, { color: colors.foreground }]}>
            Message unavailable
          </Text>
          <Text style={[styles.emptyDescription, { color: colors.secondary }]}>
            Choose another message from the Inbox.
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
                  {message.unread ? 'Mark as read' : 'Mark as unread'}
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
                {dateFormat.format(new Date(message.receivedAt))} UTC
              </Text>
              {address === undefined ? null : (
                <Text style={[styles.secondary, { color: colors.secondary }]}>
                  {`In ${address}`}
                </Text>
              )}
              {labelNames.length === 0 ? null : (
                <Text style={[styles.secondary, { color: colors.secondary }]}>
                  {`Labels: ${labelNames.join(', ')}`}
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
    </SafeAreaView>
  );
}
