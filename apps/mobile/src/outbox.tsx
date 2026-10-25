import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';

import { draftSummary } from '@private-email/mail-core/drafts';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { use, useEffect, useState } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import { SFSymbol, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useOutbox, useOutboxEntries } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
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
  toast: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingHorizontal: spacing.l,
    paddingVertical: 10,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  toastMessage: { ...typography.macos.body, flexShrink: 1 },
  // The 44pt target extends 4pt above and below the 36pt toast.
  toastAction: { minHeight: 44, marginVertical: -14, justifyContent: 'center' },
  toastActionLabel: { ...typography.macos.bodyEmphasized },
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

// The deep graphite toast saying storage refused to return a message to the Drafts. It stays until
// Try Again or the next Outbox action, and while the message can still return.
function RefusedToast({
  open,
  message,
  onTryAgain,
}: {
  readonly open: boolean;
  readonly message: string;
  readonly onTryAgain: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const motion = useMenuMotion(open, 'menu');
  if (!motion.shown) {
    return null;
  }
  return (
    <Animated.View
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      style={[
        styles.toast,
        { backgroundColor: colors.brandDeep, boxShadow: colors.toastShadow },
        motion.style,
      ]}>
      <SFSymbol
        name="exclamationmark.triangle.fill"
        color={colors.brandOnDeep}
      />
      <Text style={[styles.toastMessage, { color: colors.brandOnDeep }]}>
        {message}
      </Text>
      <Pressable
        accessibilityRole="button"
        onPress={onTryAgain}
        style={styles.toastAction}>
        <Text style={[styles.toastActionLabel, { color: colors.brandOnDeep }]}>
          {t('outbox.tryAgain')}
        </Text>
      </Pressable>
    </Animated.View>
  );
}

// Whether a message is still in the Outbox and not yet handed to its provider.
const returnable = (entry: OutboxSnapshotEntry | undefined) =>
  entry !== undefined && entry.state !== 'sending' && entry.state !== 'filing';

// Undo, Edit and Check Again for one window's Outbox rows, with their outcomes: a refused return to
// the Drafts shows the toast, announced at once, and a Check Again that finds the message in Sent is
// heard, queued. A message that leaves the Outbox on its own goes silently.
export function useOutboxActions(onOpen: (id: string) => Promise<void>) {
  const outbox = useOutbox();
  const entries = useOutboxEntries();
  const { t } = useLocalization();
  // The words outlast the toast so it can fade out.
  const [refused, setRefused] = useState<{
    readonly id: string;
    readonly message: string;
    readonly open: boolean;
  }>();
  const current = entries.find(({ id }) => id === refused?.id);
  const dismiss = () => {
    setRefused((toast) => toast && { ...toast, open: false });
  };
  const returnToDrafts = (entry: OutboxSnapshotEntry) => {
    dismiss();
    void (async () => {
      const id = await outbox.undo(entry.id);
      if (id !== false) {
        await onOpen(id);
      } else if (
        // Not when another press already returned it or its sending began.
        returnable(outbox.getSnapshot().find((each) => each.id === entry.id))
      ) {
        // The iPhone's narrow toast leaves out the subject.
        const message =
          Platform.OS === 'ios' && Platform.isPad
            ? t('outbox.refused', {
                subject: draftSummary(t, entry.draft).subject,
              })
            : t('outbox.refusedShort');
        setRefused({ id: entry.id, message, open: true });
        AccessibilityInfo.announceForAccessibility(message);
      }
    })();
  };
  const check = (entry: OutboxSnapshotEntry) => {
    dismiss();
    void (async () => {
      if (await outbox.check(entry.id)) {
        AccessibilityInfo.announceForAccessibilityWithOptions(
          t('outbox.inSent', { subject: draftSummary(t, entry.draft).subject }),
          { queue: true },
        );
      }
    })();
  };
  const toast =
    refused === undefined ? null : (
      <RefusedToast
        message={refused.message}
        open={refused.open && returnable(current)}
        onTryAgain={() => {
          if (current !== undefined) {
            returnToDrafts(current);
          }
        }}
      />
    );
  return { toast, actions: { returnToDrafts, check, dismiss } };
}

export type OutboxActions = ReturnType<typeof useOutboxActions>['actions'];

// The way out of an unknown outcome: check the Sent mailbox again, or, after a warning that the
// provider may already have sent it, return the message to the Drafts to send again deliberately.
function UnknownRecovery({
  entry,
  unconfirmed,
  editWarning,
  actions,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly unconfirmed: string | undefined;
  readonly editWarning: string;
  readonly actions: OutboxActions;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // Only the window that opened it asks before editing.
  const [confirming, setConfirming] = useState(false);
  const notice = confirming ? editWarning : unconfirmed;
  useAnnouncement(`${sendOf(entry)}:check`, unconfirmed);
  return (
    <View style={styles.recovery}>
      {notice === undefined ? null : (
        <Text style={[styles.detail, { color: colors.textSecondary }]}>
          {notice}
        </Text>
      )}
      {confirming ? (
        <View style={styles.actions}>
          <Action
            variant="composer"
            label={t('outbox.unknown.cancel')}
            onPress={() => {
              actions.dismiss();
              setConfirming(false);
            }}
          />
          <Action
            variant="composer"
            destructive
            label={t('outbox.unknown.editAnyway')}
            onPress={() => {
              actions.returnToDrafts(entry);
            }}
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
              actions.check(entry);
            }}
          />
          <Action
            variant="composer"
            label={t('outbox.edit')}
            onPress={() => {
              actions.dismiss();
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
  actions,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly actions: OutboxActions;
}) {
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
    actions.returnToDrafts(entry);
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
          actions={actions}
          editWarning={editWarning}
          entry={entry}
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
    <Text
      accessibilityRole="header"
      style={[styles.section, { color: colors.textSecondary }]}>
      {t('outbox.heading')}
    </Text>
  );
}
