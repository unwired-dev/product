import type { Translate } from '@private-email/localization';
import type {
  DeliveryProblem,
  OutboxEntry,
} from '@private-email/mail-core/drafts';

import { draftSummary } from '@private-email/mail-core/drafts';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Action } from './composer.tsx';
import { useLocalization } from './localization.ts';
import { useOutbox } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  section: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.s,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
    marginHorizontal: spacing.s,
    padding: 14,
    borderRadius: radius.row,
    borderCurve: 'continuous',
  },
  grow: { flex: 1, gap: 4 },
  subject: { ...textStyles.subheadline },
  detail: { ...textStyles.footnote },
  recovery: { flexBasis: '100%', gap: 4 },
  actions: { flexDirection: 'row', gap: spacing.s },
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

// The way out of an unknown outcome: ask Gmail again, or, after a warning that Gmail may already
// have sent it, return the message to the Drafts to send again deliberately.
function UnknownRecovery({
  id,
  onEdit,
}: {
  readonly id: string;
  readonly onEdit: () => void;
}) {
  const outbox = useOutbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const [step, setStep] = useState<
    'idle' | 'checking' | 'unconfirmed' | 'confirming'
  >('idle');
  const notice =
    step === 'unconfirmed' || step === 'confirming'
      ? t(`outbox.unknown.${step}`)
      : undefined;
  return (
    <View style={styles.recovery}>
      {notice === undefined ? null : (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.detail, { color: colors.textSecondary }]}>
          {notice}
        </Text>
      )}
      {step === 'confirming' ? (
        <View style={styles.actions}>
          <Action
            label={t('outbox.unknown.cancel')}
            onPress={() => {
              setStep('idle');
            }}
          />
          <Action
            destructive
            label={t('outbox.unknown.editAnyway')}
            onPress={onEdit}
          />
        </View>
      ) : (
        <View style={styles.actions}>
          <Action
            disabled={step === 'checking'}
            label={t(
              step === 'checking'
                ? 'outbox.unknown.checking'
                : 'outbox.unknown.check',
            )}
            onPress={() => {
              setStep('checking');
              void (async () => {
                if (!(await outbox.check(id))) {
                  setStep((current) =>
                    current === 'checking' ? 'unconfirmed' : current,
                  );
                }
              })();
            }}
          />
          <Action
            label={t('outbox.edit')}
            onPress={() => {
              setStep('confirming');
            }}
          />
        </View>
      )}
    </View>
  );
}

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
  const returning = entry.state === 'waiting' ? 'undo' : 'edit';
  const edit = () => {
    void (async () => {
      const id = await outbox.undo(entry.id);
      if (id !== false) {
        await onOpen(id);
      }
    })();
  };
  return (
    <View style={[styles.row, { backgroundColor: colors.surfaceSidebar }]}>
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
          style={[styles.subject, { color: colors.textPrimary }]}>
          {subject}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.detail, { color: colors.textSecondary }]}>
          {recipients}
        </Text>
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.detail, { color: colors.textSecondary }]}>
          {status}
        </Text>
      </View>
      {entry.state === 'sending' || entry.state === 'unknown' ? null : (
        <Action
          label={t(`outbox.${returning}`)}
          onPress={edit}
        />
      )}
      {entry.state === 'unknown' ? (
        <UnknownRecovery
          id={entry.id}
          onEdit={edit}
        />
      ) : null}
    </View>
  );
}

export function OutboxHeading() {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Text
      accessibilityRole="header"
      style={[styles.section, { color: colors.textSecondary }]}>
      {t('outbox.heading')}
    </Text>
  );
}
