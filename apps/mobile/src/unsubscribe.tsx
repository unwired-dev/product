import type { MenuItem } from '@private-email/mail-core/context-menu';
import type {
  SentUnsubscribeRequest,
  Unsubscribe,
  UnsubscribeOutcome,
} from '@private-email/mail-core/unsubscribe';

import { Alert, Button, Host, Spacer, Text } from '@expo/ui/swift-ui';
import { frame } from '@expo/ui/swift-ui/modifiers';
import { unsubscribeOf } from '@private-email/mail-core/unsubscribe';
import {
  createContext,
  use,
  useEffect,
  useMemo,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  Text as NativeText,
  Platform,
  View,
} from 'react-native';

import { useBlockSender } from './block-sender.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { useInboxActions, useMailbox, useProfile } from './mailbox.tsx';
import { styles } from './message-body-styles.ts';
import { BannerButton } from './message-body.tsx';
import { AccountContext } from './registration-gate.tsx';
import { unsubscribe } from './registration.ts';
import { usePalette } from './theme.ts';

export const UnsubscribeContext = createContext<Unsubscribe>(unsubscribe);

const compact = Platform.OS === 'ios' && !Platform.isPad;

// One message's Unsubscribe: whether its stored request was looked up, whether the confirmation is
// open, whether a request is under way, and how the last one ended, with when a sent one was sent.
// It lives outside the reader, keyed by Product Account, Mail Profile, connection and message, so a
// result arriving after the reader moved on changes only the message it was sent from.
type Entry = Readonly<{
  checked?: boolean;
  // The latest stored-request lookup; only its answer counts.
  lookup?: number;
  asking?: boolean;
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
let lookups = 0;

// Whether Unsubscribe… is offered: the stored request was looked up, none is under way and none has
// ended, when the banner offers what comes next.
const offered = (entry: Entry) =>
  entry.checked === true &&
  entry.sending !== true &&
  entry.outcome === undefined;

// The opened message's one-click offer in the scoped mailbox and Profile, and its Unsubscribe
// state. A `mailto:` offer, or a store without bodies such as the preview fixture, shows nothing.
function useOneClick(id: string) {
  const store = use(UnsubscribeContext);
  const account = use(AccountContext)?.account;
  const profile = useProfile();
  const mailbox = useMailbox();
  const inbox = useInboxActions();
  const document = useSyncExternalStore(inbox.subscribe, () =>
    'responseSource' in inbox ? inbox.responseSource(id) : undefined,
  );
  const offer = useMemo(() => {
    const found = unsubscribeOf(document);
    return found?.kind === 'one-click' && mailbox !== undefined
      ? found
      : undefined;
  }, [document, mailbox]);
  const key = `${account}\n${profile}\n${mailbox?.id}\n${id}`;
  const entry =
    useSyncExternalStore(subscribe, () => entries.get(key)) ?? nothing;
  return { store, profile, offer, mailbox, key, entry };
}

// The More menu's Unsubscribe… for the opened message, which opens the banner's confirmation.
export function useUnsubscribeItems(id: string): readonly MenuItem[] {
  const { t } = useLocalization();
  const { offer, key, entry } = useOneClick(id);
  return offer === undefined || !offered(entry)
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

// The reader's Unsubscribe banner, where the device's frames draw it: above the message on iPhone,
// beneath its header on iPad.
export function UnsubscribeBanner({
  message,
  above = false,
}: Parameters<typeof Banner>[0] & { readonly above?: boolean }) {
  return above === compact ? <Banner message={message} /> : null;
}

// The banner for a message with a one-click offer, in the Schedule Banner recipe: the list and Unsubscribe…, which asks in the system alert before sending, then the
// request's outcome. Sent is dated and offers nothing more; Failed and uncertain offer Try Again,
// which sends without asking again, and Block Sender…. A request the Profile sent to the list in
// the 14 days before the message arrived shows as sent, and nothing is offered until that is known.
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
  const { store, profile, offer, mailbox, key, entry } = useOneClick(
    message.id,
  );
  const block = useBlockSender();
  const receivedAt = new Date(message.receivedAt).getTime();
  useEffect(() => {
    if (offer === undefined) {
      return undefined;
    }
    // Each opening looks the stored request up again, and offers nothing until it is known.
    lookups += 1;
    const lookup = lookups;
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
    // Leaving the message closes its confirmation without acting.
    return () => {
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
  if (offer === undefined || mailbox === undefined) {
    return null;
  }
  const marker = (outcome: Entry['outcome']) =>
    outcome === undefined ? offer.list : t(`unsubscribe.${outcome.kind}`);
  const summary = (outcome: Entry['outcome']) => {
    if (outcome?.kind === 'sent') {
      return t('unsubscribe.sentDetail', {
        sender: message.sender,
        date: day.format(outcome.at),
      });
    }
    return outcome === undefined
      ? undefined
      : t(`unsubscribe.${outcome.kind}Detail`, { sender: message.sender });
  };
  // Sends the request once; a press before the stored request is known, while one is under way or
  // after one was sent sends nothing. VoiceOver hears the outcome once.
  const send = async () => {
    const current = entries.get(key) ?? nothing;
    if (
      current.checked !== true ||
      current.sending === true ||
      current.outcome?.kind === 'sent'
    ) {
      return;
    }
    update(key, (each) => ({ ...each, sending: true }));
    let at = Date.now();
    const kind = await store
      .request(profile, offer, () => {
        at = Date.now();
        return at;
      })
      .catch((): UnsubscribeOutcome => 'uncertain');
    const outcome: Entry['outcome'] = kind === 'sent' ? { kind, at } : { kind };
    update(key, (each) => ({ ...each, sending: false, outcome }));
    AccessibilityInfo.announceForAccessibility(
      `${marker(outcome)}. ${summary(outcome)}`,
    );
  };
  const close = () => {
    update(key, (each) => ({ ...each, asking: false }));
  };
  const { outcome, sending = false } = entry;
  const [blocking] = block.items(message.address, mailbox.id, message.id);
  const shown = summary(outcome);
  const busy = sending || entry.checked !== true;
  return (
    <View
      style={[
        ipad ? styles.padBanner : styles.banner,
        { backgroundColor: colors.fillQuiet },
      ]}>
      {/* VoiceOver reads the label, then the summary, as one element before the buttons. */}
      <View accessible>
        <NativeText
          style={[
            ipad ? styles.padBannerTitle : styles.bannerTitle,
            { color: colors.textPrimary },
          ]}>
          {marker(outcome)}
        </NativeText>
        {shown === undefined ? null : (
          <NativeText
            style={[
              ipad ? styles.padBannerText : styles.bannerText,
              { color: colors.textSecondary },
            ]}>
            {shown}
          </NativeText>
        )}
      </View>
      {outcome?.kind === 'sent' ? null : (
        <View style={ipad ? styles.padBannerActions : styles.bannerActions}>
          {outcome === undefined ? (
            <BannerButton
              label={t('unsubscribe.action')}
              disabled={!offered(entry)}
              onPress={() => {
                update(key, (each) => ({ ...each, asking: true }));
              }}
            />
          ) : (
            <>
              <BannerButton
                label={t('unsubscribe.tryAgain')}
                disabled={busy}
                onPress={() => {
                  void send();
                }}
              />
              {blocking === undefined ? null : (
                <BannerButton
                  label={blocking.title}
                  disabled={busy}
                  onPress={() => {
                    blocking.run();
                  }}
                />
              )}
            </>
          )}
        </View>
      )}
      {entry.asking === true && offered(entry) ? (
        <View style={styles.alertAnchor}>
          <Host matchContents>
            {/* The system alert owns focus and dismissal; Cancel's role makes it the dismissal
                choice, and Unsubscribe is the default. */}
            <Alert
              testID="unsubscribe-confirmation"
              title={t('unsubscribe.confirmTitle', { list: offer.list })}
              isPresented
              onIsPresentedChange={(presented) => {
                if (!presented) {
                  close();
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
                    close();
                    void send();
                  }}
                />
                <Button
                  // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
                  role="cancel"
                  label={t('common.cancel')}
                  onPress={close}
                />
              </Alert.Actions>
              <Alert.Message>
                <Text>
                  {t('unsubscribe.confirm', {
                    sender: message.sender,
                    address: mailbox.address,
                  })}
                </Text>
              </Alert.Message>
            </Alert>
          </Host>
        </View>
      ) : null}
      {block.alert}
    </View>
  );
}
