import type { Translate } from '@private-email/localization';
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
import { draftSummary, profileDrafts } from '@private-email/mail-core/drafts';
import { invitationChoiceKeys } from '@private-email/mail-core/invitations';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Platform,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import { SFSymbol, Toast } from './design.tsx';
import { useLocalization, useMessageDateFormats } from './localization.ts';
import { useOutbox, useOutboxEntries, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

const phone = Platform.OS === 'ios' && !Platform.isPad;

const styles = StyleSheet.create({
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
  responseHeading: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  responseTitle: { ...textStyles.subheadlineEmphasized, flex: 1 },
  // Long labels wrap the capsules onto another line on iPad too.
  responseActions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
});

// Where each send last stood when announced, and its last Check Again answer, keyed by the send;
// no subject or recipients. VoiceOver hears each change once, however many windows show the row;
// iOS and macOS ignore live regions.
const announced = new Map<string, string>();
const sendOf = ({ id, sendAt }: OutboxSnapshotEntry) => `${id}:${sendAt}`;
const announce = (key: string, heard: string | undefined, words = heard) => {
  if (heard === undefined) {
    announced.delete(key);
  } else if (announced.get(key) !== heard) {
    announced.set(key, heard);
    AccessibilityInfo.announceForAccessibilityWithOptions(words ?? heard, {
      queue: true,
    });
  }
};

// An Invitation Response's meeting and choice, which its row shows in place of a subject and
// recipients.
const responseSummary = (
  t: Translate,
  invitation: NonNullable<OutboxSnapshotEntry['invitation']>,
) => ({
  subject: invitation.summary ?? t('invitation.untitled'),
  recipients: t('outbox.invitation.response', {
    choice: t(`invitation.${invitationChoiceKeys[invitation.choice]}`),
  }),
});

// VoiceOver hears where each Outbox message stands, and each answer to Check Again that leaves
// delivery unknown, whichever list shows. A message sent again after Undo has a new deadline, so its
// words are heard again.
function useOutboxAnnouncements(entries: readonly OutboxSnapshotEntry[]) {
  const { t } = useLocalization();
  const mailboxes = use(AccountContext)?.mailboxes;
  useEffect(() => {
    for (const entry of entries) {
      const { invitation } = entry;
      const { status, unconfirmed } = outboxCopy(
        t,
        entry,
        invitation === undefined
          ? mailboxes?.find(({ id }) => id === entry.draft.connection)?.provider
          : 'imap',
      );
      const label =
        invitation === undefined
          ? t('outbox.rowLabel', { ...draftSummary(t, entry.draft), status })
          : t('outbox.rowLabel', {
              ...responseSummary(t, invitation),
              status: unconfirmed ?? status,
            });
      announce(sendOf(entry), status, label);
      announce(`${sendOf(entry)}:check`, unconfirmed);
    }
  }, [entries, t, mailboxes]);
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

// The toast saying storage refused to return a message to the Drafts. It stays until Try Again or
// the next Outbox action, and while the message can still return.
function RefusedToast({
  open,
  message,
  spoken,
  onTryAgain,
}: {
  readonly open: boolean;
  readonly message: string;
  readonly spoken: string;
  readonly onTryAgain: () => void;
}) {
  const { t } = useLocalization();
  return (
    <Toast
      open={open}
      symbol="exclamationmark.triangle.fill"
      message={message}
      messageLabel={spoken}
      action={t('outbox.tryAgain')}
      onAction={onTryAgain}
    />
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
    readonly spoken: string;
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
        // The iPhone's narrow toast leaves out the subject. VoiceOver also hears what happens next.
        const { subject } = draftSummary(t, entry.draft);
        const pad = Platform.OS === 'ios' && Platform.isPad;
        const message = pad
          ? t('outbox.notReturned', { subject })
          : t('outbox.notReturnedShort');
        const spoken = pad
          ? t('outbox.refused', { subject })
          : t('outbox.refusedShort');
        setRefused({
          id: entry.id,
          state: now.state,
          message,
          spoken,
          open: true,
        });
        AccessibilityInfo.announceForAccessibility(spoken);
      }
    })();
  };
  // An Invitation Response, which was never a Draft, only leaves the Outbox.
  const undoResponse = (entry: OutboxSnapshotEntry) => {
    dismiss();
    void outbox.undo(entry.id, 'waiting');
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
        spoken={refused.spoken}
        open={refused.open}
        onTryAgain={() => {
          if (current !== undefined) {
            returnToDrafts(current);
          }
        }}
      />
    );
  return { toast, actions: { returnToDrafts, undoResponse, check, dismiss } };
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
  capsule = phone,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly capsule?: boolean;
}) {
  const colors = usePalette();
  if (!capsule) {
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
  // frames draw them otherwise, as they do for an Invitation Response.
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

// Where an Invitation Response stands, as its row's symbol shows it.
const responseSymbols = {
  waiting: ['clock', 'textSecondary'],
  queued: ['clock', 'textSecondary'],
  sending: ['clock', 'textSecondary'],
  filing: ['clock', 'textSecondary'],
  failed: ['exclamationmark.triangle.fill', 'statusDestructive'],
  unknown: ['info.circle', 'statusWarning'],
} as const satisfies Record<OutboxSnapshotEntry['state'], readonly string[]>;
// A waiting response storage refused to take back.
const undoRefusedSymbol = [
  'exclamationmark.triangle.fill',
  'statusWarning',
] as const;

// An Invitation Response's row: the meeting, the choice and where it stands, with Undo while it
// waits (Try Again once storage refused it), Check Again when its delivery is unknown, and Open Invitation, as capsules under its words
// on iPhone and iPad. It has no Edit, since it was never a Draft.
function ResponseRow({
  entry,
  invitation,
  actions,
  onOpenInvitation,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly invitation: NonNullable<OutboxSnapshotEntry['invitation']>;
  readonly actions: OutboxActions;
  readonly onOpenInvitation: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const formats = useMessageDateFormats();
  const { subject, recipients } = responseSummary(t, invitation);
  const { status, unconfirmed } = outboxCopy(t, entry, 'imap');
  const label = t('outbox.rowLabel', {
    subject,
    recipients,
    status: unconfirmed ?? status,
  });
  const [symbol, tone] =
    entry.undo === 'refused' ? undoRefusedSymbol : responseSymbols[entry.state];
  return (
    <View style={[styles.row, { backgroundColor: colors.surfaceSidebar }]}>
      <View
        accessible
        accessibilityLabel={label}
        style={styles.grow}>
        <View style={styles.responseHeading}>
          <Text
            numberOfLines={1}
            style={[styles.responseTitle, { color: colors.textPrimary }]}>
            {subject}
          </Text>
          <SFSymbol
            name={symbol}
            size={13}
            color={colors[tone]}
          />
          <Text
            style={[
              styles.detail,
              {
                color:
                  entry.state === 'failed'
                    ? colors.statusDestructive
                    : colors.textSecondary,
              },
            ]}>
            {formats.time.format(entry.draft.updatedAt)}
          </Text>
        </View>
        <Text
          numberOfLines={1}
          style={[styles.detail, { color: colors.textPrimary }]}>
          {recipients}
        </Text>
        <Text style={[styles.detail, { color: colors.textSecondary }]}>
          {unconfirmed ?? status}
        </Text>
      </View>
      <View style={styles.recovery}>
        <View style={styles.responseActions}>
          {entry.state === 'waiting' ? (
            <RowAction
              capsule
              label={t(
                entry.undo === 'refused' ? 'outbox.tryAgain' : 'outbox.undo',
              )}
              onPress={() => {
                actions.undoResponse(entry);
              }}
            />
          ) : null}
          {entry.state === 'unknown' ? (
            <RowAction
              capsule
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
          ) : null}
          {onOpenInvitation === undefined ? null : (
            <RowAction
              capsule
              label={t('outbox.invitation.open')}
              onPress={onOpenInvitation}
            />
          )}
        </View>
      </View>
    </View>
  );
}

export function OutboxRow({
  entry,
  actions,
  onOpenInvitation,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly actions: OutboxActions;
  // Opens the invitation an Invitation Response answers.
  readonly onOpenInvitation?: (() => void) | undefined;
}) {
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === entry.draft.connection,
  )?.provider;
  if (entry.invitation !== undefined) {
    return (
      <ResponseRow
        entry={entry}
        invitation={entry.invitation}
        actions={actions}
        onOpenInvitation={onOpenInvitation}
      />
    );
  }
  return (
    <MessageRow
      entry={entry}
      actions={actions}
      provider={provider}
    />
  );
}

// An outgoing message's row: its subject, recipients and where it stands, with Undo or Edit, and
// the way out of an unknown outcome.
function MessageRow({
  entry,
  actions,
  provider,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly actions: OutboxActions;
  readonly provider: Parameters<typeof outboxCopy>[2];
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { subject, recipients } = draftSummary(t, entry.draft);
  const { status, unconfirmed, editWarning } = outboxCopy(t, entry, provider);
  const label = t('outbox.rowLabel', { subject, recipients, status });
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

// The Mail Profile's Outbox, oldest Send first.
export function useProfileOutbox() {
  const outbox = useOutboxEntries();
  const account = use(AccountContext);
  const profile = useProfile();
  return profileDrafts({ drafts: [], outbox, account, profile }).outbox;
}

// The Outbox list's subtitle: how many messages wait, and how many were not sent.
const outboxSubtitle = (
  t: Translate,
  outbox: readonly OutboxSnapshotEntry[],
) => {
  const waiting = t('outbox.waiting', { count: outbox.length });
  const failed = outbox.filter(({ state }) => state === 'failed').length;
  return failed === 0
    ? waiting
    : t('outbox.summary', {
        waiting,
        attention: t('outbox.attention', { count: failed }),
      });
};

const noOutbox: readonly OutboxSnapshotEntry[] = [];

// The message list's Outbox view: the Mail Profile's Outbox while the person chose it, it holds a
// message and no search lists mail instead. VoiceOver hears the Outbox whichever list shows, and
// the Outbox row leaves Mailboxes with its last message, emptying the view.
export function useOutboxView({
  chosen,
  onEmptied,
  canCompose,
  searching,
}: Readonly<{
  chosen: boolean;
  onEmptied: () => void;
  // A list that cannot compose lists no Outbox.
  canCompose: boolean;
  searching: boolean;
}>) {
  const outbox = useProfileOutbox();
  const { t } = useLocalization();
  useOutboxAnnouncements(canCompose ? outbox : noOutbox);
  const empty = outbox.length === 0;
  useEffect(() => {
    if (chosen && empty) {
      onEmptied();
    }
  }, [chosen, empty, onEmptied]);
  return chosen && canCompose && !empty && !searching
    ? {
        entries: outbox,
        title: t('outbox.heading'),
        subtitle: outboxSubtitle(t, outbox),
      }
    : undefined;
}
