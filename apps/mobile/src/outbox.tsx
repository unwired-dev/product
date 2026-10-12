import type { Translate } from '@private-email/localization';
import type {
  DeliveryProblem,
  OutboxEntry,
} from '@private-email/mail-core/drafts';
import type { MailProvider } from '@private-email/mail-core/registration';

import { draftSummary } from '@private-email/mail-core/drafts';
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

// The provider whose words a row uses; 'unlisted' when its connection is no longer listed.
type CopyProvider = MailProvider | 'unlisted';

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
  'sent-folder': 'outbox.failed.sent-folder',
} as const satisfies Readonly<Record<DeliveryProblem, string>>;
// The same reasons in each provider's words: the copy above names Gmail, and an IMAP connection's
// mail server or Microsoft send other messages. A message whose connection is no longer listed,
// as after its removal, names no provider.
const providerProblems = {
  gmail: problems,
  imap: {
    ...problems,
    offline: 'outbox.queued.offline_imap',
    authorization: 'outbox.failed.authorization_imap',
    'too-large': 'outbox.failed.too-large_imap',
    refused: 'outbox.failed.refused_imap',
  },
  'microsoft-graph': {
    ...problems,
    offline: 'outbox.queued.offline_microsoft',
    'rate-limited': 'outbox.queued.rate-limited_microsoft',
    authorization: 'outbox.failed.authorization_microsoft',
    'too-large': 'outbox.failed.too-large_microsoft',
    refused: 'outbox.failed.refused_microsoft',
  },
  unlisted: {
    ...problems,
    offline: 'outbox.queued.offline_unlisted',
    'rate-limited': 'outbox.queued.rate-limited_unlisted',
    authorization: 'outbox.failed.authorization_unlisted',
    'too-large': 'outbox.failed.too-large_unlisted',
    refused: 'outbox.failed.refused_unlisted',
  },
} as const satisfies Readonly<
  Record<CopyProvider, Readonly<Record<DeliveryProblem, string>>>
>;
// The unknown-outcome copy's own words for each provider.
const unknownCopy = {
  gmail: '',
  imap: '_imap',
  'microsoft-graph': '_microsoft',
  unlisted: '_unlisted',
} as const satisfies Readonly<Record<CopyProvider, string>>;
// Why an accepted message's Sent copy still waits.
const filing: Readonly<
  Partial<
    Record<
      DeliveryProblem,
      `outbox.filing.${'offline' | 'locked' | 'authorization' | 'sent-folder'}`
    >
  >
> = {
  offline: 'outbox.filing.offline',
  locked: 'outbox.filing.locked',
  authorization: 'outbox.filing.authorization',
  'sent-folder': 'outbox.filing.sent-folder',
};

// Where a message stands, in words: waiting out Undo Send, waiting to send and why, sending,
// sent with its Sent copy pending and why, refused and why, or handed off without a confirmed
// outcome.
const statusOf = (
  t: Translate,
  { state, problem }: OutboxEntry,
  provider: CopyProvider,
) => {
  if (state === 'filing') {
    return t(
      (problem === undefined ? undefined : filing[problem]) ??
        'outbox.state.filing',
    );
  }
  if ((state === 'queued' || state === 'failed') && problem !== undefined) {
    return t(providerProblems[provider][problem]);
  }
  if (state === 'failed') {
    return t(providerProblems[provider].refused);
  }
  if (state === 'unknown') {
    return t(`outbox.state.unknown${unknownCopy[provider]}`);
  }
  return t(`outbox.state.${state === 'queued' ? 'sending' : state}`);
};

// The way out of an unknown outcome: check the Sent mailbox again, or, after a warning that the
// provider may already have sent it, return the message to the Drafts to send again deliberately.
function UnknownRecovery({
  id,
  provider,
  onEdit,
}: {
  readonly id: string;
  // The provider the message was handed to.
  readonly provider: CopyProvider;
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
      ? t(`outbox.unknown.${step}${unknownCopy[provider]}`)
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
  const provider =
    use(AccountContext)?.mailboxes.find(
      ({ id }) => id === entry.draft.connection,
    )?.provider ?? 'unlisted';
  const status = statusOf(t, entry, provider);
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
          id={entry.id}
          provider={provider}
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
