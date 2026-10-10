import type {
  MessageSummary as SummaryStore,
  NativeAssistance,
  SummaryState,
} from '@private-email/mail-core/assistance';
import type { ReadableBody } from '@private-email/mail-core/message-body';
import type { TurboModule } from 'react-native';

import {
  canRetryAssistance,
  createMessageSummary,
  readableBodyText,
  summaryInput,
} from '@private-email/mail-core/assistance';
import { spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  ActivityIndicator,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  summary: {
    gap: spacing.small,
    padding: spacing.medium,
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.large,
  },
  title: { fontSize: 15, fontWeight: '600' },
  text: { fontSize: 16, lineHeight: 24 },
  secondary: { fontSize: 14, lineHeight: 21 },
});

interface AssistanceModule extends TurboModule, NativeAssistance {}

const native = () =>
  TurboModuleRegistry.getEnforcing<AssistanceModule>('UnwiredAssistance');

// The host's on-device Apple model; Mock Mail Session tests substitute their own.
export const AssistanceContext = createContext<NativeAssistance>({
  availability: () => native().availability(),
  summarize: (request, input) => native().summarize(request, input),
  rewrite: (request, input) => native().rewrite(request, input),
  suggestReply: (request, input) => native().suggestReply(request, input),
  cancel: (request) => native().cancel(request),
});

const idle: SummaryState = { kind: 'idle' };

function SummaryContent({
  summary,
  state,
  onRetry,
}: {
  readonly summary: SummaryStore;
  readonly state: Exclude<SummaryState, { kind: 'idle' }>;
  readonly onRetry: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const dismiss = (
    <Action
      label={t('summary.dismiss')}
      accessibilityLabel={t('summary.dismissLabel')}
      onPress={() => {
        summary.discard();
      }}
    />
  );
  if (state.kind === 'summarizing') {
    return (
      <View style={styles.row}>
        <ActivityIndicator accessibilityLabel={t('summary.progress')} />
        <Text
          selectable
          style={[styles.secondary, { color: colors.secondary }]}>
          {t('summary.summarizing')}
        </Text>
        <Action
          label={t('common.cancel')}
          accessibilityLabel={t('summary.cancelLabel')}
          onPress={() => {
            summary.cancel();
          }}
        />
      </View>
    );
  }
  if (state.kind === 'ready') {
    return (
      <>
        <Text
          selectable
          accessibilityRole="header"
          style={[styles.title, { color: colors.foreground }]}>
          {t('summary.title')}
        </Text>
        <Text
          selectable
          style={[styles.text, { color: colors.foreground }]}>
          {state.text}
        </Text>
        {state.omitted ? (
          <Text
            selectable
            style={[styles.secondary, { color: colors.secondary }]}>
            {t('summary.omitted')}
          </Text>
        ) : null}
        <Text
          selectable
          style={[styles.secondary, { color: colors.secondary }]}>
          {t('summary.disclaimer')}
        </Text>
        {dismiss}
      </>
    );
  }
  return (
    <>
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.secondary }]}>
        {t(
          `summary.${state.kind === 'unavailable' ? state.reason : state.kind}`,
        )}
      </Text>
      <View style={styles.row}>
        {canRetryAssistance(state) ? (
          <Action
            label={t('common.retry')}
            accessibilityLabel={t('summary.summarizeAgainLabel')}
            onPress={onRetry}
          />
        ) : null}
        {dismiss}
      </View>
    </>
  );
}

// An explicitly requested on-device summary of the already-local message text in the reader.
// Nothing runs until the person asks, and the preview is never saved or written to mail.
export function MessageSummary({
  source,
  id,
  subject,
  body,
}: {
  // The mailbox store the message belongs to; with the id, it identifies the summarized message.
  readonly source: object;
  readonly id: string;
  readonly subject?: string | undefined;
  readonly body: ReadableBody | string;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  const input = useMemo(
    () =>
      summaryInput({
        subject,
        body: typeof body === 'string' ? body : readableBodyText(body),
      }),
    [subject, body],
  );
  // Another message, mailbox, account or captured input replaces the summary before rendering, so a result
  // for the previous one is never shown; the effect below cancels and forgets it.
  const [owner, setOwner] = useState(() => ({
    assistance,
    source,
    id,
    input,
    summary: createMessageSummary(assistance),
  }));
  let current = owner;
  if (
    owner.assistance !== assistance ||
    owner.source !== source ||
    owner.id !== id ||
    owner.input?.text !== input?.text ||
    owner.input?.omitted !== input?.omitted
  ) {
    current = {
      assistance,
      source,
      id,
      input,
      summary: createMessageSummary(assistance),
    };
    setOwner(current);
  }
  const { summary } = current;
  // Native input can be queued before the reader's message, mailbox, account or input changes and
  // be delivered afterward; only the committed summary may start inference. A replaced summary is
  // cancelled and forgotten as the new one commits, before passive effects, so a pending
  // availability check cannot start the model on the previous message.
  const committed = useRef<SummaryStore>(undefined);
  useLayoutEffect(() => {
    committed.current = summary;
    return () => {
      committed.current = undefined;
      summary.discard();
    };
  }, [summary]);
  const state = useSyncExternalStore(summary.subscribe, () =>
    input === undefined ? idle : summary.getSnapshot(input),
  );
  if (input === undefined) {
    return null;
  }
  const start = () => {
    if (committed.current === summary) {
      void summary.summarize(input);
    }
  };
  if (state.kind === 'idle') {
    return (
      <View style={styles.row}>
        <Action
          label={t('summary.summarize')}
          accessibilityLabel={t('summary.summarizeLabel')}
          onPress={start}
        />
      </View>
    );
  }
  return (
    <View
      accessibilityLabel={t('summary.region')}
      style={[styles.summary, { borderColor: colors.separator }]}>
      <SummaryContent
        summary={summary}
        state={state}
        onRetry={start}
      />
    </View>
  );
}
