import type { Translate } from '@private-email/localization';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';

import { draftSummary, profileDrafts } from '@private-email/mail-core/drafts';
import { invitationChoiceKeys } from '@private-email/mail-core/invitations';
import { outboxCopy } from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import { Button, MenuPresence, SFSymbol } from './design.tsx';
import { useLocalization, useMessageListDateFormats } from './localization.ts';
import { useOutbox, useOutboxEntries, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

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
  subject: { ...textStyles.body },
  detail: { ...textStyles.body },
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
  toastMessage: { flexShrink: 1 },
  // A 28pt target around the 16pt label, inside the toast's own height.
  toastAction: {
    minHeight: 28,
    marginVertical: -6,
    justifyContent: 'center',
    outlineWidth: 2,
    borderRadius: radius.control,
  },
  toastActionLabel: { ...textStyles.bodyEmphasized },
  response: {
    gap: 2,
    paddingTop: 10,
    paddingBottom: 12,
    paddingHorizontal: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  responseHeading: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  responseTitle: { ...textStyles.bodyEmphasized, flex: 1 },
  responseActions: { flexDirection: 'row', gap: spacing.s, paddingTop: 4 },
});

// What a row names: a message's subject and recipients, or the meeting an Invitation Response
// answers and the choice it carries.
const summaryOf = (t: Translate, { draft, invitation }: OutboxSnapshotEntry) =>
  invitation === undefined
    ? draftSummary(t, draft)
    : {
        subject: invitation.summary ?? t('invitation.untitled'),
        recipients: t('outbox.invitation.response', {
          choice: t(`invitation.${invitationChoiceKeys[invitation.choice]}`),
        }),
      };

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

// VoiceOver hears where each of the window's Outbox messages stands, and each answer to Check Again
// that leaves delivery unknown, whichever list the window shows. A message sent again after Undo
// has a new deadline, so its words are heard again.
export function useOutboxAnnouncements(
  entries: readonly OutboxSnapshotEntry[],
) {
  const { t } = useLocalization();
  const mailboxes = use(AccountContext)?.mailboxes;
  useEffect(() => {
    for (const entry of entries) {
      const { subject, recipients } = summaryOf(t, entry);
      const { status, unconfirmed } = outboxCopy(
        t,
        entry,
        mailboxes?.find(({ id }) => id === entry.draft.connection)?.provider,
      );
      announce(
        sendOf(entry),
        status,
        t('outbox.rowLabel', { subject, recipients, status }),
      );
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
  const [focused, setFocused] = useState(false);
  return (
    <MenuPresence
      open={open}
      origin="bottom"
      style={[
        styles.toast,
        { backgroundColor: colors.brandDeep, boxShadow: colors.toastShadow },
      ]}>
      {/* React Native's legacy view interop mounts a nested native view without its offset,
          so the symbol sits in a plain view inside the toast's padding. */}
      <View collapsable={false}>
        <SFSymbol
          name="exclamationmark.triangle.fill"
          color={colors.brandOnDeep}
        />
      </View>
      <View
        accessible
        accessibilityLabel={message}
        style={styles.toastMessage}>
        <Text style={[textStyles.body, { color: colors.brandOnDeep }]}>
          {message}
        </Text>
      </View>
      <Pressable
        accessibilityLabel={t('outbox.tryAgain')}
        accessibilityRole="button"
        enableFocusRing={false}
        focusable
        onBlur={() => {
          setFocused(false);
        }}
        onFocus={() => {
          setFocused(true);
        }}
        onPress={onTryAgain}
        style={[
          styles.toastAction,
          { outlineColor: focused ? colors.brandOnDeep : 'transparent' },
        ]}>
        <Text style={[styles.toastActionLabel, { color: colors.brandOnDeep }]}>
          {t('outbox.tryAgain')}
        </Text>
      </Pressable>
    </MenuPresence>
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
        const message = t('outbox.refused', {
          subject: draftSummary(t, entry.draft).subject,
        });
        setRefused({ id: entry.id, state: now.state, message, open: true });
        AccessibilityInfo.announceForAccessibility(message);
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

// Where an Invitation Response stands, as its row's symbol shows it.
const responseSymbols = {
  waiting: ['clock', 'textSecondary'],
  queued: ['clock', 'textSecondary'],
  sending: ['clock', 'textSecondary'],
  filing: ['clock', 'textSecondary'],
  failed: ['exclamationmark.triangle.fill', 'statusDestructive'],
  unknown: ['info.circle', 'statusWarning'],
} as const satisfies Record<OutboxSnapshotEntry['state'], readonly string[]>;

// An Invitation Response's row: the meeting, the choice and where it stands, with Undo while it
// waits, Check Again when its delivery is unknown, and Open Invitation. It has no Edit, since it
// was never a Draft.
function ResponseRow({
  entry,
  actions,
  onOpenInvitation,
}: {
  readonly entry: OutboxSnapshotEntry;
  readonly actions: OutboxActions;
  readonly onOpenInvitation: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const formats = useMessageListDateFormats();
  const { subject, recipients } = summaryOf(t, entry);
  const { status, unconfirmed } = outboxCopy(t, entry, 'imap');
  const [symbol, tone] = responseSymbols[entry.state];
  const time = formats.time.format(entry.draft.updatedAt);
  return (
    <View style={[styles.response, { borderBottomColor: colors.separator }]}>
      <View
        accessible
        accessibilityLabel={t('outbox.rowLabel', {
          subject,
          recipients,
          status,
        })}
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
            style={{ width: 16, height: 16 }}
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
            {time}
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
      <View style={styles.responseActions}>
        {entry.state === 'waiting' ? (
          <Button
            label={t('outbox.undo')}
            onPress={() => {
              actions.undoResponse(entry);
            }}
          />
        ) : null}
        {entry.state === 'unknown' ? (
          <Button
            label={t(
              entry.check === 'checking'
                ? 'outbox.unknown.checking'
                : 'outbox.unknown.check',
            )}
            disabled={entry.check === 'checking'}
            onPress={() => {
              actions.check(entry);
            }}
          />
        ) : null}
        {onOpenInvitation === undefined ? null : (
          <Button
            label={t('outbox.invitation.open')}
            onPress={onOpenInvitation}
          />
        )}
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
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === entry.draft.connection,
  )?.provider;
  if (entry.invitation !== undefined) {
    return (
      <ResponseRow
        entry={entry}
        actions={actions}
        onOpenInvitation={onOpenInvitation}
      />
    );
  }
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

// The window's Mail Profile's Outbox, oldest Send first.
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

// A window list's Outbox view: its Mail Profile's Outbox while the person chose it, it holds a
// message and no search lists mail instead. VoiceOver hears the Outbox whichever list the window
// shows, and the Outbox row leaves the sidebar with its last message, emptying the view.
export function useOutboxView({
  chosen,
  onEmptied,
  canCompose,
  searching,
}: Readonly<{
  chosen: boolean;
  onEmptied: () => void;
  // A window that cannot compose lists no Outbox.
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
