import type { Translate } from '@private-email/localization';
import type {
  DeliveryProblem,
  OutboxEntry,
} from '@private-email/mail-core/drafts';

import { draftSummary } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import { StyleSheet, Text, View } from 'react-native';

import { Action } from './composer.tsx';
import { useLocalization } from './localization.ts';
import { useOutbox } from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  section: {
    fontSize: 13,
    fontWeight: '600',
    paddingHorizontal: spacing.large,
    paddingTop: spacing.small,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.small,
    marginHorizontal: spacing.small,
    padding: 14,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  grow: { flex: 1, gap: 4 },
  subject: { fontSize: 15, fontWeight: '500' },
  detail: { fontSize: 13 },
});

// Why a message waits or was refused, as the person reads it.
const problems = {
  offline: 'outbox.queued.offline',
  locked: 'outbox.queued.locked',
  'rate-limited': 'outbox.queued.rate-limited',
  claimed: 'outbox.failed.claimed',
  authorization: 'outbox.failed.authorization',
  mailbox: 'outbox.failed.mailbox',
  assets: 'outbox.failed.assets',
  'too-large': 'outbox.failed.too-large',
  refused: 'outbox.failed.refused',
} as const satisfies Readonly<Record<DeliveryProblem, string>>;

// Where a message stands, in words: waiting out Undo Send, waiting to send and why, sending,
// refused and why, or handed to Gmail without a confirmed outcome.
const statusOf = (t: Translate, { state, problem }: OutboxEntry) => {
  if ((state === 'queued' || state === 'failed') && problem !== undefined) {
    return t(problems[problem]);
  }
  if (state === 'failed') {
    return t('outbox.failed.refused');
  }
  return t(`outbox.state.${state === 'queued' ? 'sending' : state}`);
};

export function OutboxRow({
  entry,
  onOpen,
}: {
  readonly entry: OutboxEntry;
  readonly onOpen: (id: string) => Promise<void>;
}) {
  const outbox = useOutbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const { subject, recipients } = draftSummary(t, entry.draft);
  const status = statusOf(t, entry);
  // Only a message never handed to Gmail returns to the Drafts.
  const returning = entry.state === 'waiting' ? 'undo' : 'edit';
  return (
    <View style={[styles.row, { backgroundColor: colors.sidebar }]}>
      <View
        accessible
        accessibilityLabel={t('outbox.rowLabel', {
          subject,
          recipients,
          status,
        })}
        style={styles.grow}>
        <Text
          numberOfLines={1}
          style={[styles.subject, { color: colors.foreground }]}>
          {subject}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.detail, { color: colors.secondary }]}>
          {recipients}
        </Text>
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.detail, { color: colors.secondary }]}>
          {status}
        </Text>
      </View>
      {entry.state === 'sending' || entry.state === 'unknown' ? null : (
        <Action
          label={t(`outbox.${returning}`)}
          onPress={() => {
            void (async () => {
              const id = await outbox.undo(entry.id);
              if (id !== false) {
                await onOpen(id);
              }
            })();
          }}
        />
      )}
    </View>
  );
}

export function OutboxHeading() {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View
      accessible
      accessibilityLabel={t('outbox.heading')}
      accessibilityRole="header">
      <Text style={[styles.section, { color: colors.secondary }]}>
        {t('outbox.heading')}
      </Text>
    </View>
  );
}
