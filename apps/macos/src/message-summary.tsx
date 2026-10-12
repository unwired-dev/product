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
import { radius, spacing } from '@private-email/mail-core/theme';
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
import { OnDeviceMarker } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  summary: {
    gap: spacing.s,
    padding: spacing.m,
    borderRadius: radius.card,
    width: '100%',
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.xl,
  },
  title: { ...textStyles.bodyEmphasized },
  text: { ...textStyles.reading.body },
  secondary: { ...textStyles.body },
});

interface AssistanceModule extends TurboModule, NativeAssistance {}

const native = () =>
  TurboModuleRegistry.getEnforcing<AssistanceModule>('UnwiredAssistance');

// The host's on-device Apple model; Mock Mail Session tests substitute their own.
export const nativeAssistance: NativeAssistance = {
  availability: () => native().availability(),
  summarize: (request, input) => native().summarize(request, input),
  rewrite: (request, input) => native().rewrite(request, input),
  suggestReply: (request, input) => native().suggestReply(request, input),
  cancel: (request) => native().cancel(request),
};

// The model while Mail Assistance Enablement permits On-Device Mail Assistance; without it every
// assistance action is hidden and nothing reaches the model.
export const AssistanceContext = createContext<NativeAssistance | undefined>(
  undefined,
);

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
          style={[styles.secondary, { color: colors.textSecondary }]}>
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
          style={[styles.title, { color: colors.textPrimary }]}>
          {t('summary.title')}
        </Text>
        <Text
          selectable
          style={[styles.text, { color: colors.textPrimary }]}>
          {state.text}
        </Text>
        {state.omitted ? (
          <Text
            selectable
            style={[styles.secondary, { color: colors.textSecondary }]}>
            {t('summary.omitted')}
          </Text>
        ) : null}
        <OnDeviceMarker label={t('summary.disclaimer')} />
        {dismiss}
      </>
    );
  }
  return (
    <>
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.textSecondary }]}>
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

interface SummaryProps {
  // The mailbox store the message belongs to; with the id, it identifies the summarized message.
  readonly source: object;
  readonly id: string;
  readonly subject?: string | undefined;
  readonly body: ReadableBody | string;
}

// An explicitly requested on-device summary of the already-local message text in the reader.
// Nothing runs until the person asks, and the preview is never saved or written to mail. Turning
// Mail Assistance Enablement off unmounts it, which cancels the request and forgets its preview.
export function MessageSummary(props: SummaryProps) {
  const assistance = use(AssistanceContext);
  return assistance === undefined ? null : (
    <Summary
      assistance={assistance}
      {...props}
    />
  );
}

function Summary({
  assistance,
  source,
  id,
  subject,
  body,
}: SummaryProps & { readonly assistance: NativeAssistance }) {
  const colors = usePalette();
  const { t } = useLocalization();
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
  const enabled = useMailAssistanceLifetime(() => {
    summary.discard();
  });
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
    if (committed.current === summary && enabled()) {
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
      style={[styles.summary, { backgroundColor: colors.onDeviceSurface }]}>
      <SummaryContent
        summary={summary}
        state={state}
        onRetry={start}
      />
    </View>
  );
}
