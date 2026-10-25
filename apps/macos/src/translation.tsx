import type { ReadableBody } from '@private-email/mail-core/message-body';
import type {
  NativeTranslation,
  Translation as TranslationStore,
  TranslationInput,
  ReaderText,
  TranslationLanguage,
  TranslationState,
} from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';
import type { TurboModule } from 'react-native';

import { draftTextIssue } from '@private-email/mail-core/assistance';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  canRetryTranslation,
  createTranslation,
  draftTranslationInput,
  hasTranslatableText,
  messageTranslationInput,
  readerText,
  translationLanguages,
} from '@private-email/mail-core/translation';
import {
  createContext,
  use,
  useEffect,
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

import type { PopUpItem } from './composer-controls.tsx';

import { Action } from './action.tsx';
import { PopUp } from './composer-controls.tsx';
import { OnDeviceMarker, SFSymbol, useOutcomeAnnouncement } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  panel: {
    width: '100%',
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
  banner: {
    width: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.card,
  },
  bannerText: { ...textStyles.body, flex: 1 },
  title: { ...textStyles.bodyEmphasized },
  text: { ...textStyles.reading.body },
  secondary: { ...textStyles.body },
});

interface TranslationModule extends TurboModule, NativeTranslation {}

const native = () =>
  TurboModuleRegistry.getEnforcing<TranslationModule>('UnwiredAssistance');

// The host's on-device Apple Translation; Mock Mail Session tests substitute their own.
export const nativeTranslation: NativeTranslation = {
  translationLanguages: () => native().translationLanguages(),
  translate: (request, input, target) =>
    native().translate(request, input, target),
  cancel: (request) => native().cancel(request),
};

// Translation while Mail Assistance Enablement permits On-Device Mail Assistance; without it
// translation is hidden and nothing reaches Apple Translation.
export const TranslationContext = createContext<NativeTranslation | undefined>(
  undefined,
);

// Languages are a device property, not mail, so one successful list serves every reader.
const languageLists = new WeakMap<
  NativeTranslation,
  Promise<readonly TranslationLanguage[] | undefined>
>();

// Language lists outlive any one control, so no request needs retiring with it.
const keepLanguages = () => undefined;

// A failed list is not an empty one: only the failure offers Try Again.
type Languages =
  | readonly TranslationLanguage[]
  | 'loading'
  | 'unavailable'
  | 'failed';

function useLanguages(translation: NativeTranslation | undefined) {
  const enabled = useMailAssistanceLifetime(keepLanguages);
  const [languages, setLanguages] = useState<Languages>('loading');
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (translation === undefined || !enabled()) {
      return;
    }
    let current = true;
    let list = languageLists.get(translation);
    if (list === undefined) {
      list = translationLanguages(translation);
      languageLists.set(translation, list);
    }
    const load = async (pending: typeof list) => {
      const loaded = await pending;
      const usable = loaded !== undefined && loaded.length > 0;
      if (!usable) {
        // Try Again or a later control asks the device again.
        languageLists.delete(translation);
      }
      if (!current) {
        return;
      }
      if (loaded === undefined) {
        setLanguages('failed');
      } else {
        setLanguages(usable ? loaded : 'unavailable');
      }
    };
    void load(list);
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react/exhaustive-effect-dependencies -- Try Again asks the device again.
  }, [translation, enabled, attempt]);
  const reload = () => {
    setLanguages('loading');
    setAttempt((count) => count + 1);
  };
  return [languages, reload] as const;
}

// The device's target languages as native menu items, the chosen one checked. The list and its
// Try Again come back too, so the reader can show a failure in place of its menu. Only a failure
// after Try Again is announced, so opening a message or Draft stays quiet.
function useLanguageMenu(
  translation: NativeTranslation | undefined,
  selected: TranslationLanguage | undefined,
  choose: (language: TranslationLanguage) => void,
) {
  const { t } = useLocalization();
  const [languages, reload] = useLanguages(translation);
  const [retried, setRetried] = useState(false);
  useOutcomeAnnouncement(
    retried && languages === 'failed'
      ? t('translation.languagesFailed')
      : undefined,
    false,
  );
  const retry = () => {
    setRetried(true);
    reload();
  };
  const items = (): PopUpItem[] => {
    if (languages === 'failed') {
      return [
        {
          key: 'languages',
          title: t('translation.languagesFailed'),
          disabled: true,
        },
        {
          key: 'reload',
          title: t('translation.tryAgain'),
          accessibilityLabel: t('translation.tryAgainLabel'),
          run: retry,
        },
      ];
    }
    if (typeof languages === 'string') {
      return [
        {
          key: 'languages',
          title: t(
            languages === 'loading'
              ? 'translation.loading'
              : 'translation.noLanguages',
          ),
          disabled: true,
        },
      ];
    }
    return languages.map((language) => ({
      key: `language:${language.code}`,
      title: language.name,
      accessibilityLabel: t('translation.targetLabel', {
        language: language.name,
      }),
      checked: selected?.code === language.code,
      run: () => {
        choose(language);
      },
    }));
  };
  return { languages, retried, retry, items: items() };
}

// The target language menu items. Nothing is translated until one is chosen.
export function useTargetLanguages(
  translation: NativeTranslation | undefined,
  selected: TranslationLanguage | undefined,
  choose: (language: TranslationLanguage) => void,
): PopUpItem[] {
  return useLanguageMenu(translation, selected, choose).items;
}

const idle: TranslationState = { kind: 'idle' };

// One mounted owner's translation store. Unmounting cancels it and forgets its result before
// passive effects, and only the committed store may start the native request.
function useTranslation(
  translation: NativeTranslation,
  input: TranslationInput | undefined,
  isCurrent: () => boolean = () => true,
) {
  const [owner, setOwner] = useState(() => ({
    translation,
    store: createTranslation(translation),
  }));
  let { store } = owner;
  if (owner.translation !== translation) {
    store = createTranslation(translation);
    setOwner({ translation, store });
  }
  const enabled = useMailAssistanceLifetime(() => {
    store.discard();
  });
  const committed = useRef<TranslationStore>(undefined);
  useLayoutEffect(() => {
    committed.current = store;
    return () => {
      committed.current = undefined;
      store.discard();
    };
  }, [store]);
  const state = useSyncExternalStore(store.subscribe, () =>
    input === undefined ? idle : store.getSnapshot(input),
  );
  const current = () => committed.current === store && enabled() && isCurrent();
  const start = (next: TranslationInput | undefined) => {
    if (next !== undefined && current()) {
      void store.start(next);
    }
  };
  const currentResult = () =>
    current() && input !== undefined && store.getSnapshot(input) === state;
  const retry = () => {
    if (currentResult()) {
      start(input);
    }
  };
  const cancel = () => {
    if (currentResult()) {
      store.cancel();
    }
  };
  const accept = (apply: (text: string) => void) => {
    if (currentResult() && state.kind === 'ready') {
      apply(state.text);
    }
  };
  return {
    native: translation,
    enabled,
    store,
    state,
    start,
    retry,
    cancel,
    accept,
  };
}

// The language named by its code, as the device lists it.
const languageName = (languages: Languages, code: string) =>
  typeof languages === 'string'
    ? code
    : (languages.find((language) => language.code === code)?.name ?? code);

// A finished translation, or why there is none.
function Outcome({
  state,
  source,
  target,
}: {
  readonly state: Exclude<TranslationState, { kind: 'idle' | 'translating' }>;
  // The names of the language the device identified and of the chosen one.
  readonly source: string;
  readonly target: string;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const failure =
    state.kind === 'ready'
      ? undefined
      : t(
          `translation.${state.kind === 'unavailable' ? state.reason : state.kind}`,
        );
  useOutcomeAnnouncement(
    state.kind === 'ready'
      ? `${t('translation.title', { language: target })}\n${state.text}`
      : failure,
    state.kind === 'ready',
  );
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
        {t('translation.title', { language: target })}
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
          {t('translation.omitted')}
        </Text>
      ) : null}
      <OnDeviceMarker label={t('translation.disclaimer', { source, target })} />
    </>
  );
}

// The progress and outcome for one chosen target language, above the owner's actions.
function TranslationPanel({
  label,
  target,
  translation,
  actions,
}: {
  readonly label: string;
  readonly target: TranslationLanguage;
  readonly translation: ReturnType<typeof useTranslation>;
  readonly actions: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [languages] = useLanguages(translation.native);
  const { state, retry, cancel } = translation;
  return (
    <View
      accessibilityLabel={label}
      style={[
        styles.panel,
        { borderColor: colors.separator, backgroundColor: colors.fillQuiet },
      ]}>
      {state.kind === 'translating' ? (
        <View style={styles.row}>
          <ActivityIndicator accessibilityLabel={t('translation.progress')} />
          <Text
            selectable
            style={[styles.secondary, { color: colors.textSecondary }]}>
            {t('translation.translating')}
          </Text>
          <Action
            label={t('common.cancel')}
            accessibilityLabel={t('translation.cancelLabel')}
            onPress={() => {
              cancel();
            }}
          />
        </View>
      ) : null}
      {state.kind === 'idle' || state.kind === 'translating' ? null : (
        <Outcome
          state={state}
          source={
            state.kind === 'ready' ? languageName(languages, state.source) : ''
          }
          target={target.name}
        />
      )}
      <View style={styles.row}>
        {state.kind !== 'idle' &&
        state.kind !== 'translating' &&
        state.kind !== 'ready' &&
        canRetryTranslation(state) ? (
          <Action
            label={t('common.retry')}
            accessibilityLabel={t('translation.retryLabel')}
            onPress={() => {
              retry();
            }}
          />
        ) : null}
        {actions}
      </View>
    </View>
  );
}

// A language list the device could not give, in place of the Translate pull-down, which stays
// while Try Again asks the device again.
function LanguagesFailed({
  loading,
  onRetry,
}: {
  readonly loading: boolean;
  readonly onRetry: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={[styles.banner, { backgroundColor: colors.fillQuiet }]}>
      <SFSymbol
        name="character.bubble"
        color={colors.onDeviceInk}
      />
      <Text
        selectable
        style={[styles.bannerText, { color: colors.textPrimary }]}>
        {t(loading ? 'translation.loading' : 'translation.languagesFailed')}
      </Text>
      {loading ? (
        <ActivityIndicator
          accessibilityLabel={t('translation.loading')}
          size="small"
          color={colors.textSecondary}
        />
      ) : null}
      <Action
        label={t('translation.tryAgain')}
        accessibilityLabel={t('translation.tryAgainLabel')}
        onPress={onRetry}
        disabled={loading}
        variant="banner"
      />
    </View>
  );
}

function ReaderTranslation({
  translator,
  body,
}: {
  readonly translator: NativeTranslation;
  readonly body: ReaderText;
}) {
  const { t } = useLocalization();
  // Each shown translation owns its queued native input; Show Original retires it before rendering.
  const session = useRef(0);
  const generation = session.current;
  const [target, setTarget] = useState<TranslationLanguage>();
  const input =
    target === undefined
      ? undefined
      : messageTranslationInput(body, target.code);
  const current = () => generation === session.current;
  const translation = useTranslation(translator, input, current);
  const menu = useLanguageMenu(translator, target, (language) => {
    if (!current()) {
      return;
    }
    setTarget(language);
    translation.start(messageTranslationInput(body, language.code));
  });
  const retrying = menu.retried && menu.languages === 'loading';
  if (target === undefined && (menu.languages === 'failed' || retrying)) {
    return (
      <LanguagesFailed
        loading={retrying}
        onRetry={() => {
          menu.retry();
        }}
      />
    );
  }
  return (
    <>
      {/* A pull-down until a language is chosen, then a pop-up naming it. */}
      <PopUp
        icon="translate"
        pullsDown={target === undefined}
        label={target === undefined ? t('translation.translate') : target.name}
        accessibilityLabel={
          target === undefined
            ? t('translation.translateMessageLabel')
            : t('translation.targetLabel', { language: target.name })
        }
        items={[
          {
            key: 'heading',
            title: t('translation.menuHeading'),
            disabled: true,
          },
          ...menu.items,
        ]}
      />
      {target === undefined ? null : (
        <TranslationPanel
          label={t('translation.messageRegion')}
          target={target}
          translation={translation}
          actions={
            <Action
              label={t('translation.showOriginal')}
              accessibilityLabel={t('translation.showOriginalLabel')}
              onPress={() => {
                if (!current()) {
                  return;
                }
                session.current += 1;
                translation.store.discard();
                setTarget(undefined);
              }}
            />
          }
        />
      )}
    </>
  );
}

// A counter that advances whenever any of `deps` changes identity, during the same render.
function useGeneration(deps: readonly unknown[]) {
  const [owner, setOwner] = useState({ deps, generation: 0 });
  if (
    deps.length !== owner.deps.length ||
    deps.some((dep, index) => dep !== owner.deps[index])
  ) {
    const next = { deps, generation: owner.generation + 1 };
    setOwner(next);
    return next.generation;
  }
  return owner.generation;
}

// An explicitly requested on-device translation of the already-local message text in the reader.
// It is a read-only, ephemeral preview beside the unchanged message: never saved or written to mail.
export function MessageTranslation({
  source,
  id,
  body,
}: {
  // The mailbox store the message belongs to; with the id, it identifies the translated message.
  readonly source: object;
  readonly id: string;
  readonly body: ReadableBody | string;
}) {
  const translation = use(TranslationContext);
  const text = useMemo(() => readerText(body), [body]);
  // Another message, mailbox, account or text replaces the translation before rendering, so a
  // result for the previous one is never shown; unmounting cancels and forgets it.
  const generation = useGeneration([translation, source, id, text.text]);
  // Turning Mail Assistance Enablement off unmounts it, which cancels and forgets the translation.
  if (translation === undefined || !hasTranslatableText(text.text)) {
    return null;
  }
  return (
    <ReaderTranslation
      key={generation}
      translator={translation}
      body={text}
    />
  );
}

// Review of a translation of captured Draft text into the language chosen with it, started at
// once. The Draft changes only when the person applies it; the owner then replaces exactly the
// captured selection as one undoable edit.
export function DraftTranslation({
  translator,
  text,
  target,
  onApply,
  onClose,
}: {
  readonly translator: NativeTranslation;
  readonly text: string;
  readonly target: TranslationLanguage;
  readonly onApply: (translated: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const input = useMemo(
    () => draftTranslationInput(text, target.code),
    [text, target.code],
  );
  const translation = useTranslation(translator, input);
  const { store, enabled, state } = translation;
  useLayoutEffect(() => {
    if (input !== undefined && enabled()) {
      void store.start(input);
    }
  }, [store, input, enabled]);
  const keep = (
    <Action
      label={t('translation.keepOriginal')}
      accessibilityLabel={t('translation.keepOriginalLabel')}
      onPress={() => {
        store.discard();
        onClose();
      }}
    />
  );
  const issue = draftTextIssue(text);
  const refusal =
    issue === undefined
      ? undefined
      : t(
          issue === 'inline-image'
            ? 'translation.selectionHasImage'
            : 'translation.selectionTooLong',
        );
  useOutcomeAnnouncement(refusal, false);
  if (issue !== undefined) {
    return (
      <View
        accessibilityLabel={t('translation.draftRegion')}
        style={[
          styles.panel,
          { borderColor: colors.separator, backgroundColor: colors.fillQuiet },
        ]}>
        <Text
          selectable
          accessibilityRole="alert"
          style={[styles.secondary, { color: colors.textSecondary }]}>
          {refusal}
        </Text>
        {keep}
      </View>
    );
  }
  return (
    <TranslationPanel
      label={t('translation.draftRegion')}
      target={target}
      translation={translation}
      actions={
        <>
          {state.kind === 'ready' ? (
            <Action
              label={t('translation.replace')}
              accessibilityLabel={t('translation.replaceLabel')}
              onPress={() => {
                translation.accept(onApply);
              }}
            />
          ) : null}
          {keep}
        </>
      }
    />
  );
}
