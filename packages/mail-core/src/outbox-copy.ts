import type { Translate } from '@private-email/localization';

import type { DeliveryProblem, OutboxEntry } from './draft-model.ts';
import type { MailProvider } from './registration-snapshot.ts';

// The answer to the person's last Check Again of an unknown message: none, still looking, or its
// Sent mailbox did not confirm it.
export type OutboxCheck = 'idle' | 'checking' | 'unconfirmed';

// An Outbox entry as hosts read it.
export type OutboxSnapshotEntry = OutboxEntry &
  Readonly<{ check: OutboxCheck }>;

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
  if (state === 'queued') {
    return t(
      problem === undefined
        ? 'outbox.state.sending'
        : providerProblems[provider][problem],
    );
  }
  if (state === 'failed') {
    return t(providerProblems[provider][problem ?? 'refused']);
  }
  if (state === 'unknown') {
    return t(`outbox.state.unknown${unknownCopy[provider]}`);
  }
  return t(`outbox.state.${state}`);
};

// An entry's words in the provider it was handed to, undefined once its connection is no longer
// listed: its status, the notice after Check Again found no confirmation, and the warning before
// editing an unknown message, which the provider may already have sent.
export function outboxCopy(
  t: Translate,
  entry: OutboxSnapshotEntry,
  provider: CopyProvider = 'unlisted',
) {
  return {
    status: statusOf(t, entry, provider),
    unconfirmed:
      entry.check === 'unconfirmed'
        ? t(`outbox.unknown.unconfirmed${unknownCopy[provider]}`)
        : undefined,
    editWarning: t(`outbox.unknown.confirming${unknownCopy[provider]}`),
  };
}
