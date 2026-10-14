import type { ImapInbox } from '@private-email/mail-core/imap-inbox';

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
import { usePalette } from './theme.ts';
import { MessageTranslation } from './translation.tsx';

// An IMAP message's body, downloaded once and then read from this device. Remote Message Content
// is never loaded for IMAP mail yet, and its attachments are only counted; links open only after
// the person confirms the destination shown here.
export function ImapMessageBody({
  inbox,
  id,
  subject,
}: {
  readonly inbox: ImapInbox;
  readonly id: string;
  readonly subject?: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const confirm = use(LinkConfirmationContext);
  // oxlint-disable-next-line react/hook-use-state -- This immutable reader identity has no setter.
  const [reader] = useState(() => Symbol('IMAP reader'));
  const body = useSyncExternalStore(inbox.subscribe, () =>
    inbox.messageBody(id, reader),
  );
  const showing = useRef<{ readonly inbox: ImapInbox; readonly id: string }>(
    undefined,
  );
  useLayoutEffect(() => {
    showing.current = { inbox, id };
    return () => {
      showing.current = undefined;
    };
  }, [inbox, id]);
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
      {(body.presentation.rich?.remote.images.length ?? 0) > 0 ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('messageBody.imap-remote')}
        </Text>
      ) : null}
      <Presentation
        presentation={body.presentation}
        onNear={() => undefined}
        onLoadImages={undefined}
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
