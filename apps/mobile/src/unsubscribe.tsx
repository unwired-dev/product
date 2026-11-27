import type { Translate } from '@private-email/localization';
import type { MenuItem } from '@private-email/mail-core/context-menu';
import type { OutboxSnapshotEntry } from '@private-email/mail-core/outbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  SentUnsubscribeRequest,
  Unsubscribe,
  UnsubscribeOffer,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';
import type { ReactNode } from 'react';

import { Alert, Button, Host, Spacer, Text } from '@expo/ui/swift-ui';
import { frame } from '@expo/ui/swift-ui/modifiers';
import { imapPresetOf } from '@private-email/mail-core/imap-setup';
import {
  pendingUnsubscribe,
  undoSendWindow,
  unsendable,
} from '@private-email/mail-core/outbox';
import { unsubscribeOf } from '@private-email/mail-core/unsubscribe';
import {
  createContext,
  use,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  Text as NativeText,
  Platform,
  View,
} from 'react-native';

import { useBlockSender } from './block-sender.tsx';
import { Toast } from './design.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import {
  useInboxActions,
  useMailbox,
  useOutbox,
  useOutboxEntries,
  useProfile,
  useReloadMailboxes,
} from './mailbox.tsx';
import { styles } from './message-body-styles.ts';
import { BannerButton } from './message-body.tsx';
import { AccountContext } from './registration-gate.tsx';
import { unsubscribe } from './registration.ts';
import { usePalette } from './theme.ts';

// SwiftUI sets a capsule's label about 2pt narrower than the frames do, so the capsules gain 1pt
// on each side.
const labelInset = 1;

export const UnsubscribeContext = createContext<Unsubscribe>(unsubscribe);

const compact = Platform.OS === 'ios' && !Platform.isPad;

// One message's Unsubscribe: whether its stored request was looked up, whether the confirmation is
// open, whether a request is under way, how the last one ended, with when a sent one was sent, and
// the Outbox identifiers of its `mailto:` requests. It lives outside the reader, keyed by Product
// Account, Mail Profile, connection and message, so a result arriving after the reader moved on
// changes only the message it was sent from.
type Entry = Readonly<{
  checked?: boolean;
  // The latest stored-request lookup; only its answer counts.
  lookup?: number;
  asking?: boolean;
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
let lookups = 0;
// The messages whose banner is shown now, which alone announce an outcome.
const visible = new Set<string>();

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
// one of the message's requests confirmed meanwhile.
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

// Sends the one-click `offer` for `profile` and records how it ended for the message `key` names,
// dated when it was sent; a Sent request the lookup found meanwhile stays over a failure.
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
  const ended: Outcome =
    answered === 'sent' ? { kind: 'sent', at } : { kind: answered };
  update(key, (each) => ({
    ...each,
    sending: false,
    outcome:
      ended.kind === 'sent' || each.outcome?.kind !== 'sent'
        ? ended
        : each.outcome,
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
// offers Undo.
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

// A request confirmed sent at `at`, emailed `to` when that is known.
const emailed = (at: number, to: string | undefined): Outcome => ({
  kind: 'sent',
  at,
  ...(to === undefined ? {} : { to }),
});

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

// The opened message's offer in the scoped mailbox and Profile, its Unsubscribe state, and why the
// receiving connection cannot send a `mailto:` request, if it cannot. A `mailto:` request shows as
// the Outbox holds it, across relaunches, then as sent once the Outbox confirmed it; one confirmed
// for another message of the list only when this one arrived, at `receivedAt`, within the list's 14
// days. A store without bodies, such as the preview fixture, offers nothing.
function useOffer(id: string, receivedAt: number | undefined) {
  const store = use(UnsubscribeContext);
  const signedIn = use(AccountContext);
  const account = signedIn?.account;
  const profile = useProfile();
  const mailbox = useMailbox();
  const inbox = useInboxActions();
  const outbox = useOutbox();
  const queued = useOutboxEntries();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    'responseSource' in inbox ? inbox.responseSource(id) : undefined,
  );
  // Only the document changes the offer, so a sync's new mailbox snapshot leaves an open
  // confirmation in place.
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
    mailbox,
    receiving,
    ...pendingStateOf(offer, pending, receiving),
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

// The More menu's Unsubscribe… for the opened message, which opens the banner's confirmation. A
// connection that cannot send the `mailto:` request offers it only in the banner, with its repair.
export function useUnsubscribeItems(id: string): readonly MenuItem[] {
  const { t } = useLocalization();
  const { offer, blocked, key, offered } = useOffer(id, undefined);
  return offer === undefined || !offered || blocked !== undefined
    ? []
    : [
        {
          key: `${key}\nunsubscribe`,
          title: t('unsubscribe.action'),
          symbol: 'minus.circle',
          run: () => {
            update(key, (each) => ({ ...each, asking: true }));
          },
        },
      ];
}

// The Undo Send toast of the opened message's `mailto:` request while it waits in the Outbox, for
// the reader to place: 12pt above the iPhone toolbar, or with the window bar's notices on iPad. It
// closes once the request is handed off or undone.
export function useUnsubscribeToast(
  id: string,
  message: Readonly<{ receivedAt: string }> | undefined,
) {
  const receivedAt = message?.receivedAt;
  const { t } = useLocalization();
  const outbox = useOutbox();
  const { waiting } = useOffer(
    id,
    receivedAt === undefined ? undefined : new Date(receivedAt).getTime(),
  );
  // The toast outlasts the wait so it can fade out.
  const [shown, setShown] = useState(waiting);
  if (waiting !== undefined && waiting !== shown) {
    setShown(waiting);
  }
  const open = useOutboxEntries().some(
    (entry) => entry.id === shown && entry.state === 'waiting',
  );
  return shown === undefined ? null : (
    <Toast
      open={open && shown === waiting}
      symbol="paperplane"
      message={t('unsubscribe.waitingToast')}
      action={t('outbox.undo')}
      onAction={() => {
        void outbox.undo(shown, 'waiting');
      }}
    />
  );
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
    blocked: ReturnType<typeof useOffer>['blocked'];
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
  if (blocked === 'authorization') {
    return {
      marker: offer.list,
      summary: t('unsubscribe.signInDetail', {
        sender,
        address,
        provider: providerOf(t, receiving),
      }),
    };
  }
  return {
    marker: offer.list,
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
  readonly blocked: NonNullable<ReturnType<typeof useOffer>['blocked']>;
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
    <BannerButton
      widen={labelInset}
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
          if (refused !== undefined) {
            void outbox.undo(refused, 'failed');
          }
        }
      }}
    />
  );
}

// The banner's buttons for where the request stands: a connection that cannot send offers its
// repair in place of Unsubscribe…, a failed or uncertain request Try Again and Block Sender…, and
// a request under way or sent nothing.
function Actions({
  outcome,
  blocked,
  receiving,
  refused,
  offered,
  busy,
  blocking,
  onAsk,
  onRequest,
}: {
  readonly outcome: ReturnType<typeof useOffer>['outcome'];
  readonly blocked: ReturnType<typeof useOffer>['blocked'];
  readonly receiving: MailboxConnection | undefined;
  readonly refused: string | undefined;
  readonly offered: boolean;
  // A request is under way or the stored request is not known yet.
  readonly busy: boolean;
  readonly blocking:
    | ReturnType<ReturnType<typeof useBlockSender>['items']>[number]
    | undefined;
  readonly onAsk: () => void;
  readonly onRequest: () => void;
}) {
  const { t } = useLocalization();
  let buttons: ReactNode = null;
  if (outcome === undefined && blocked !== undefined) {
    buttons = (
      <Repair
        blocked={blocked}
        connection={receiving}
        refused={refused}
        onRetry={onRequest}
      />
    );
  } else if (outcome === undefined) {
    buttons = (
      <BannerButton
        widen={labelInset}
        label={t('unsubscribe.action')}
        disabled={!offered}
        onPress={onAsk}
      />
    );
  } else if (outcome.kind === 'failed' || outcome.kind === 'uncertain') {
    buttons = (
      <>
        <BannerButton
          widen={labelInset}
          label={t('unsubscribe.tryAgain')}
          disabled={busy}
          onPress={onRequest}
        />
        {blocking === undefined ? null : (
          <BannerButton
            widen={labelInset}
            label={blocking.title}
            disabled={busy}
            onPress={() => {
              blocking.run();
            }}
          />
        )}
      </>
    );
  } else {
    // A request under way or sent offers nothing.
    return null;
  }
  return (
    <View style={ipad ? styles.padBannerActions : styles.bannerActions}>
      {buttons}
    </View>
  );
}

// The system alert that confirms the request for `list` before sending it.
function Confirmation({
  list,
  message,
  onClose,
  onConfirm,
}: {
  readonly list: string;
  readonly message: string;
  readonly onClose: () => void;
  readonly onConfirm: () => void;
}) {
  const { t } = useLocalization();
  return (
    <View style={styles.alertAnchor}>
      <Host matchContents>
        {/* The system alert owns focus and dismissal; Cancel's role makes it the dismissal
            choice, and Unsubscribe is the default. */}
        <Alert
          testID="unsubscribe-confirmation"
          title={t('unsubscribe.confirmTitle', { list })}
          isPresented
          onIsPresentedChange={(presented) => {
            if (!presented) {
              onClose();
            }
          }}>
          {/* SwiftUI drops an alert attached to an empty view, so it anchors on a zero-size spacer. */}
          <Alert.Trigger>
            <Spacer modifiers={[frame({ width: 0, height: 0 })]} />
          </Alert.Trigger>
          <Alert.Actions>
            <Button
              label={t('unsubscribe.confirmAction')}
              onPress={() => {
                onClose();
                onConfirm();
              }}
            />
            <Button
              // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
              role="cancel"
              label={t('common.cancel')}
              onPress={onClose}
            />
          </Alert.Actions>
          <Alert.Message>
            <Text>{message}</Text>
          </Alert.Message>
        </Alert>
      </Host>
    </View>
  );
}

// The reader's Unsubscribe banner, where the device's frames draw it: above the message on iPhone,
// beneath its header on iPad.
export function UnsubscribeBanner({
  message,
  above = false,
}: Parameters<typeof Banner>[0] & { readonly above?: boolean }) {
  return above === compact ? <Banner message={message} /> : null;
}

// The banner for a message with an offer, in the Schedule Banner recipe: the list and
// Unsubscribe…, which asks in the system alert before sending, then the request's outcome. A
// `mailto:` request first waits in the Outbox with the Undo Send toast; a receiving connection that
// cannot send it says why and offers Sign In… or Mailbox Settings… instead. Sent is dated and offers
// nothing more; Failed and uncertain offer Try Again, which sends without asking again, and Block
// Sender…. A request the Profile sent to the list in the 14 days before the message arrived shows as
// sent, and nothing is offered until that is known.
function Banner({
  message,
}: {
  readonly message: Readonly<{
    id: string;
    sender: string;
    address: string;
    receivedAt: string;
  }>;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const receivedAt = new Date(message.receivedAt).getTime();
  const {
    store,
    profile,
    offer,
    mailbox,
    receiving,
    blocked,
    refused,
    key,
    entry,
    outcome,
    offered,
    send,
  } = useOffer(message.id, receivedAt);
  const block = useBlockSender();
  const seconds = useSecondsUntil(
    outcome?.kind === 'waiting' ? outcome.sendAt : undefined,
  );
  useEffect(() => {
    if (offer === undefined) {
      return undefined;
    }
    // Each opening looks the stored request up again, and offers nothing until it is known.
    lookups += 1;
    const lookup = lookups;
    update(key, (each) => ({ ...each, checked: false, lookup }));
    visible.add(key);
    const answered = (request?: SentUnsubscribeRequest) => {
      update(key, (each) =>
        each.lookup === lookup
          ? {
              ...each,
              checked: true,
              // A stored request supersedes a Failed or uncertain one, such as one sent from another
              // message of the list, an older Sent one and one that does not know its recipient.
              ...(request !== undefined &&
              (replaces(each.outcome, emailed(request.sentAt, request.to)) ||
                (each.outcome?.kind === 'sent' &&
                  each.outcome.at < request.sentAt))
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
    // Leaving the message closes its confirmation without acting.
    return () => {
      visible.delete(key);
      update(key, (each) => ({ ...each, asking: false }));
    };
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
  const words =
    offer === undefined || mailbox?.address === undefined
      ? undefined
      : wordsOf(t, {
          offer,
          outcome,
          blocked,
          sender: message.sender,
          address: mailbox.address,
          receiving,
          seconds,
          // A locale whose date ends in a period, such as "26. 11.", ends the sentence with it.
          date: (at) => day.format(at).replace(/\.$/u, ''),
        });
  // VoiceOver hears each new state of a request sent from this banner once, while it shows; the
  // countdown is not announced again each second.
  const sent = useRef(false);
  const marker = words?.marker;
  const spoken = useRef(marker);
  useEffect(() => {
    // A request under way has no new state yet.
    if (entry.sending === true || marker === spoken.current) {
      return;
    }
    spoken.current = marker;
    if (sent.current && visible.has(key) && words !== undefined) {
      AccessibilityInfo.announceForAccessibility(
        words.summary === undefined
          ? words.marker
          : `${words.marker}. ${words.summary}`,
      );
    }
  });
  if (
    offer === undefined ||
    mailbox?.address === undefined ||
    words === undefined
  ) {
    return null;
  }
  const request = () => {
    sent.current = true;
    // A retry that ends as the last one did is still news.
    spoken.current = undefined;
    void send(offer);
  };
  const close = () => {
    update(key, (each) => ({ ...each, asking: false }));
  };
  const actions = (
    <Actions
      outcome={outcome}
      blocked={blocked}
      receiving={receiving}
      refused={refused}
      offered={offered}
      busy={entry.sending === true || entry.checked !== true}
      blocking={block.items(message, mailbox.id, message.id)[0]}
      onAsk={() => {
        update(key, (each) => ({ ...each, asking: true }));
      }}
      onRequest={request}
    />
  );
  return (
    <View
      style={[
        ipad
          ? [styles.padBanner, styles.padUnsubscribeBanner]
          : [styles.banner, styles.unsubscribeBanner],
        { backgroundColor: colors.fillQuiet },
      ]}>
      {/* VoiceOver reads the label, then the summary, as one element before the buttons. */}
      <View accessible>
        <NativeText
          style={[
            ipad
              ? [styles.padBannerTitle, styles.padUnsubscribeTitle]
              : [styles.bannerTitle, styles.unsubscribeTitle],
            { color: colors.textPrimary },
          ]}>
          {words.marker}
        </NativeText>
        {words.summary === undefined ? null : (
          <NativeText
            style={[
              ipad
                ? [styles.padBannerText, styles.padUnsubscribeText]
                : [styles.bannerText, styles.unsubscribeText],
              { color: colors.textSecondary },
            ]}>
            {words.summary}
          </NativeText>
        )}
      </View>
      {actions}
      {entry.asking === true && offered && blocked === undefined ? (
        <Confirmation
          list={offer.list}
          message={
            offer.kind === 'mailto'
              ? t('unsubscribe.confirmEmail', {
                  to: offer.address,
                  address: mailbox.address,
                })
              : t('unsubscribe.confirm', {
                  sender: message.sender,
                  address: mailbox.address,
                })
          }
          onClose={close}
          onConfirm={request}
        />
      ) : null}
      {block.alert}
    </View>
  );
}
