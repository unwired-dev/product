import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';

import { draftSummary } from '@private-email/mail-core/drafts';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Action } from './composer.tsx';
import { useLocalization } from './localization.ts';
import { useOutbox } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  section: {
    ...textStyles.bodyEmphasized,
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
  subject: { ...textStyles.body },
  detail: { ...textStyles.body },
  recovery: { flexBasis: '100%', gap: 4 },
  actions: { flexDirection: 'row', gap: spacing.s },
});

// The way out of an unknown outcome: check the Sent mailbox again, or, after a warning that the
// provider may already have sent it, return the message to the Drafts to send again deliberately.
function UnknownRecovery({
  entry,
  unconfirmed,
  editWarning,
  onEdit,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly unconfirmed: string | undefined;
  readonly editWarning: string;
  readonly onEdit: () => void;
}) {
  const outbox = useOutbox();
  const colors = usePalette();
  const { t } = useLocalization();
  // Only the window that opened it asks before editing.
  const [confirming, setConfirming] = useState(false);
  const notice = confirming ? editWarning : unconfirmed;
  return (
    <View style={styles.recovery}>
      {notice === undefined ? null : (
        <View
          accessible
          accessibilityLabel={notice}
          accessibilityLiveRegion="polite">
          <Text style={[styles.detail, { color: colors.textSecondary }]}>
            {notice}
          </Text>
        </View>
      )}
      {confirming ? (
        <View style={styles.actions}>
          <Action
            label={t('outbox.unknown.cancel')}
            onPress={() => {
              setConfirming(false);
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
            disabled={entry.check === 'checking'}
            label={t(
              entry.check === 'checking'
                ? 'outbox.unknown.checking'
                : 'outbox.unknown.check',
            )}
            onPress={() => {
              void outbox.check(entry.id);
            }}
          />
          <Action
            label={t('outbox.edit')}
            onPress={() => {
              setConfirming(true);
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
  readonly entry: OutboxSnapshotEntry;
  readonly onOpen: (id: string) => Promise<void>;
}) {
  const outbox = useOutbox();
  const colors = usePalette();
  const { t } = useLocalization();
  const { subject, recipients } = draftSummary(t, entry.draft);
  const { status, unconfirmed, editWarning } = outboxCopy(
    t,
    entry,
    use(AccountContext)?.mailboxes.find(
      ({ id }) => id === entry.draft.connection,
    )?.provider,
  );
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
      {entry.state === 'sending' ||
      entry.state === 'filing' ||
      entry.state === 'unknown' ? null : (
        <Action
          label={t(`outbox.${returning}`)}
          onPress={edit}
        />
      )}
      {entry.state === 'unknown' ? (
        <UnknownRecovery
          editWarning={editWarning}
          entry={entry}
          onEdit={edit}
          unconfirmed={unconfirmed}
        />
      ) : null}
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
      <Text style={[styles.section, { color: colors.textSecondary }]}>
        {t('outbox.heading')}
      </Text>
    </View>
  );
}
