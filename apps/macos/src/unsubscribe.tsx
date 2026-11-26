import type { Translate } from '@private-email/localization';
import type { GmailInbox } from '@private-email/mail-core/inbox-store';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  MailtoProgress,
  SentUnsubscribeRequest,
  Unsubscribe,
  UnsubscribeOffer,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';

import { imapPresetOf } from '@private-email/mail-core/imap-setup';
import { undoSendWindow, unsendable } from '@private-email/mail-core/outbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { unsubscribeOf } from '@private-email/mail-core/unsubscribe';
import {
  createContext,
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { StyleSheet, View } from 'react-native';

import type { PopUpItem } from './composer-controls.tsx';

import { useBlockSender } from './block-sender.ts';
import { Button, Popover, Toast } from './design.tsx';
import { ReaderToastContext } from './inbox-bar.tsx';
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
// way, and how the last one ended, with when a sent one was sent; a `mailto:` request waits in the
// Outbox as `id` before it ends. It lives outside the reader,
// keyed by Product Account, Mail Profile, connection and message, so a result arriving after the
// reader moved on changes only the message it was sent from.
type Entry = Readonly<{
  checked?: boolean;
  // The latest stored-request lookup; only its answer counts.
  lookup?: number;
  sending?: boolean;
  outcome?:
    | Readonly<{ kind: 'sent'; at: number }>
    | Readonly<{ kind: 'waiting'; id: string }>
    | Readonly<{ kind: Exclude<UnsubscribeOutcome, 'sent'> }>
    | undefined;
}>;
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

// How a `mailto:` request's progress shows: undone, or a connection that cannot send, returns to
// the offer, which then says why.
const outcomeOf = (progress: MailtoProgress): Entry['outcome'] => {
  if (progress.kind === 'waiting' || progress.kind === 'sent') {
    return progress;
  }
  if (progress.kind === 'failed' || progress.kind === 'uncertain') {
    return { kind: progress.kind };
  }
  return undefined;
};

// The opened message's offer in the scoped mailbox and Profile, its Unsubscribe state, and why
// the receiving connection cannot send a `mailto:` request, if it cannot.
function useOffer(inbox: Source, id: string) {
  const store = use(UnsubscribeContext);
  const signedIn = use(AccountContext);
  const account = signedIn?.account;
  const profile = useProfile();
  const mailbox = useMailbox();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    inbox.responseSource?.(id),
  );
  const offer = useMemo(() => unsubscribeOf(document), [document]);
  const receiving = signedIn?.mailboxes.find((each) => each.id === mailbox?.id);
  const blocked =
    offer?.kind === 'mailto' && receiving !== undefined
      ? unsendable(receiving)
      : undefined;
  const key = `${account}\n${profile}\n${mailbox?.id}\n${id}`;
  const entry =
    useSyncExternalStore(subscribe, () => entries.get(key)) ?? nothing;
  // Sends the request once; a press before the stored request is known, while one is under way,
  // waits in the Outbox, or after one was sent sends nothing.
  const send = async (sending: UnsubscribeOffer) => {
    const current = entries.get(key) ?? nothing;
    if (
      current.checked !== true ||
      current.sending === true ||
      current.outcome?.kind === 'sent' ||
      current.outcome?.kind === 'waiting'
    ) {
      return;
    }
    update(key, (each) => ({ ...each, sending: true }));
    if (sending.kind === 'mailto') {
      // A request the Outbox never admitted sent nothing.
      await store
        .email(
          { profile, connection: mailbox?.id ?? '', offer: sending },
          (progress) => {
            update(key, (each) => ({
              ...each,
              sending: false,
              outcome: outcomeOf(progress),
            }));
          },
        )
        .catch(() => {
          update(key, (each) =>
            each.sending === true
              ? { ...each, sending: false, outcome: { kind: 'failed' } }
              : each,
          );
        });
      return;
    }
    let at = Date.now();
    const outcome = await store
      .request(profile, sending, () => {
        at = Date.now();
        return at;
      })
      .catch((): UnsubscribeOutcome => 'uncertain');
    update(key, (each) => ({
      ...each,
      sending: false,
      outcome: outcome === 'sent' ? { kind: 'sent', at } : { kind: outcome },
    }));
  };
  return {
    store,
    profile,
    offer: mailbox === undefined ? undefined : offer,
    address: mailbox?.address,
    connection: mailbox?.id ?? '',
    receiving,
    blocked,
    key,
    entry,
    send,
  };
}

// Whether Unsubscribe… is offered: the stored request was looked up, none is under way or waiting
// and none has ended, when the banner offers what comes next.
const offered = (entry: Entry) =>
  entry.checked === true &&
  entry.sending !== true &&
  entry.outcome === undefined;

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
// name.
export function useUnsubscribeMenu(inbox: Source, id: string) {
  const { t } = useLocalization();
  const { offer, address, blocked, key, entry, send } = useOffer(inbox, id);
  const { asking, ask, close } = useAsking(key);
  if (offer === undefined || address === undefined) {
    return { items: [], confirmation: () => null };
  }
  const items: readonly PopUpItem[] =
    offered(entry) && blocked === undefined
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
        opening={offered(entry) ? asking : undefined}
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
  const showToast = use(ReaderToastContext);
  // The toast outlasts the wait so it can fade out.
  const [shown, setShown] = useState(id);
  if (id !== undefined && id !== shown) {
    setShown(id);
  }
  const waiting = useOutboxEntries().some(
    (entry) => entry.id === shown && entry.state === 'waiting',
  );
  const toast =
    shown === undefined ? null : (
      <Toast
        open={waiting && shown === id}
        symbol="paperplane"
        message={t('unsubscribe.waitingToast')}
        action={t('outbox.undo')}
        onAction={() => {
          void outbox.undo(shown, 'waiting');
        }}
      />
    );
  // Only a toast this banner showed is cleared, so another reader toast stays.
  const showing = useRef(false);
  useLayoutEffect(() => {
    if (toast !== null) {
      showing.current = true;
      showToast?.(toast);
    }
  });
  useLayoutEffect(
    () => () => {
      if (showing.current) {
        showToast?.(null);
      }
    },
    [showToast],
  );
  return showToast === undefined ? toast : null;
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
    date,
  }: Readonly<{
    offer: UnsubscribeOffer;
    outcome: Entry['outcome'];
    blocked: ReturnType<typeof unsendable>;
    sender: string;
    address: string;
    receiving: MailboxConnection | undefined;
    date: (at: number) => string;
  }>,
) => {
  const to = offer.kind === 'mailto' ? offer.address : '';
  if (outcome?.kind === 'sent') {
    return {
      marker: t('unsubscribe.sent'),
      summary:
        offer.kind === 'mailto'
          ? t('unsubscribe.emailSentDetail', { to, date: date(outcome.at) })
          : t('unsubscribe.sentDetail', { sender, date: date(outcome.at) }),
    };
  }
  if (outcome?.kind === 'waiting') {
    return {
      marker: t('unsubscribe.waiting'),
      summary: t('unsubscribe.waitingDetail', {
        count: undoSendWindow / 1000,
        to,
        address,
      }),
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
        list,
        address,
        provider: providerOf(t, receiving),
      }),
    };
  }
  return {
    marker: list,
    summary:
      blocked === 'receive-only'
        ? t('unsubscribe.receiveOnlyDetail', { list, address })
        : undefined,
  };
};

// Sign In… asks the provider again; an IMAP password and a missing outgoing server are repaired in
// the mailbox's settings, from Mailbox Settings….
function Repair({
  blocked,
  connection,
}: {
  readonly blocked: NonNullable<ReturnType<typeof unsendable>>;
  readonly connection: MailboxConnection | undefined;
}) {
  const { t } = useLocalization();
  const signedIn = use(AccountContext);
  const reload = useReloadMailboxes();
  const signIn = async (id: string) => {
    try {
      await signedIn?.authorizeMailbox(id);
      await reload();
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
    key,
    entry,
    send,
  } = useOffer(inbox, id);
  const { asking, ask, close } = useAsking(key);
  const { anchor, items } = useBlockSender();
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
              ...(request === undefined || each.outcome !== undefined
                ? {}
                : { outcome: { kind: 'sent', at: request.sentAt } }),
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
  const { outcome, sending = false } = entry;
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
    date: (at) => day.format(at),
  });
  let actions = null;
  if (outcome === undefined && blocked !== undefined) {
    actions = (
      <Repair
        blocked={blocked}
        connection={receiving}
      />
    );
  } else if (outcome === undefined) {
    actions = (
      <View collapsable={false}>
        <Button
          label={t('unsubscribe.action')}
          disabled={!offered(entry)}
          onPress={ask}
        />
        <Confirmation
          offer={offer}
          sender={sender.name}
          address={address}
          opening={offered(entry) ? asking : undefined}
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
      <WaitingToast id={outcome?.kind === 'waiting' ? outcome.id : undefined} />
    </View>
  );
}
