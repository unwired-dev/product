import type {
  CapturedDraftText,
  DetailChange,
  DetailCheck,
  DraftAssistance as DraftAssistanceStore,
  DraftAssistanceInput,
  DraftAssistanceState,
  NativeAssistance,
} from '@private-email/mail-core/assistance';

import {
  canRetryAssistance,
  checkDetails,
  createDraftAssistance,
  isTextTool,
} from '@private-email/mail-core/assistance';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Action } from './action.tsx';
import { OnDeviceMarker, SFSymbol, useOutcomeAnnouncement } from './design.tsx';
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
  note: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  noteText: { ...textStyles.subheadline, flex: 1 },
  table: {
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.xs,
    borderRadius: radius.row,
  },
  tableRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.s,
    paddingVertical: spacing.s,
  },
  heading: { ...textStyles.subheadline, fontWeight: '600' },
  name: { ...textStyles.subheadline, fontWeight: '600', flex: 2 },
  value: { ...textStyles.body, flex: 3 },
  status: { ...textStyles.subheadline, fontWeight: '600', flex: 2 },
});

type Purpose = DraftAssistanceInput['purpose'];

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
  let refusal = t('assistance.failed');
  if (purpose === 'generate') {
    // A prompt has no images, so it is refused only for its length.
    if (issue !== undefined) {
      refusal = t('assistance.generateTooLong');
    }
  } else if (issue !== undefined) {
    refusal = t(
      `assistance.${purpose}${issue === 'inline-image' ? 'HasImage' : 'TooLong'}`,
    );
  }
  useOutcomeAnnouncement(refusal, false);
  return (
    <Text
      selectable
      accessibilityRole="alert"
      style={[styles.secondary, { color: colors.textSecondary }]}>
      {refusal}
    </Text>
  );
}

// An icon and a line of small secondary text below a Writing tools result.
function Note({
  icon,
  children,
}: {
  readonly icon: string;
  readonly children: string;
}) {
  const colors = usePalette();
  return (
    <View style={styles.note}>
      <SFSymbol
        name={icon}
        size={12}
        color={colors.textSecondary}
      />
      <Text
        selectable
        style={[styles.noteText, { color: colors.textSecondary }]}>
        {children}
      </Text>
    </View>
  );
}

const statusOf = ({ kind, status }: DetailChange) => {
  if (status === 'changed' && (kind === 'link' || kind === 'date')) {
    return kind === 'link' ? 'linkChanged' : 'dateChanged';
  }
  return status;
};

// The details a Writing tools result changed, removed or added, side by side with the original,
// and those it kept. The check compares details only, which the closing note says every time.
function Checks({ check }: { readonly check: DetailCheck }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const none = t('assistance.noDetail');
  const name = ({ kind, label }: DetailChange) =>
    label === undefined
      ? t(`assistance.detail.${kind}`)
      : t('assistance.detailNamed', {
          detail: t(`assistance.detail.${kind}`),
          text: label,
        });
  return (
    <>
      {check.changes.length > 0 ? (
        <>
          <View style={styles.note}>
            <SFSymbol
              name="exclamationmark.triangle.fill"
              size={12}
              color={colors.statusWarning}
            />
            <Text
              selectable
              style={[styles.title, { color: colors.textPrimary }]}>
              {t('assistance.detailsDiffer', { count: check.changes.length })}
            </Text>
          </View>
          <View
            style={[styles.table, { backgroundColor: colors.surfaceContent }]}>
            <View
              accessibilityElementsHidden
              importantForAccessibility="no-hide-descendants"
              style={styles.tableRow}>
              <Text style={[styles.name, { color: colors.textSecondary }]}>
                {t('assistance.detailColumn')}
              </Text>
              <Text
                style={[
                  styles.value,
                  styles.heading,
                  { color: colors.textSecondary },
                ]}>
                {t('assistance.originalColumn')}
              </Text>
              <Text
                style={[
                  styles.value,
                  styles.heading,
                  { color: colors.textSecondary },
                ]}>
                {t('assistance.resultColumn')}
              </Text>
              <View style={styles.status} />
            </View>
            {check.changes.map((change, index) => (
              <View
                // Changes have no identity of their own; the list is rebuilt with each result.
                // eslint-disable-next-line react/no-array-index-key
                key={index}
                accessible
                accessibilityLabel={t('assistance.detailRow', {
                  detail: name(change),
                  original: change.original ?? none,
                  result: change.result ?? none,
                  status: t(`assistance.detailStatus.${statusOf(change)}`),
                })}
                style={[
                  styles.tableRow,
                  {
                    borderTopWidth: StyleSheet.hairlineWidth,
                    borderTopColor: colors.separator,
                  },
                ]}>
                <Text style={[styles.name, { color: colors.textSecondary }]}>
                  {name(change)}
                </Text>
                <Text style={[styles.value, { color: colors.textPrimary }]}>
                  {change.original ?? none}
                </Text>
                <Text style={[styles.value, { color: colors.textPrimary }]}>
                  {change.result ?? none}
                </Text>
                <Text style={[styles.status, { color: colors.statusWarning }]}>
                  {t(`assistance.detailStatus.${statusOf(change)}`)}
                </Text>
              </View>
            ))}
          </View>
        </>
      ) : null}
      {check.kept.length > 0 || check.changes.length === 0 ? (
        <Note icon="text.badge.checkmark">
          {check.kept.length > 0
            ? t('assistance.detailsKept', { details: check.kept.join(' · ') })
            : t('assistance.noDetails')}
        </Note>
      ) : null}
      <Note icon="info.circle">{t('assistance.detailsOnly')}</Note>
    </>
  );
}

// Progress with Cancel, the finished result, or why there is none.
function Status({
  purpose,
  state,
  check,
  onCancel,
}: {
  readonly purpose: Purpose;
  readonly state: DraftAssistanceState;
  readonly check: DetailCheck | undefined;
  readonly onCancel: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const failure =
    !finished(state) || state.kind === 'ready'
      ? undefined
      : t(
          `assistance.${state.kind === 'unavailable' ? state.reason : state.kind}`,
        );
  const differ =
    check === undefined || check.changes.length === 0
      ? ''
      : `\n${t('assistance.detailsDiffer', { count: check.changes.length })}`;
  useOutcomeAnnouncement(
    state.kind === 'ready'
      ? `${t(`assistance.${purpose}Title`)}\n${state.text}${differ}`
      : failure,
    state.kind === 'ready',
  );
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
        {failure}
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
      {check === undefined ? null : <Checks check={check} />}
      <OnDeviceMarker label={t('assistance.disclaimer')} />
    </>
  );
}

// Review of an explicitly requested rewrite, reply suggestion or prompted draft for captured Draft
// text. Opening it is the request. The Draft changes only when the person applies the result; the
// owner then replaces exactly the captured text, or inserts a prompted draft at the caret, as one
// undoable edit. A Writing tools result shows which details of the original it changed. Nothing is
// saved or sent.
export function DraftAssistance({
  native,
  original,
  purpose,
  issue,
  input,
  onApply,
  onClose,
}: {
  readonly native: NativeAssistance;
  readonly original: CapturedDraftText;
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
  const check =
    state.kind === 'ready' && isTextTool(purpose)
      ? checkDetails(original, state.text)
      : undefined;
  const apply = { reply: 'useReply', generate: 'insert' } as const;
  let action: 'useReply' | 'insert' | 'replace' | 'replaceWithChanges' =
    'replace';
  if (purpose === 'reply' || purpose === 'generate') {
    action = apply[purpose];
  } else if (check !== undefined && check.changes.length > 0) {
    action = 'replaceWithChanges';
  }
  // A prompted draft has no original text to keep.
  const close = purpose === 'generate' ? 'discard' : 'keepOriginal';
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
          check={check}
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
            label={t(`assistance.${action}`)}
            accessibilityLabel={t(`assistance.${action}Label`)}
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
          label={t(`assistance.${close}`)}
          accessibilityLabel={t(`assistance.${close}Label`)}
          onPress={() => {
            store.discard();
            onClose();
          }}
        />
      </View>
    </View>
  );
}
