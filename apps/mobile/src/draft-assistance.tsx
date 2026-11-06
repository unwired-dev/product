import type {
  CapturedDraftText,
  DetailChange,
  DetailCheck,
  DraftAssistance as DraftAssistanceStore,
  DraftAssistanceInput,
  DraftAssistanceState,
  NativeAssistance,
  TextTool,
} from '@private-email/mail-core/assistance';

import {
  Host,
  HStack,
  Button as SwiftUIButton,
  Text as SwiftUIText,
  VStack,
} from '@expo/ui/swift-ui';
import {
  buttonStyle,
  controlSize,
  frame,
  accessibilityLabel as spokenLabel,
  tint,
} from '@expo/ui/swift-ui/modifiers';
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
import { ipad } from './inbox-styles.ts';
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
  title: { ...textStyles.subheadline, fontWeight: '600' },
  text: { ...textStyles.reading.body },
  secondary: { ...textStyles.subheadline },
  note: { flexDirection: 'row', alignItems: 'flex-start', gap: spacing.s },
  // Centres a note's symbol on the first line of its footnote text.
  icon: { height: textStyles.footnote.lineHeight, justifyContent: 'center' },
  count: { ...textStyles.footnote, fontWeight: '600', flex: 1 },
  noteText: { ...textStyles.footnote, flex: 1 },
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
  stackedRow: { gap: spacing.xs, paddingVertical: spacing.s },
  line: { flexDirection: 'row', gap: spacing.s },
  heading: { ...textStyles.footnote },
  name: { ...textStyles.footnote, fontWeight: '600', flex: 2 },
  value: { ...textStyles.reading.body, flex: 3 },
  status: { ...textStyles.footnote, fontWeight: '600', flex: 2 },
  trailing: { flex: 0, flexShrink: 1, textAlign: 'right' },
  buttons: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
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
      <View style={styles.icon}>
        <SFSymbol
          name={icon}
          size={12}
          color={colors.textSecondary}
        />
      </View>
      <Text
        selectable
        style={[styles.noteText, { color: colors.textSecondary }]}>
        {children}
      </Text>
    </View>
  );
}

const statusOf = ({ kind, status }: DetailChange) => {
  if (status === 'changed' && kind === 'link') {
    return 'linkChanged';
  }
  return status === 'uncertain' ? (`uncertain.${kind}` as const) : status;
};

// The details a Writing tools result changed, removed or added, compared with the original, and
// those it kept. The check compares details only, which the closing note says every time.
function Checks({ check }: { readonly check: DetailCheck }) {
  // iPhone stacks each compared detail; iPad sets the comparison out as a table.
  const stacked = !ipad;
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
  const divider = {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  };
  return (
    <>
      {check.changes.length > 0 ? (
        <>
          <View style={styles.note}>
            <View style={styles.icon}>
              <SFSymbol
                name="exclamationmark.triangle.fill"
                size={12}
                color={colors.statusWarning}
              />
            </View>
            <Text
              selectable
              style={[styles.count, { color: colors.textPrimary }]}>
              {t('assistance.detailsDiffer', { count: check.changes.length })}
            </Text>
          </View>
          <View
            style={[styles.table, { backgroundColor: colors.surfaceContent }]}>
            <View
              accessibilityElementsHidden
              importantForAccessibility="no-hide-descendants"
              style={styles.tableRow}>
              {stacked ? (
                <Text style={[styles.heading, { color: colors.textSecondary }]}>
                  {t('assistance.comparison')}
                </Text>
              ) : (
                <>
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
                </>
              )}
            </View>
            {check.changes.map((change, index) => {
              const original = change.original ?? none;
              const result = change.result ?? none;
              const status = (
                <Text
                  style={[
                    styles.status,
                    stacked && styles.trailing,
                    { color: colors.statusWarning },
                  ]}>
                  {t(`assistance.detailStatus.${statusOf(change)}`)}
                </Text>
              );
              return (
                <View
                  // Changes have no identity of their own; the list is rebuilt with each result.
                  // eslint-disable-next-line react/no-array-index-key
                  key={index}
                  accessible
                  accessibilityLabel={t('assistance.detailRow', {
                    detail: name(change),
                    original,
                    result,
                    status: t(`assistance.detailStatus.${statusOf(change)}`),
                  })}
                  // iPhone's comparison line needs no rule above the first row; iPad's header does.
                  style={[
                    stacked ? styles.stackedRow : styles.tableRow,
                    (!stacked || index > 0) && divider,
                  ]}>
                  {stacked ? (
                    <>
                      <View style={styles.line}>
                        <Text
                          style={[
                            styles.name,
                            { color: colors.textSecondary },
                          ]}>
                          {name(change)}
                        </Text>
                        {status}
                      </View>
                      <Text
                        style={[styles.text, { color: colors.textPrimary }]}>
                        {t('assistance.detailChange', { original, result })}
                      </Text>
                    </>
                  ) : (
                    <>
                      <Text
                        style={[styles.name, { color: colors.textSecondary }]}>
                        {name(change)}
                      </Text>
                      <Text
                        style={[styles.value, { color: colors.textPrimary }]}>
                        {original}
                      </Text>
                      <Text
                        style={[styles.value, { color: colors.textPrimary }]}>
                        {result}
                      </Text>
                      {status}
                    </>
                  )}
                </View>
              );
            })}
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
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
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
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {failure}
      </Text>
    );
  }
  return (
    <>
      <Text
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
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('assistance.omitted')}
        </Text>
      ) : null}
      {check === undefined ? null : <Checks check={check} />}
      <OnDeviceMarker label={t('assistance.disclaimer')} />
    </>
  );
}

// Review of an explicitly requested rewrite, reply suggestion or generated draft for captured
// Draft text. Opening it is the request. The Draft changes only when the person applies the
// result; the owner then replaces exactly the captured text, or inserts a generated draft at the
// caret, as one undoable edit. A Writing tools result shows which details of the original it
// changed. Nothing is saved or sent.
export function DraftAssistance({
  native,
  original,
  purpose,
  issue,
  input,
  onApply,
  onClose,
  onPending,
}: {
  readonly native: NativeAssistance;
  readonly original: CapturedDraftText;
  readonly purpose: Purpose;
  // Why the captured text was refused, when the person can act on it.
  readonly issue: CapturedDraftText['issue'];
  readonly input: DraftAssistanceInput | undefined;
  readonly onApply: (replacement: string) => void;
  readonly onClose: () => void;
  // Whether its request is running or its result waits to be used, rather than why there is none.
  readonly onPending?: ((pending: boolean) => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { store, state, act } = useDraftAssistance(native, input);
  const pending =
    input !== undefined && (!finished(state) || state.kind === 'ready');
  useLayoutEffect(() => {
    onPending?.(pending);
  }, [onPending, pending]);
  // iPhone stacks a checked result's buttons; iPad sets them out side by side and wraps any that do
  // not fit a narrow composer.
  const stacked = !ipad;
  const check =
    state.kind === 'ready' && isTextTool(purpose)
      ? checkDetails(original, state.text)
      : undefined;
  const differs = check !== undefined && check.changes.length > 0;
  const verbs = { reply: 'useReply', generate: 'insert' } as const;
  let apply: 'useReply' | 'insert' | 'replace' | 'replaceWithChanges' = differs
    ? 'replaceWithChanges'
    : 'replace';
  if (purpose === 'reply' || purpose === 'generate') {
    apply = verbs[purpose];
  }
  const close = purpose === 'generate' ? 'discard' : 'keepOriginal';
  // A checked result offers native push buttons, as its frames do: Keep original carries the
  // accent fill when details differ, and the rewrite when none do. On iPhone each button takes the
  // width it is given.
  const control = ({
    label,
    accessibilityLabel,
    onPress,
    main = false,
  }: Readonly<{
    label: string;
    accessibilityLabel: string;
    onPress: () => void;
    main?: boolean;
  }>) =>
    check === undefined ? (
      <Action
        label={label}
        accessibilityLabel={accessibilityLabel}
        onPress={onPress}
      />
    ) : (
      <SwiftUIButton
        onPress={onPress}
        modifiers={[
          buttonStyle(main ? 'borderedProminent' : 'bordered'),
          controlSize('large'),
          tint(main ? colors.accentFill : colors.textPrimary),
          spokenLabel(accessibilityLabel),
        ]}>
        <SwiftUIText modifiers={stacked ? [frame({ maxWidth: Infinity })] : []}>
          {label}
        </SwiftUIText>
      </SwiftUIButton>
    );
  const applyAction =
    state.kind === 'ready'
      ? control({
          label: t(`assistance.${apply}`),
          accessibilityLabel: t(`assistance.${apply}Label`),
          onPress: () => {
            act(() => {
              onApply(state.text);
            });
          },
          main: !differs,
        })
      : null;
  const retryAction =
    finished(state) && canRetryAssistance(state)
      ? control({
          label: t('common.retry'),
          accessibilityLabel: t('assistance.retryLabel'),
          onPress: () => {
            act((request, captured) => {
              void request.start(captured);
            });
          },
        })
      : null;
  const closeAction = control({
    label: t(`assistance.${close}`),
    accessibilityLabel: t(`assistance.${close}Label`),
    onPress: () => {
      store.discard();
      onClose();
    },
    main: differs,
  });
  let actions = (
    <View style={styles.row}>
      {applyAction}
      {retryAction}
      {closeAction}
    </View>
  );
  if (check !== undefined) {
    actions = stacked ? (
      <Host matchContents={{ vertical: true }}>
        <VStack spacing={spacing.s}>
          {applyAction}
          <HStack spacing={spacing.s}>
            {closeAction}
            {retryAction}
          </HStack>
        </VStack>
      </Host>
    ) : (
      <View style={styles.buttons}>
        {applyAction && <Host matchContents>{applyAction}</Host>}
        <Host matchContents>{closeAction}</Host>
        {retryAction && <Host matchContents>{retryAction}</Host>}
      </View>
    );
  }
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
      {actions}
    </View>
  );
}

// Says that a Writing tools result was dropped because the Draft changed while it was made or
// shown. Rewrite again starts the tool over from the current text. iPhone gives its two buttons
// equal halves of the card; iPad sets them out at their own width.
export function DroppedAssistance({
  purpose,
  onRewrite,
  onClose,
}: {
  readonly purpose: TextTool;
  readonly onRewrite: () => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const message = t('assistance.dropped');
  useOutcomeAnnouncement(message, false);
  const button = (
    label: string,
    accessibilityLabel: string,
    onPress: () => void,
  ) => (
    <SwiftUIButton
      onPress={onPress}
      modifiers={[
        buttonStyle('bordered'),
        controlSize('large'),
        tint(colors.textPrimary),
        spokenLabel(accessibilityLabel),
      ]}>
      <SwiftUIText modifiers={ipad ? [] : [frame({ maxWidth: Infinity })]}>
        {label}
      </SwiftUIText>
    </SwiftUIButton>
  );
  const rewrite = button(
    t('assistance.rewriteAgain'),
    t('assistance.rewriteAgainLabel'),
    onRewrite,
  );
  const close = button(
    t('assistance.close'),
    t('assistance.closeLabel'),
    onClose,
  );
  return (
    <View
      accessibilityLabel={t(`assistance.${purpose}Title`)}
      style={[
        styles.panel,
        {
          borderColor: colors.separator,
          backgroundColor: colors.onDeviceSurface,
        },
      ]}>
      <OnDeviceMarker
        label={t('assistance.droppedMarker', {
          tool: t(`assistance.${purpose}Title`),
        })}
      />
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.text, { color: colors.textPrimary }]}>
        {message}
      </Text>
      {ipad ? (
        <View style={styles.buttons}>
          <Host matchContents>{rewrite}</Host>
          <Host matchContents>{close}</Host>
        </View>
      ) : (
        <Host matchContents={{ vertical: true }}>
          <HStack spacing={spacing.s}>
            {rewrite}
            {close}
          </HStack>
        </Host>
      )}
    </View>
  );
}
