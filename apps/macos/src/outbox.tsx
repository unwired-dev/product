import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';

import { draftSummary } from '@private-email/mail-core/drafts';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useState } from 'react';
import { AccessibilityInfo, StyleSheet, Text, View } from 'react-native';

import { Action } from './action.tsx';
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

// Where each send last stood when announced, and its last Check Again answer, keyed by the send;
// no subject or recipients. VoiceOver hears each change once, however many windows show the row;
// iOS and macOS ignore live regions.
const announced = new Map<string, string>();
const sendOf = ({ id, sendAt }: OutboxSnapshotEntry) => `${id}:${sendAt}`;
function useAnnouncement(
  key: string,
  heard: string | undefined,
  words = heard,
) {
  useEffect(() => {
    if (heard === undefined) {
      announced.delete(key);
    } else if (announced.get(key) !== heard) {
      announced.set(key, heard);
      AccessibilityInfo.announceForAccessibilityWithOptions(words ?? heard, {
        queue: true,
      });
    }
  }, [key, heard, words]);
}

// Forgets sends that have left the Outbox: delivered, undone, or edited after a refusal.
export function forgetRetired(entries: readonly OutboxSnapshotEntry[]) {
  const current = new Set(entries.map(sendOf));
  for (const key of announced.keys()) {
    if (!current.has(key.replace(/:check$/u, ''))) {
      announced.delete(key);
    }
  }
}

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
  useAnnouncement(`${sendOf(entry)}:check`, unconfirmed);
  return (
    <View style={styles.recovery}>
      {notice === undefined ? null : (
        <View
          accessible
          accessibilityLabel={notice}>
          <Text style={[styles.detail, { color: colors.textSecondary }]}>
            {notice}
          </Text>
        </View>
      )}
      {confirming ? (
        <View style={styles.actions}>
          <Action
            variant="composer"
            label={t('outbox.unknown.cancel')}
            onPress={() => {
              setConfirming(false);
            }}
          />
          <Action
            variant="composer"
            destructive
            label={t('outbox.unknown.editAnyway')}
            onPress={onEdit}
          />
        </View>
      ) : (
        <View style={styles.actions}>
          <Action
            variant="composer"
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
            variant="composer"
            label={t('outbox.edit')}
            onPress={() => {
              setConfirming(true);
              AccessibilityInfo.announceForAccessibility(editWarning);
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
  const label = t('outbox.rowLabel', { subject, recipients, status });
  // A message sent again after Undo has a new deadline, so its words are heard again.
  useAnnouncement(sendOf(entry), status, label);
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
        accessibilityLabel={label}
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
        <Text style={[styles.detail, { color: colors.textSecondary }]}>
          {status}
        </Text>
      </View>
      {entry.state === 'sending' ||
      entry.state === 'filing' ||
      entry.state === 'unknown' ? null : (
        <Action
          variant="composer"
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
