import type {
  CapturedDraftText,
  DraftAssistance as DraftAssistanceStore,
  DraftAssistanceInput,
  DraftAssistanceState,
  NativeAssistance,
} from '@private-email/mail-core/assistance';

import {
  canRetryAssistance,
  createDraftAssistance,
} from '@private-email/mail-core/assistance';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Action } from './action.tsx';
import { OnDeviceMarker } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  panel: {
    gap: spacing.s,
    padding: spacing.l,
    borderRadius: radius.card,
    borderWidth: StyleSheet.hairlineWidth,
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

type Purpose = 'rewrite' | 'reply';

const idle: DraftAssistanceState = { kind: 'idle' };

const finished = (state: DraftAssistanceState) =>
  state.kind !== 'idle' && state.kind !== 'generating';

// The panel's own request for its captured input. It starts once committed; unmounting, or a
// replaced store, cancels the request and forgets its preview before passive effects. `act` runs
// only for the state it was rendered with, so queued input cannot affect a replaced request.
function useDraftAssistance(
  native: NativeAssistance,
  input: DraftAssistanceInput | undefined,
) {
  const [owner, setOwner] = useState(() => ({
    native,
    store: createDraftAssistance(native),
  }));
  let { store } = owner;
  if (owner.native !== native) {
    store = createDraftAssistance(native);
    setOwner({ native, store });
  }
  const enabled = useMailAssistanceLifetime(() => {
    store.discard();
  });
  const committed = useRef<DraftAssistanceStore>(undefined);
  useLayoutEffect(() => {
    committed.current = store;
    if (input !== undefined && enabled()) {
      void store.start(input);
    }
    return () => {
      committed.current = undefined;
      store.discard();
    };
  }, [store, input, enabled]);
  const state = useSyncExternalStore(store.subscribe, () =>
    input === undefined ? idle : store.getSnapshot(input),
  );
  const act = (
    action: (store: DraftAssistanceStore, input: DraftAssistanceInput) => void,
  ) => {
    if (
      committed.current === store &&
      enabled() &&
      input !== undefined &&
      store.getSnapshot(input) === state
    ) {
      action(store, input);
    }
  };
  return { store, state, act };
}

// Why captured text cannot be sent to the model.
function Refusal({
  purpose,
  issue,
}: {
  readonly purpose: Purpose;
  readonly issue: CapturedDraftText['issue'];
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Text
      selectable
      accessibilityRole="alert"
      style={[styles.secondary, { color: colors.textSecondary }]}>
      {t(
        issue === undefined
          ? 'assistance.failed'
          : `assistance.${purpose}${issue === 'inline-image' ? 'HasImage' : 'TooLong'}`,
      )}
    </Text>
  );
}

// Progress with Cancel, the finished result, or why there is none.
function Status({
  purpose,
  state,
  onCancel,
}: {
  readonly purpose: Purpose;
  readonly state: DraftAssistanceState;
  readonly onCancel: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (!finished(state)) {
    return (
      <View style={styles.row}>
        <ActivityIndicator accessibilityLabel={t('assistance.progress')} />
        <Text
          selectable
          style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('assistance.generating')}
        </Text>
        <Action
          label={t('common.cancel')}
          accessibilityLabel={t('assistance.cancelLabel')}
          onPress={onCancel}
        />
      </View>
    );
  }
  if (state.kind !== 'ready') {
    return (
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {t(
          `assistance.${state.kind === 'unavailable' ? state.reason : state.kind}`,
        )}
      </Text>
    );
  }
  return (
    <>
      <Text
        selectable
        accessibilityRole="header"
        style={[styles.title, { color: colors.textPrimary }]}>
        {t(`assistance.${purpose}Title`)}
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
          {t('assistance.omitted')}
        </Text>
      ) : null}
      <OnDeviceMarker label={t('assistance.disclaimer')} />
    </>
  );
}

// Review of an explicitly requested rewrite or reply suggestion for captured Draft text. Opening it
// is the request. The Draft changes only when the person applies the result; the owner then
// replaces exactly the captured text as one undoable edit. Nothing is saved or sent.
export function DraftAssistance({
  native,
  purpose,
  issue,
  input,
  onApply,
  onClose,
}: {
  readonly native: NativeAssistance;
  readonly purpose: Purpose;
  // Why the captured text was refused, when the person can act on it.
  readonly issue: CapturedDraftText['issue'];
  readonly input: DraftAssistanceInput | undefined;
  readonly onApply: (replacement: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { store, state, act } = useDraftAssistance(native, input);
  const apply = purpose === 'rewrite' ? 'replace' : 'useReply';
  return (
    <View
      accessibilityLabel={t(`assistance.${purpose}Region`)}
      style={[
        styles.panel,
        {
          borderColor: colors.separator,
          backgroundColor:
            state.kind === 'ready' ? colors.onDeviceSurface : colors.fillQuiet,
        },
      ]}>
      {input === undefined ? (
        <Refusal
          purpose={purpose}
          issue={issue}
        />
      ) : (
        <Status
          purpose={purpose}
          state={state}
          onCancel={() => {
            act((request) => {
              request.cancel();
            });
          }}
        />
      )}
      <View style={styles.row}>
        {state.kind === 'ready' ? (
          <Action
            label={t(`assistance.${apply}`)}
            accessibilityLabel={t(`assistance.${apply}Label`)}
            onPress={() => {
              act(() => {
                onApply(state.text);
              });
            }}
          />
        ) : null}
        {finished(state) && canRetryAssistance(state) ? (
          <Action
            label={t('common.retry')}
            accessibilityLabel={t('assistance.retryLabel')}
            onPress={() => {
              act((request, captured) => {
                void request.start(captured);
              });
            }}
          />
        ) : null}
        <Action
          label={t('assistance.keepOriginal')}
          accessibilityLabel={t('assistance.keepOriginalLabel')}
          onPress={() => {
            store.discard();
            onClose();
          }}
        />
      </View>
    </View>
  );
}
