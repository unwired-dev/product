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

import { spacing } from '@private-email/mail-core/theme';
import {
  canRetryTranslation,
  createTranslation,
  draftTranslationInput,
  draftTranslationIssue,
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
  Pressable,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  panel: {
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
  options: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.small },
  option: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.small,
    borderWidth: 1,
    borderRadius: 8,
  },
  title: { fontSize: 15, fontWeight: '600' },
  text: { fontSize: 16, lineHeight: 24 },
  secondary: { fontSize: 14, lineHeight: 21 },
});

interface TranslationModule extends TurboModule, NativeTranslation {}

const native = () =>
  TurboModuleRegistry.getEnforcing<TranslationModule>('UnwiredAssistance');

// The host's on-device Apple Translation; Mock Mail Session tests substitute their own.
export const TranslationContext = createContext<NativeTranslation>({
  translationLanguages: () => native().translationLanguages(),
  translate: (request, input, target) =>
    native().translate(request, input, target),
  cancel: (request) => native().cancel(request),
});

// Languages are a device property, not mail, so one successful list serves every reader.
const languageLists = new WeakMap<
  NativeTranslation,
  Promise<readonly TranslationLanguage[] | undefined>
>();

function useLanguages(translation: NativeTranslation) {
  const [languages, setLanguages] = useState<
    readonly TranslationLanguage[] | 'loading' | 'unavailable'
  >('loading');
  useEffect(() => {
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
        // A later panel asks the device again.
        languageLists.delete(translation);
      }
      if (current) {
        setLanguages(usable ? loaded : 'unavailable');
      }
    };
    void load(list);
    return () => {
      current = false;
    };
  }, [translation]);
  return languages;
}

// The explicit choice of target language. Nothing is translated until one is chosen.
function TargetLanguages({
  languages,
  selected,
  onSelect,
}: {
  readonly languages: ReturnType<typeof useLanguages>;
  readonly selected: TranslationLanguage | undefined;
  readonly onSelect: (language: TranslationLanguage) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (languages === 'loading') {
    return <ActivityIndicator accessibilityLabel={t('translation.loading')} />;
  }
  if (languages === 'unavailable') {
    return (
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.secondary }]}>
        {t('translation.noLanguages')}
      </Text>
    );
  }
  return (
    <View
      accessibilityLabel={t('translation.target')}
      accessibilityRole="radiogroup"
      style={styles.options}>
      {languages.map((language) => (
        <Pressable
          key={language.code}
          accessibilityRole="radio"
          accessibilityLabel={t('translation.targetLabel', {
            language: language.name,
          })}
          accessibilityState={{ checked: selected?.code === language.code }}
          onPress={() => {
            onSelect(language);
          }}
          style={[
            styles.option,
            {
              borderColor:
                selected?.code === language.code
                  ? colors.accent
                  : colors.separator,
            },
          ]}>
          <Text style={[styles.secondary, { color: colors.foreground }]}>
            {selected?.code === language.code ? '✓ ' : ''}
            {language.name}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

const idle: TranslationState = { kind: 'idle' };

// One mounted owner's translation store. Unmounting cancels it and forgets its result before
// passive effects, and only the committed store may start the native request.
function useTranslation(
  input: TranslationInput | undefined,
  isCurrent: () => boolean = () => true,
) {
  const translation = use(TranslationContext);
  const [owner, setOwner] = useState(() => ({
    translation,
    store: createTranslation(translation),
  }));
  let { store } = owner;
  if (owner.translation !== translation) {
    store = createTranslation(translation);
    setOwner({ translation, store });
  }
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
  const current = () => committed.current === store && isCurrent();
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
  return { store, state, start, retry, cancel, accept };
}

// The language named by its code, as the device lists it.
const languageName = (
  languages: ReturnType<typeof useLanguages>,
  code: string,
) =>
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
  if (state.kind !== 'ready') {
    return (
      <Text
        selectable
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.secondary }]}>
        {t(
          `translation.${state.kind === 'unavailable' ? state.reason : state.kind}`,
        )}
      </Text>
    );
  }
  return (
    <>
      <Text
        selectable
        accessibilityRole="header"
        style={[styles.title, { color: colors.foreground }]}>
        {t('translation.title', { language: target })}
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
          {t('translation.omitted')}
        </Text>
      ) : null}
      <Text
        selectable
        style={[styles.secondary, { color: colors.secondary }]}>
        {t('translation.disclaimer', { source, target })}
      </Text>
    </>
  );
}

// The language choice, progress and outcome for one captured input, above the owner's actions.
function TranslationPanel({
  label,
  target,
  onTarget,
  translation,
  actions,
}: {
  readonly label: string;
  readonly target: TranslationLanguage | undefined;
  readonly onTarget: (language: TranslationLanguage) => void;
  readonly translation: ReturnType<typeof useTranslation>;
  readonly actions: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const languages = useLanguages(use(TranslationContext));
  const { state, retry, cancel } = translation;
  return (
    <View
      accessibilityLabel={label}
      style={[styles.panel, { borderColor: colors.separator }]}>
      <TargetLanguages
        languages={languages}
        selected={target}
        onSelect={onTarget}
      />
      {state.kind === 'translating' ? (
        <View style={styles.row}>
          <ActivityIndicator accessibilityLabel={t('translation.progress')} />
          <Text
            selectable
            style={[styles.secondary, { color: colors.secondary }]}>
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
          target={target?.name ?? ''}
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

function ReaderTranslation({ body }: { readonly body: ReaderText }) {
  const { t } = useLocalization();
  // Each open panel owns its queued native input; dismissal retires it before rendering.
  const session = useRef(0);
  const generation = session.current;
  const [open, setOpen] = useState<number>();
  const [target, setTarget] = useState<TranslationLanguage>();
  const input =
    target === undefined
      ? undefined
      : messageTranslationInput(body, target.code);
  const current = () => open !== undefined && open === session.current;
  const translation = useTranslation(input, current);
  if (open === undefined) {
    return (
      <View style={styles.row}>
        <Action
          label={t('translation.translate')}
          accessibilityLabel={t('translation.translateMessageLabel')}
          onPress={() => {
            if (generation !== session.current) {
              return;
            }
            session.current += 1;
            setOpen(session.current);
          }}
        />
      </View>
    );
  }
  return (
    <TranslationPanel
      label={t('translation.messageRegion')}
      target={target}
      onTarget={(language) => {
        if (!current()) {
          return;
        }
        setTarget(language);
        translation.start(messageTranslationInput(body, language.code));
      }}
      translation={translation}
      actions={
        <Action
          label={t('translation.dismiss')}
          accessibilityLabel={t('translation.dismissLabel')}
          onPress={() => {
            if (!current()) {
              return;
            }
            session.current += 1;
            translation.store.discard();
            setTarget(undefined);
            setOpen(undefined);
          }}
        />
      }
    />
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
  if (!hasTranslatableText(text.text)) {
    return null;
  }
  return (
    <ReaderTranslation
      key={generation}
      body={text}
    />
  );
}

// Review of a translation of captured Draft text. The Draft changes only when the person applies
// it; the owner then replaces exactly the captured selection as one undoable edit.
export function DraftTranslation({
  text,
  onApply,
  onClose,
}: {
  readonly text: string;
  readonly onApply: (translated: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [target, setTarget] = useState<TranslationLanguage>();
  const input =
    target === undefined ? undefined : draftTranslationInput(text, target.code);
  const translation = useTranslation(input);
  const { state } = translation;
  const keep = (
    <Action
      label={t('translation.keepOriginal')}
      accessibilityLabel={t('translation.keepOriginalLabel')}
      onPress={() => {
        translation.store.discard();
        onClose();
      }}
    />
  );
  const issue = draftTranslationIssue(text);
  if (issue !== undefined) {
    return (
      <View
        accessibilityLabel={t('translation.draftRegion')}
        style={[styles.panel, { borderColor: colors.separator }]}>
        <Text
          selectable
          accessibilityRole="alert"
          style={[styles.secondary, { color: colors.secondary }]}>
          {t(
            issue === 'inline-image'
              ? 'translation.selectionHasImage'
              : 'translation.selectionTooLong',
          )}
        </Text>
        {keep}
      </View>
    );
  }
  return (
    <TranslationPanel
      label={t('translation.draftRegion')}
      target={target}
      onTarget={(language) => {
        setTarget(language);
        translation.start(draftTranslationInput(text, language.code));
      }}
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
