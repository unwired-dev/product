import { spacing } from '@private-email/mail-core/theme';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { useLocalization, useMessageDateFormat } from './localization.ts';
import {
  MailboxScope,
  useInbox,
  useInboxActions,
  useMailbox,
} from './mailbox.tsx';
import { GmailMessageBody, LinkConfirmationProvider } from './message-body.tsx';
import { MessageSummary } from './message-summary.tsx';
import { MessageActions } from './organize.tsx';
import { usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

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

export function MessageDetail({
  mailbox,
  id,
  onClose,
}: {
  // The mailbox the message belongs to; Gmail message IDs are unique only within it.
  readonly mailbox: string | undefined;
  readonly id: string | undefined;
  // Leaves the reader after its message leaves the Inbox.
  readonly onClose?: (() => void) | undefined;
}) {
  if (mailbox === undefined || id === undefined) {
    return <EmptyDetail id={id} />;
  }
  return (
    <MailboxScope
      id={mailbox}
      fallback={<EmptyDetail id={id} />}>
      <MailboxMessage
        id={id}
        onClose={onClose}
      />
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
                subject={message.subject}
              />
            ) : (
              <>
                <MessageSummary
                  source={actions}
                  id={message.id}
                  subject={message.subject}
                  body={'body' in message ? message.body : message.preview}
                />
                <MessageTranslation
                  source={actions}
                  id={message.id}
                  body={'body' in message ? message.body : message.preview}
                />
                <Text
                  selectable
                  style={[styles.body, { color: colors.foreground }]}>
                  {'body' in message ? message.body : message.preview}
                </Text>
              </>
            )}
          </ScrollView>
        </LinkConfirmationProvider>
      )}
    </View>
  );
}
