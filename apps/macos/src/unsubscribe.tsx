import type { GmailInbox } from '@private-email/mail-core/inbox-store';
import type {
  Unsubscribe,
  UnsubscribeOffer,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';

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
import { Button, Popover } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { unsubscribe } from './registration.ts';
import { textStyles, usePalette } from './theme.ts';

export const UnsubscribeContext = createContext<Unsubscribe>(unsubscribe);

// The Mac Unsubscribe frames: a 12pt banner with 4pt between its lines and 8pt between buttons,
// and the confirmation popover's 20pt inset and 10pt rhythm.
const styles = StyleSheet.create({
  banner: {
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

type OneClick = Extract<UnsubscribeOffer, { kind: 'one-click' }>;

// One message's Unsubscribe: whether its stored request was looked up, whether a request is under
// way, and how the last one ended, with when a sent one was sent. It lives outside the reader,
// keyed by Product Account, Mail Profile, connection and message, so a result arriving after the
// reader moved on changes only the message it was sent from.
type Entry = Readonly<{
  checked?: boolean;
  sending?: boolean;
  outcome?:
    | Readonly<{ kind: 'sent'; at: number }>
    | Readonly<{ kind: Exclude<UnsubscribeOutcome, 'sent'> }>;
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

// Each confirmation opening is its own popover, so a late close of the last one cannot close it.
let openings = 0;
const nextOpening = () => {
  openings += 1;
  return openings;
};

// The opened message's store; one without bodies, such as the preview fixture, offers nothing.
type Source = Pick<GmailInbox, 'subscribe'> &
  Partial<Pick<GmailInbox, 'responseSource'>>;

// The opened message's one-click offer in the scoped mailbox and Profile, and its Unsubscribe
// state. A `mailto:` offer shows nothing yet.
function useOneClick(inbox: Source, id: string) {
  const store = use(UnsubscribeContext);
  const account = use(AccountContext)?.account;
  const profile = useProfile();
  const mailbox = useMailbox();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    inbox.responseSource?.(id),
  );
  const offer = useMemo(() => {
    const found = unsubscribeOf(document);
    return found?.kind === 'one-click' ? found : undefined;
  }, [document]);
  const key = `${account}\n${profile}\n${mailbox?.id}\n${id}`;
  const entry =
    useSyncExternalStore(subscribe, () => entries.get(key)) ?? nothing;
  // Sends the request once; a press while one is under way sends nothing.
  const send = async (sending: OneClick) => {
    if (entries.get(key)?.sending === true) {
      return;
    }
    update(key, (each) => ({ ...each, sending: true }));
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
    key,
    entry,
    send,
  };
}

// Whether Unsubscribe… is offered: the stored request was looked up, none is under way and none has
// ended, when the banner offers what comes next.
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
  readonly offer: OneClick;
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
          {t('unsubscribe.confirm', { sender, address })}
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

// A confirmation that opens on request and closes on Cancel, Unsubscribe or a click outside.
function useAsking() {
  const [asking, setAsking] = useState<number>();
  return {
    asking,
    ask: () => {
      setAsking(nextOpening());
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
  const { offer, address, key, entry, send } = useOneClick(inbox, id);
  const { asking, ask, close } = useAsking();
  if (offer === undefined || address === undefined) {
    return { items: [], confirmation: () => null };
  }
  const items: readonly PopUpItem[] = offered(entry)
    ? [{ key: `${key}\nunsubscribe`, title: t('unsubscribe.action'), run: ask }]
    : [];
  return {
    items,
    confirmation: (sender: string) => (
      <Confirmation
        offer={offer}
        sender={sender}
        address={address}
        opening={asking}
        onClose={close}
        onConfirm={() => {
          close();
          void send(offer);
        }}
      />
    ),
  };
}

// The reader's Unsubscribe banner for a message with a one-click offer: the list and
// Unsubscribe…, which asks before sending, then the request's outcome. Sent is dated and offers
// nothing more; Failed and uncertain offer Try Again, which sends without asking again, and Block
// Sender…. A request the Profile sent to the list in the 14 days before the message arrived shows
// as sent, and nothing is offered until that is known.
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
  const { store, profile, offer, address, connection, key, entry, send } =
    useOneClick(inbox, id);
  const { asking, ask, close } = useAsking();
  const { anchor, items } = useBlockSender();
  useEffect(() => {
    if (offer === undefined) {
      return;
    }
    const recall = async () => {
      try {
        const request = await store.sentRequest(profile, offer, receivedAt);
        update(key, (each) => ({
          ...each,
          checked: true,
          ...(request === undefined || each.outcome !== undefined
            ? {}
            : { outcome: { kind: 'sent', at: request.sentAt } }),
        }));
      } catch {
        update(key, (each) => ({ ...each, checked: true }));
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
  let marker = offer.list;
  let summary: string | undefined = undefined;
  if (outcome?.kind === 'sent') {
    marker = t('unsubscribe.sent');
    summary = t('unsubscribe.sentDetail', {
      sender: sender.name,
      date: day.format(outcome.at),
    });
  } else if (outcome !== undefined) {
    marker = t(`unsubscribe.${outcome.kind}`);
    summary = t(`unsubscribe.${outcome.kind}Detail`, { sender: sender.name });
  }
  return (
    <View
      ref={anchor}
      collapsable={false}
      style={[styles.banner, { backgroundColor: colors.fillQuiet }]}>
      <Label style={[styles.marker, primary]}>{marker}</Label>
      {summary === undefined ? null : (
        <Label
          accessibilityLiveRegion="polite"
          style={[styles.summary, primary]}>
          {summary}
        </Label>
      )}
      {outcome?.kind === 'sent' ? null : (
        <View style={styles.actions}>
          {outcome === undefined ? (
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
                opening={asking}
                onClose={close}
                onConfirm={() => {
                  close();
                  void send(offer);
                }}
              />
            </View>
          ) : (
            <>
              <Button
                label={t('unsubscribe.tryAgain')}
                disabled={sending}
                onPress={() => {
                  void send(offer);
                }}
              />
              {block === undefined ? null : (
                <Button
                  label={block.title}
                  disabled={sending}
                  onPress={() => {
                    void block.run();
                  }}
                />
              )}
            </>
          )}
        </View>
      )}
    </View>
  );
}
