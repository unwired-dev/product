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
  useSyncExternalStore,
} from 'react';
import { StyleSheet, View } from 'react-native';

import type { PopUpItem } from './composer-controls.tsx';

import { useBlockSender } from './block-sender.ts';
import { Button, Popover } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProfile } from './mailbox.tsx';
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

// What one message's Unsubscribe shows: how its last request ended, with when a sent one was sent,
// whether a request is under way, and which opening of the confirmation is asked for. It lives
// outside the reader, keyed by Mail Profile, connection and message, so a result arriving after
// the reader moved on changes only the message it was sent from.
type Entry = Readonly<{
  outcome?:
    | Readonly<{ kind: 'sent'; at: number }>
    | Readonly<{ kind: Exclude<UnsubscribeOutcome, 'sent'> }>;
  sending?: boolean;
  asking?: number | undefined;
}>;
const entries = new Map<string, Entry>();
const listeners = new Set<() => void>();
const nothing: Entry = {};
let openings = 0;
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

// The opened message's store; one without bodies, such as the preview fixture, offers nothing.
type Source = Pick<GmailInbox, 'subscribe'> &
  Partial<Pick<GmailInbox, 'responseSource'>>;

// The opened message's one-click offer in the scoped mailbox and Profile, and its Unsubscribe
// state. A `mailto:` offer shows nothing yet. With `receivedAt`, a request the Profile sent to the
// list in the 14 days before the message arrived shows as sent.
function useOneClick(inbox: Source, id: string, receivedAt?: number) {
  const store = use(UnsubscribeContext);
  const profile = useProfile();
  const mailbox = useMailbox();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    inbox.responseSource?.(id),
  );
  const offer = useMemo(() => {
    const found = unsubscribeOf(document);
    return found?.kind === 'one-click' ? found : undefined;
  }, [document]);
  const key = `${profile}\n${mailbox?.id}\n${id}`;
  const entry =
    useSyncExternalStore(subscribe, () => entries.get(key)) ?? nothing;
  useEffect(() => {
    if (offer === undefined || receivedAt === undefined) {
      return;
    }
    const recall = async () => {
      const request = await store.sentRequest(profile, offer, receivedAt);
      if (request !== undefined) {
        update(key, (each) =>
          each.outcome === undefined && each.sending !== true
            ? { ...each, outcome: { kind: 'sent', at: request.sentAt } }
            : each,
        );
      }
    };
    void recall();
  }, [store, profile, offer, receivedAt, key]);
  // Sends the request once; a press while one is under way sends nothing.
  const send = async (sending: OneClick) => {
    if (entries.get(key)?.sending === true) {
      return;
    }
    update(key, (each) => ({ ...each, sending: true }));
    const outcome = await store
      .request(profile, sending)
      .catch((): UnsubscribeOutcome => 'uncertain');
    update(key, (each) => ({
      ...each,
      sending: false,
      outcome:
        outcome === 'sent'
          ? { kind: 'sent', at: Date.now() }
          : { kind: outcome },
    }));
  };
  return {
    offer: mailbox === undefined ? undefined : offer,
    address: mailbox?.address,
    connection: mailbox?.id ?? '',
    key,
    entry,
    send,
    ask: () => {
      openings += 1;
      const opening = openings;
      update(key, (each) => ({ ...each, asking: opening }));
    },
  };
}

// The More menu's Unsubscribe… for the opened message, which opens the banner's confirmation; none
// while a request is under way or once one has ended, when the banner offers what comes next.
export function useUnsubscribeItems(
  inbox: Source,
  id: string,
): readonly PopUpItem[] {
  const { t } = useLocalization();
  const { offer, key, entry, ask } = useOneClick(inbox, id);
  return offer === undefined ||
    entry.sending === true ||
    entry.outcome !== undefined
    ? []
    : [
        {
          key: `${key}\nunsubscribe`,
          title: t('unsubscribe.action'),
          run: ask,
        },
      ];
}

// The reader's Unsubscribe banner for a message with a one-click offer: the list and
// Unsubscribe…, which asks before sending, then the request's outcome. Sent is dated and offers
// nothing more; Failed and uncertain offer Try Again, which sends without asking again, and Block
// Sender….
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
  const { offer, address, connection, key, entry, send, ask } = useOneClick(
    inbox,
    id,
    receivedAt,
  );
  const { anchor, items } = useBlockSender();
  // Leaving the message closes a confirmation asked in it.
  useEffect(
    () => () => {
      update(key, (each) => ({ ...each, asking: undefined }));
    },
    [key],
  );
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
  const { outcome, sending = false, asking } = entry;
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
                disabled={sending}
                onPress={ask}
              />
              <Popover
                // Each opening is its own popover, so the last one's close, arriving late, cannot
                // close it.
                key={asking}
                below
                title={t('unsubscribe.confirmTitle', { list: offer.list })}
                shown={asking !== undefined}
                onClose={() => {
                  update(key, (each) =>
                    each.asking === asking
                      ? { ...each, asking: undefined }
                      : each,
                  );
                }}>
                <View style={styles.panel}>
                  <Label
                    accessibilityRole="header"
                    style={[textStyles.title3Emphasized, primary]}>
                    {t('unsubscribe.confirmTitle', { list: offer.list })}
                  </Label>
                  <Label
                    style={[textStyles.body, { color: colors.textSecondary }]}>
                    {t('unsubscribe.confirm', { sender: sender.name, address })}
                  </Label>
                  <View style={styles.buttons}>
                    <Button
                      label={t('common.cancel')}
                      isCancel
                      onPress={() => {
                        update(key, (each) => ({ ...each, asking: undefined }));
                      }}
                    />
                    <Button
                      label={t('unsubscribe.confirmAction')}
                      fill="accent"
                      isDefault
                      onPress={() => {
                        update(key, (each) => ({ ...each, asking: undefined }));
                        void send(offer);
                      }}
                    />
                  </View>
                </View>
              </Popover>
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
