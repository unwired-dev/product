import type { Translate } from '@private-email/localization';
import type { GmailInbox } from '@private-email/mail-core/inbox-store';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  SentUnsubscribeRequest,
  Unsubscribe,
  UnsubscribeOffer,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';

import { imapPresetOf } from '@private-email/mail-core/imap-setup';
import {
  pendingUnsubscribe,
  undoSendWindow,
  unsendable,
} from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { unsubscribeOf } from '@private-email/mail-core/unsubscribe';
import {
  createContext,
  use,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react';
import { StyleSheet, View } from 'react-native';

import type { PopUpItem } from './composer-controls.tsx';

import { useBlockSender } from './block-sender.ts';
import { Button, Popover, Toast } from './design.tsx';
import { useReaderToast } from './inbox-bar.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import {
  useMailbox,
  useOutbox,
  useOutboxEntries,
  useProfile,
  useReloadMailboxes,
} from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { unsubscribe } from './registration.ts';
import { textStyles, usePalette } from './theme.ts';

export const UnsubscribeContext = createContext<Unsubscribe>(unsubscribe);

// The Mac Unsubscribe frames: a 12pt banner with 4pt between its lines and 8pt between buttons,
// and the confirmation popover's 20pt inset and 10pt rhythm.
const styles = StyleSheet.create({
  // The reader's 16pt gap is 12pt above and below the banner in the frames.
  banner: {
    marginVertical: -spacing.xs,
    gap: spacing.xs,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  marker: { ...textStyles.caption1Emphasized },
  summary: { ...textStyles.body },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  panel: { width: 340, gap: 10, padding: 20 },
  buttons: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
    paddingTop: 6,
  },
});

// One message's Unsubscribe: whether its stored request was looked up, whether a request is under
// way, how the last one ended, with when a sent one was sent, and the Outbox identifiers of its
// `mailto:` requests. It lives outside the reader, keyed by Product Account, Mail Profile,
// connection and message, so a result arriving after the reader moved on changes only the message
// it was sent from.
type Entry = Readonly<{
  checked?: boolean;
  // The latest stored-request lookup; only its answer counts.
  lookup?: number;
  sending?: boolean;
  outcome?: Outcome;
  requests?: readonly string[];
}>;
// A sent outcome names `to` only when a `mailto:` request was emailed there.
type Outcome =
  | Readonly<{ kind: 'sent'; at: number; to?: string }>
  | Readonly<{ kind: Exclude<UnsubscribeOutcome, 'sent'> }>
  | undefined;
const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
const nothing: Entry = {};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const update = (key: string, change: (entry: Entry) => Entry) => {
  entries.set(key, change(entries.get(key) ?? nothing));
  for (const listener of listeners) {
    listener();
  }
};

// A new number for each confirmation opening, so a late close of the last popover cannot close it,
// and for each lookup, so an earlier lookup's late answer is ignored.
let counted = 0;
const next = () => {
  counted += 1;
  return counted;
};

// The opened message's store; one without bodies, such as the preview fixture, offers nothing.
type Source = Pick<GmailInbox, 'subscribe'> &
  Partial<Pick<GmailInbox, 'responseSource'>>;

// Whether the provider refused the request until the receiving connection signs in again. A
// connection that needs authorization has no open Inbox, so the reader only learns it this way.
const needsSignIn = (pending: OutboxSnapshotEntry | undefined) =>
  pending?.state === 'failed' && pending.problem === 'authorization';

// Where the message's `mailto:` request stands while the Outbox holds it, as the banner shows it.
const pendingOf = (pending: OutboxSnapshotEntry) => {
  const to = pending.draft.to[0]?.address ?? '';
  if (pending.state === 'waiting') {
    return { kind: 'waiting', sendAt: pending.sendAt, to } as const;
  }
  if (pending.state === 'failed' || pending.state === 'unknown') {
    return {
      kind: pending.state === 'failed' ? 'failed' : 'uncertain',
    } as const;
  }
  return { kind: 'queued', to } as const;
};

// Admits the `mailto:` request from `connection` in place of the message `key` names' last one; the
// Outbox sends a refused or unknown request it holds again in place of `offer`, and answers with
// one of the message's requests confirmed meanwhile. A connection that
// cannot send says why in place of an outcome.
const email = async ({
  outbox,
  key,
  connection,
  epoch,
  message,
  receivedAt,
  offer,
}: Readonly<{
  outbox: ReturnType<typeof useOutbox>;
  key: string;
  connection: string;
  // The connection's incarnation the request was confirmed for.
  epoch: string;
  // The message that offered the request, and when it arrived.
  message: string;
  receivedAt: number | undefined;
  offer: Extract<UnsubscribeOffer, { kind: 'mailto' }>;
}>) => {
  const admitted = await outbox
    .unsubscribe(connection, offer, {
      message,
      retrying: entries.get(key)?.requests,
      epoch,
      receivedAt,
    })
    .catch(() => ({ kind: 'failed' }) as const);
  update(key, (each) => ({
    ...each,
    sending: false,
    outcome: admitted.kind === 'failed' ? { kind: 'failed' } : undefined,
    ...(admitted.kind === 'waiting'
      ? { requests: [...(each.requests ?? []), admitted.id] }
      : {}),
  }));
};

// Sends the one-click `offer` for `profile` in place of the message `key` names' last request, and
// records how it ended, dated when it was sent.
const click = async (
  store: Unsubscribe,
  { key, profile }: Readonly<{ key: string; profile: string }>,
  offer: Exclude<UnsubscribeOffer, { kind: 'mailto' }>,
) => {
  let at = Date.now();
  const answered = await store
    .request(profile, offer, () => {
      at = Date.now();
      return at;
    })
    .catch((): UnsubscribeOutcome => 'uncertain');
  update(key, (each) => ({
    ...each,
    sending: false,
    outcome: answered === 'sent' ? { kind: 'sent', at } : { kind: answered },
  }));
};

// Why the receiving connection cannot send the `mailto:` request: the provider refused the last one
// until sign-in, or the connection receives only or needs authorization.
const blockedOf = (
  offer: UnsubscribeOffer | undefined,
  pending: OutboxSnapshotEntry | undefined,
  receiving: MailboxConnection | undefined,
) => {
  if (needsSignIn(pending)) {
    return 'authorization';
  }
  return offer?.kind === 'mailto' && receiving !== undefined
    ? unsendable(receiving)
    : undefined;
};

// Why the receiving connection cannot send the request; the refused request a repair takes out of
// the Outbox, so the offer returns; and the request waiting out its Undo Send Window, whose toast
// offers Undo whatever the banner says.
const pendingStateOf = (
  offer: UnsubscribeOffer | undefined,
  pending: OutboxSnapshotEntry | undefined,
  receiving: MailboxConnection | undefined,
) => ({
  blocked: blockedOf(offer, pending, receiving),
  refused: needsSignIn(pending) ? pending?.id : undefined,
  waiting: pending?.state === 'waiting' ? pending.id : undefined,
});

// Whether `later` is sent and replaces `current`: anything but a sent outcome, or one that does
// not know the recipient `later` names.
const replaces = (current: Outcome, later: Outcome) =>
  later?.kind === 'sent' &&
  (current?.kind !== 'sent' ||
    (current.to === undefined && later.to !== undefined));

// The banner's outcome: a request the Outbox confirmed or that was recorded as sent, which an older
// attempt still in the Outbox never masks; else the request the Outbox holds; else how the last
// request ended.
const outcomeOf = (
  entry: Entry,
  pending: OutboxSnapshotEntry | undefined,
  confirmed: Outcome,
): ReturnType<typeof pendingOf> | Outcome => {
  if (replaces(entry.outcome, confirmed)) {
    return confirmed;
  }
  if (
    entry.outcome?.kind === 'sent' ||
    pending === undefined ||
    needsSignIn(pending)
  ) {
    return entry.outcome;
  }
  return pendingOf(pending);
};

// A request confirmed sent at `at`, emailed `to` when that is known.
const emailed = (at: number, to: string | undefined): Outcome => ({
  kind: 'sent',
  at,
  ...(to === undefined ? {} : { to }),
});

// The first of the message `key` names' `requests` the Outbox confirmed with its recipient, else a
// request the Outbox confirmed this session from `connection` in `profile` for the message, else
// the first confirmed without one; kept for the session once found.
function useConfirmed(
  key: string,
  requests: readonly string[] | undefined,
  {
    connection,
    ...message
  }: Readonly<{ connection: string; profile: string; message: string }>,
): Outcome {
  const outbox = useOutbox();
  const delivered = (requests ?? []).map(outbox.delivered);
  const found =
    delivered.find((each) => each?.to !== undefined) ??
    outbox.emailedUnsubscribe(connection, message) ??
    delivered.find((each) => each !== undefined);
  const at = found?.at;
  const to = found?.to;
  useEffect(() => {
    if (at !== undefined) {
      update(key, (each) =>
        replaces(each.outcome, emailed(at, to))
          ? { ...each, outcome: emailed(at, to) }
          : each,
      );
    }
  }, [key, at, to]);
  return at === undefined ? undefined : emailed(at, to);
}

// The opened message's offer in the scoped mailbox and Profile, its Unsubscribe state, and why
// the receiving connection cannot send a `mailto:` request, if it cannot. A `mailto:` request shows
// as the Outbox holds it, across relaunches, then as sent once the Outbox confirmed it; one
// confirmed for another message of the list only when this one arrived, at `receivedAt`, within
// the list's 14 days.
function useOffer(inbox: Source, id: string, receivedAt: number | undefined) {
  const store = use(UnsubscribeContext);
  const signedIn = use(AccountContext);
  const account = signedIn?.account;
  const profile = useProfile();
  const mailbox = useMailbox();
  const outbox = useOutbox();
  const queued = useOutboxEntries();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    inbox.responseSource?.(id),
  );
  const offer = useMemo(() => unsubscribeOf(document), [document]);
  const connection = mailbox?.id ?? '';
  const receiving = signedIn?.mailboxes.find((each) => each.id === mailbox?.id);
  // A connection added again is another incarnation, which never takes an earlier one's requests.
  const key = `${account}\n${profile}\n${mailbox?.id}\n${receiving?.epoch}\n${id}`;
  const entry =
    useSyncExternalStore(subscribe, () => entries.get(key)) ?? nothing;
  const pending =
    offer?.kind === 'mailto'
      ? pendingUnsubscribe(queued, connection, {
          ...offer,
          message: id,
          receivedAt,
          delivered: outbox.delivered,
          ...(receiving?.epoch === undefined ? {} : { epoch: receiving.epoch }),
        })
      : undefined;
  const { blocked, refused, waiting } = pendingStateOf(
    offer,
    pending,
    receiving,
  );
  // A request found in the Outbox, as after a relaunch, shows as sent once it is confirmed too.
  const pendingId = pending?.id;
  useEffect(() => {
    if (pendingId !== undefined) {
      update(key, (each) =>
        each.requests?.includes(pendingId) === true
          ? each
          : { ...each, requests: [...(each.requests ?? []), pendingId] },
      );
    }
  }, [key, pendingId]);
  const confirmed = useConfirmed(key, entry.requests, {
    connection,
    profile,
    message: id,
  });
  const outcome = outcomeOf(entry, pending, confirmed);
  const retry = outcome?.kind === 'failed' || outcome?.kind === 'uncertain';
  // Sends the request once; a press before the stored request is known, while one is under way or
  // in the Outbox, or after one was sent sends nothing.
  const send = async (sending: UnsubscribeOffer) => {
    const current = entries.get(key) ?? nothing;
    if (
      current.checked !== true ||
      current.sending === true ||
      current.outcome?.kind === 'sent' ||
      (outcome !== undefined && !retry)
    ) {
      return;
    }
    update(key, (each) => ({ ...each, sending: true }));
    await (sending.kind === 'mailto'
      ? email({
          outbox,
          key,
          connection,
          epoch: receiving?.epoch ?? 'legacy',
          message: id,
          receivedAt,
          offer: sending,
        })
      : click(store, { key, profile }, sending));
  };
  return {
    store,
    profile,
    offer: mailbox === undefined ? undefined : offer,
    address: mailbox?.address,
    connection,
    receiving,
    blocked,
    refused,
    waiting,
    key,
    entry,
    outcome,
    // Whether Unsubscribe… is offered: the stored request was looked up, none is under way or in
    // the Outbox and none has ended, when the banner offers what comes next.
    offered:
      entry.checked === true && entry.sending !== true && outcome === undefined,
    send,
  };
}

// The confirmation for `opening`, from the view it is placed in; Unsubscribe sends the request.
function Confirmation({
  offer,
  sender,
  address,
  opening,
  onClose,
  onConfirm,
}: {
  readonly offer: UnsubscribeOffer;
  readonly sender: string;
  readonly address: string;
  readonly opening: number | undefined;
  readonly onClose: () => void;
  readonly onConfirm: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const title = t('unsubscribe.confirmTitle', { list: offer.list });
  return (
    <Popover
      key={opening}
      below
      title={title}
      shown={opening !== undefined}
      onClose={onClose}>
      <View style={styles.panel}>
        <Label
          accessibilityRole="header"
          style={[textStyles.title3Emphasized, { color: colors.textPrimary }]}>
          {title}
        </Label>
        <Label style={[textStyles.body, { color: colors.textSecondary }]}>
          {offer.kind === 'mailto'
            ? t('unsubscribe.confirmEmail', { to: offer.address, address })
            : t('unsubscribe.confirm', { sender, address })}
        </Label>
        <View style={styles.buttons}>
          <Button
            label={t('common.cancel')}
            isCancel
            onPress={onClose}
          />
          <Button
            label={t('unsubscribe.confirmAction')}
            fill="accent"
            isDefault
            onPress={onConfirm}
          />
        </View>
      </View>
    </Popover>
  );
}

// A confirmation for the message `key` names that opens on request and closes on Cancel,
// Unsubscribe or a click outside; another message does not show it.
function useAsking(key: string) {
  const [asking, setAsking] =
    useState<Readonly<{ key: string; opening: number }>>();
  return {
    asking: asking?.key === key ? asking.opening : undefined,
    ask: () => {
      setAsking({ key, opening: next() });
    },
    close: () => {
      setAsking(undefined);
    },
  };
}

// The More menu's Unsubscribe… for the opened message, with its confirmation, which opens below the
// group of More since the banner may be scrolled out of view. `confirmation` takes the sender's
// name; `receivedAt` is when the message arrived, if it is known yet.
export function useUnsubscribeMenu(
  inbox: Source,
  id: string,
  receivedAt: number | undefined,
) {
  const { t } = useLocalization();
  const { offer, address, blocked, key, offered, send } = useOffer(
    inbox,
    id,
    receivedAt,
  );
  const { asking, ask, close } = useAsking(key);
  if (offer === undefined || address === undefined) {
    return { items: [], confirmation: () => null };
  }
  const items: readonly PopUpItem[] =
    offered && blocked === undefined
      ? [
          {
            key: `${key}\nunsubscribe`,
            title: t('unsubscribe.action'),
            run: ask,
          },
        ]
      : [];
  return {
    items,
    confirmation: (sender: string) => (
      <Confirmation
        offer={offer}
        sender={sender}
        address={address}
        opening={offered ? asking : undefined}
        onClose={close}
        onConfirm={() => {
          close();
          void send(offer);
        }}
      />
    ),
  };
}

// The Undo Send toast of the `mailto:` request waiting in the Outbox as `id`, among the reader's
// toasts; it closes once the request is handed off or undone.
function WaitingToast({ id }: { readonly id: string | undefined }) {
  const { t } = useLocalization();
  const outbox = useOutbox();
  // The toast outlasts the wait so it can fade out.
  const [shown, setShown] = useState(id);
  if (id !== undefined && id !== shown) {
    setShown(id);
  }
  const waiting = useOutboxEntries().some(
    (entry) => entry.id === shown && entry.state === 'waiting',
  );
  const open = waiting && shown === id;
  const toast =
    shown === undefined ? null : (
      <Toast
        open={open}
        symbol="paperplane"
        message={t('unsubscribe.waitingToast')}
        // The approved U3 frame's 348pt toast: a 210pt message and 26pt before Undo.
        messageWidth={220}
        action={t('outbox.undo')}
        onAction={() => {
          void outbox.undo(shown, 'waiting');
        }}
      />
    );
  return useReaderToast(toast, open, shown ?? '');
}

// The whole seconds until `at`, counted down each second while `at` is given; none once it passed.
function useSecondsUntil(at: number | undefined) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (at === undefined) {
      return undefined;
    }
    const tick = () => {
      setNow(Date.now());
    };
    const first = setTimeout(tick, 0);
    const timer = setInterval(tick, 1000);
    return () => {
      clearTimeout(first);
      clearInterval(timer);
    };
  }, [at]);
  // The clock may be a tick old when `at` first arrives; the window is never longer than its own.
  const left = Math.min(at ?? 0, now + undoSendWindow) - now;
  return at === undefined ? 0 : Math.max(0, Math.ceil(left / 1000));
}

// Who asks the receiving connection to sign in again: its provider, an IMAP connection's reviewed
// provider, or its mail server.
const providerOf = (t: Translate, receiving: MailboxConnection | undefined) => {
  if (receiving?.provider !== 'imap') {
    return t(`mailProviders.${receiving?.provider ?? 'gmail'}`);
  }
  const preset =
    receiving.imap === undefined ? 'other' : imapPresetOf(receiving.imap);
  return preset === 'other'
    ? t('invitation.mailServer')
    : t(`imap.providers.${preset}`);
};

// The banner's label and summary: the list until a request starts, then where it stands; a
// connection that cannot send a `mailto:` request says why.
const wordsOf = (
  t: Translate,
  {
    offer,
    outcome,
    blocked,
    sender,
    address,
    receiving,
    seconds,
    date,
  }: Readonly<{
    offer: UnsubscribeOffer;
    outcome: ReturnType<typeof useOffer>['outcome'];
    // Until a waiting request is sent.
    seconds: number;
    blocked: ReturnType<typeof unsendable>;
    sender: string;
    address: string;
    receiving: MailboxConnection | undefined;
    date: (at: number) => string;
  }>,
) => {
  if (outcome?.kind === 'sent') {
    return {
      marker: t('unsubscribe.sent'),
      summary:
        outcome.to === undefined
          ? t('unsubscribe.sentDetail', { sender, date: date(outcome.at) })
          : t('unsubscribe.emailSentDetail', {
              to: outcome.to,
              date: date(outcome.at),
            }),
    };
  }
  if (outcome?.kind === 'waiting' || outcome?.kind === 'queued') {
    const { to } = outcome;
    return {
      marker: t('unsubscribe.waiting'),
      summary:
        // Past its deadline a request waits for the Outbox to hand it off.
        outcome.kind === 'waiting' && seconds > 0
          ? t('unsubscribe.waitingDetail', { count: seconds, to, address })
          : t('unsubscribe.sendingDetail', { to, address }),
    };
  }
  if (outcome !== undefined) {
    return {
      marker: t(`unsubscribe.${outcome.kind}`),
      summary: t(`unsubscribe.${outcome.kind}Detail`, { sender }),
    };
  }
  const { list } = offer;
  if (blocked === 'authorization') {
    return {
      marker: list,
      summary: t('unsubscribe.signInDetail', {
        sender,
        address,
        provider: providerOf(t, receiving),
      }),
    };
  }
  return {
    marker: list,
    summary:
      blocked === 'receive-only'
        ? t('unsubscribe.receiveOnlyDetail', { sender, address })
        : undefined,
  };
};

// Sign In… asks the provider again; an IMAP password and a missing outgoing server are repaired in
// the mailbox's settings, from Mailbox Settings….
function Repair({
  blocked,
  connection,
  refused,
  onRetry,
}: {
  readonly blocked: NonNullable<ReturnType<typeof unsendable>>;
  readonly connection: MailboxConnection | undefined;
  // The request the provider refused until sign-in, which a repair takes out of the Outbox.
  readonly refused: string | undefined;
  // Sends the refused request again.
  readonly onRetry: () => void;
}) {
  const { t } = useLocalization();
  const signedIn = use(AccountContext);
  const reload = useReloadMailboxes();
  const outbox = useOutbox();
  const repaired = async () => {
    if (refused !== undefined) {
      await outbox.undo(refused, 'failed');
    }
  };
  // A provider may refuse sending while its Inbox reads, so only a completed sign-in sends the
  // refused request again rather than taking it back: refused again, it asks again. A cancelled
  // sign-in leaves it as it was.
  const signIn = async (id: string) => {
    try {
      const authorized = await signedIn?.authorizeMailbox(id);
      await reload();
      if (authorized === true && refused !== undefined) {
        onRetry();
      }
    } catch {
      // Cancelled or refused: the banner still says why the request cannot be sent.
    }
  };
  return (
    <Button
      label={t(
        blocked === 'authorization'
          ? 'unsubscribe.signIn'
          : 'unsubscribe.mailboxSettings',
      )}
      onPress={() => {
        if (
          blocked === 'authorization' &&
          connection !== undefined &&
          connection.provider !== 'imap'
        ) {
          void signIn(connection.id);
        } else {
          signedIn?.openAccount('mailboxes');
          void repaired();
        }
      }}
    />
  );
}

// The reader's Unsubscribe banner for a message with an offer: the list and Unsubscribe…, which
// asks before sending, then the request's outcome. A `mailto:` request first waits in the Outbox
// with the Undo Send toast; a receiving connection that cannot send it says why and offers Sign In…
// or Mailbox Settings… instead. Sent is dated and offers nothing more; Failed and uncertain offer
// Try Again, which sends without asking again, and Block Sender…. A request the Profile sent to the
// list in the 14 days before the message arrived shows as sent, and nothing is offered until that
// is known.
export function UnsubscribeBanner({
  inbox,
  id,
  sender,
  receivedAt,
}: {
  readonly inbox: Source;
  readonly id: string;
  // The message's sender, which the outcomes name and Block Sender… blocks.
  readonly sender: Readonly<{ name: string; address: string }>;
  // When the message arrived, in milliseconds since the epoch.
  readonly receivedAt: number;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const {
    store,
    profile,
    offer,
    address,
    connection,
    receiving,
    blocked,
    refused,
    waiting,
    key,
    entry,
    outcome,
    offered,
    send,
  } = useOffer(inbox, id, receivedAt);
  const { asking, ask, close } = useAsking(key);
  const { anchor, items } = useBlockSender();
  const seconds = useSecondsUntil(
    outcome?.kind === 'waiting' ? outcome.sendAt : undefined,
  );
  useEffect(() => {
    if (offer === undefined) {
      return;
    }
    // Each opening looks the stored request up again, and offers nothing until it is known.
    const lookup = next();
    update(key, (each) => ({ ...each, checked: false, lookup }));
    const answered = (request?: SentUnsubscribeRequest) => {
      update(key, (each) =>
        each.lookup === lookup
          ? {
              ...each,
              checked: true,
              // A stored request supersedes a failure cached before it was sent from elsewhere, and
              // a receipt that does not know its recipient.
              ...(request !== undefined &&
              replaces(each.outcome, emailed(request.sentAt, request.to))
                ? { outcome: emailed(request.sentAt, request.to) }
                : {}),
            }
          : each,
      );
    };
    const recall = async () => {
      try {
        answered(await store.sentRequest(profile, offer, receivedAt));
      } catch {
        answered();
      }
    };
    void recall();
  }, [store, profile, offer, receivedAt, key]);
  const day = useMemo(
    () =>
      new Intl.DateTimeFormat(settings.locale, {
        day: 'numeric',
        month: 'short',
        timeZone: settings.timeZone,
      }),
    [settings.locale, settings.timeZone],
  );
  if (offer === undefined || address === undefined) {
    return null;
  }
  const primary = { color: colors.textPrimary };
  const { sending = false } = entry;
  const block = items(sender.address, connection, id).find(
    (item) => 'run' in item,
  );
  const { marker, summary } = wordsOf(t, {
    offer,
    outcome,
    blocked,
    sender: sender.name,
    address,
    receiving,
    seconds,
    date: (at) => day.format(at),
  });
  let actions = null;
  if (outcome === undefined && blocked !== undefined) {
    actions = (
      <Repair
        blocked={blocked}
        connection={receiving}
        refused={refused}
        onRetry={() => {
          void send(offer);
        }}
      />
    );
  } else if (outcome === undefined) {
    actions = (
      <View collapsable={false}>
        <Button
          label={t('unsubscribe.action')}
          disabled={!offered}
          onPress={ask}
        />
        <Confirmation
          offer={offer}
          sender={sender.name}
          address={address}
          opening={offered ? asking : undefined}
          onClose={close}
          onConfirm={() => {
            close();
            void send(offer);
          }}
        />
      </View>
    );
  } else if (outcome.kind === 'failed' || outcome.kind === 'uncertain') {
    actions = (
      <>
        <Button
          label={t('unsubscribe.tryAgain')}
          disabled={sending || entry.checked !== true}
          onPress={() => {
            void send(offer);
          }}
        />
        {block === undefined ? null : (
          <Button
            label={block.title}
            disabled={sending || entry.checked !== true}
            onPress={() => {
              void block.run();
            }}
          />
        )}
      </>
    );
  }
  return (
    <View
      ref={anchor}
      collapsable={false}
      style={[styles.banner, { backgroundColor: colors.fillBanner }]}>
      <Label style={[styles.marker, primary]}>{marker}</Label>
      {summary === undefined ? null : (
        <Label
          accessibilityLiveRegion="polite"
          style={[styles.summary, primary]}>
          {summary}
        </Label>
      )}
      {actions === null ? null : <View style={styles.actions}>{actions}</View>}
      <WaitingToast id={waiting} />
    </View>
  );
}
