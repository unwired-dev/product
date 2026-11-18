import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { ReactNode } from 'react';

import {
  Button as SwiftUIButton,
  Host,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  disabled as inactive,
  font,
  foregroundStyle,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { draftSummary } from '@private-email/mail-core/drafts';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { use, useEffect, useRef, useState } from 'react';
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

const phone = Platform.OS === 'ios' && !Platform.isPad;

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
  // The iPhone frames leave 8pt above a row's capsules.
  recovery: { flexBasis: '100%', gap: phone ? spacing.s : 4 },
  // Long labels, such as German ones, wrap the iPhone capsules onto another line.
  actions: {
    flexDirection: 'row',
    flexWrap: phone ? 'wrap' : 'nowrap',
    gap: spacing.s,
  },
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
    readonly state: OutboxSnapshotEntry['state'];
    readonly message: string;
    readonly open: boolean;
  }>();
  const current = entries.find(({ id }) => id === refused?.id);
  // Each Outbox action supersedes a refusal still on its way from an earlier one.
  const action = useRef(0);
  const dismiss = () => {
    action.current += 1;
    setRefused((toast) => toast && { ...toast, open: false });
  };
  // A refusal speaks for the message as it was. Once that changes it retires rather than hides, so
  // an unknown outcome after sending cannot offer Try Again without the Edit Anyway warning.
  if (refused?.open === true && current?.state !== refused.state) {
    setRefused({ ...refused, open: false });
  }
  const returnToDrafts = (entry: OutboxSnapshotEntry) => {
    dismiss();
    const started = action.current;
    void (async () => {
      const id = await outbox.undo(entry.id);
      if (id !== false) {
        await onOpen(id);
        return;
      }
      const now = outbox.getSnapshot().find((each) => each.id === entry.id);
      // Not when another press or action came since, or its sending began.
      if (started === action.current && now !== undefined && returnable(now)) {
        // The iPhone's narrow toast leaves out the subject.
        const message =
          Platform.OS === 'ios' && Platform.isPad
            ? t('outbox.refused', {
                subject: draftSummary(t, entry.draft).subject,
              })
            : t('outbox.refusedShort');
        setRefused({ id: entry.id, state: now.state, message, open: true });
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
        open={refused.open}
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

function RowActions({ children }: { readonly children: ReactNode }) {
  return <View style={styles.actions}>{children}</View>;
}

function RowAction({
  label,
  onPress,
  disabled = false,
  destructive = false,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
}) {
  const colors = usePalette();
  if (!phone) {
    return (
      <Action
        variant="composer"
        destructive={destructive}
        disabled={disabled}
        label={label}
        onPress={onPress}
      />
    );
  }
  // The iPhone frames draw a row's controls as quiet capsules; iPad keeps text actions until its
  // frames draw them otherwise.
  return (
    <Host matchContents>
      <SwiftUIButton
        role={destructive ? 'destructive' : 'default'}
        onPress={onPress}
        modifiers={[
          buttonStyle('bordered'),
          buttonBorderShape('capsule'),
          controlSize('large'),
          tint(colors.textPrimary),
          inactive(disabled),
        ]}>
        <SwiftUIText
          modifiers={[
            font({ textStyle: 'subheadline', weight: 'semibold' }),
            ...(destructive ? [foregroundStyle(colors.statusDestructive)] : []),
          ]}>
          {label}
        </SwiftUIText>
      </SwiftUIButton>
    </Host>
  );
}

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
        <RowActions>
          <RowAction
            label={t('outbox.unknown.cancel')}
            onPress={() => {
              actions.dismiss();
              setConfirming(false);
            }}
          />
          <RowAction
            destructive
            label={t('outbox.unknown.editAnyway')}
            onPress={() => {
              actions.returnToDrafts(entry);
            }}
          />
        </RowActions>
      ) : (
        <RowActions>
          <RowAction
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
          <RowAction
            label={t('outbox.edit')}
            onPress={() => {
              actions.dismiss();
              setConfirming(true);
              AccessibilityInfo.announceForAccessibility(editWarning);
            }}
          />
        </RowActions>
      )}
    </View>
  );
}

// Undo or Edit sits beside the row's words on iPad and on a line of its own under them on iPhone.
function ReturnAction({ children }: { readonly children: ReactNode }) {
  return phone ? (
    <View style={styles.recovery}>
      <RowActions>{children}</RowActions>
    </View>
  ) : (
    children
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
        <ReturnAction>
          <RowAction
            label={t(`outbox.${returning}`)}
            onPress={edit}
          />
        </ReturnAction>
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
