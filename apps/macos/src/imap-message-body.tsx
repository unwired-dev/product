import type { ImapInbox } from '@private-email/mail-core/imap-inbox';

import Clipboard from '@react-native-clipboard/clipboard';
import {
  use,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { ActivityIndicator, Text, View } from 'react-native';

import { Action } from './action.tsx';
import { useLocalization } from './localization.ts';
import { styles } from './message-body-styles.ts';
import {
  LinkConfirmationContext,
  Presentation,
  withoutLinkFrom,
} from './message-body.tsx';
import { MessageSummary } from './message-summary.tsx';
import { useRemoteContentPolicy } from './remote-content.tsx';
import { usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

// An IMAP message's body, downloaded once and then read from this device. Remote Message Content
// follows the connection's policy as for Gmail mail, and attachments are only counted; links open
// only after the person confirms the destination shown here.
export function ImapMessageBody({
  inbox,
  id,
  subject,
  connection,
}: {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly subject?: string | undefined;
  // The Mailbox Connection whose remote content policy applies.
  readonly connection?: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const confirm = use(LinkConfirmationContext);
  const policy = useRemoteContentPolicy(connection);
  // Consent under Ask belongs to this message's presentation.
  const [consent, setConsent] = useState<{
    readonly inbox: ImapInbox;
    readonly id: string;
  }>();
  // Never, or another Inbox, revokes this presentation's Ask consent.
  if (
    consent !== undefined &&
    (policy === 'never' || consent.inbox !== inbox)
  ) {
    setConsent(undefined);
  }
  const consented = consent?.inbox === inbox && consent.id === id;
  // oxlint-disable-next-line react/hook-use-state -- This immutable reader identity has no setter.
  const [reader] = useState(() => Symbol('IMAP reader'));
  // Retire network permission before queued native measurements can observe the new policy.
  useLayoutEffect(() => {
    if (policy === 'never') {
      inbox.forgetRemoteImages(id);
    } else if (policy === 'ask' && !consented) {
      void inbox.loadRemoteImages(id, [], { network: false, reader });
    }
  }, [inbox, id, policy, consented, reader]);
  const body = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageBody(id, reader),
  );
  const showing = useRef<{
    readonly inbox: ImapInbox;
    readonly id: string;
    readonly policy: typeof policy;
    readonly consented: boolean;
  }>(undefined);
  useLayoutEffect(() => {
    showing.current = { inbox, id, policy, consented };
    return () => {
      showing.current = undefined;
    };
  }, [inbox, id, policy, consented]);
  useEffect(() => {
    const release = inbox.retainMessage(id, reader);
    void inbox.readMessage(id);
    return release;
  }, [inbox, id, reader]);
  // A replaced or closed body discards a confirmation chosen in it.
  useEffect(() => {
    if (body?.kind !== 'ready') {
      return undefined;
    }
    return () => {
      confirm?.(withoutLinkFrom(inbox, id));
    };
  }, [body, confirm, inbox, id]);
  if (body === undefined || body.kind === 'loading') {
    return (
      <ActivityIndicator
        accessibilityLabel={t('messageBody.opening')}
        style={styles.body}
      />
    );
  }
  if (body.kind === 'unavailable') {
    return (
      <View style={styles.body}>
        <Text
          accessibilityRole="alert"
          style={[styles.paragraph, { color: colors.textSecondary }]}>
          {t(`messageBody.${body.reason}`)}
        </Text>
        {body.reason === 'imap-missing' ? null : (
          <Action
            label={t('common.retry')}
            onPress={() => {
              void inbox.readMessage(id);
            }}
          />
        )}
      </View>
    );
  }
  const current = () =>
    showing.current?.inbox === inbox &&
    showing.current.id === id &&
    inbox.messageBody(id, reader) === body;
  return (
    <View style={styles.body}>
      <View style={styles.assistance}>
        <MessageSummary
          source={inbox}
          id={id}
          subject={subject}
          body={body.presentation.readable}
        />
        <MessageTranslation
          source={inbox}
          id={id}
          body={body.presentation.readable}
        />
      </View>
      <Presentation
        onCopy={(link) => {
          if (current()) {
            Clipboard.setString(link.href);
          }
        }}
        presentation={body.presentation}
        // Never shows no remote content, even what an earlier authorization cached.
        onNear={(urls) => {
          if (
            policy !== 'never' &&
            current() &&
            showing.current?.policy === policy &&
            showing.current.consented === consented
          ) {
            void inbox.loadRemoteImages(id, urls, {
              network: policy === 'always' || consented,
              reader,
            });
          }
        }}
        onLoadImages={
          policy === 'ask' && !consented
            ? () => {
                if (current()) {
                  setConsent({ inbox, id });
                }
              }
            : undefined
        }
        onFailure={() => {
          if (current()) {
            inbox.discardRichMessage(id, body.presentation, reader);
          }
        }}
        onChoose={(link) => {
          if (current()) {
            confirm?.({ inbox, id, link, current, subscribe: inbox.subscribe });
          }
        }}
      />
      {body.attachments === 0 ? null : (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('messageBody.imap-attachments', { count: body.attachments })}
        </Text>
      )}
    </View>
  );
}
