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
import type { StyleProp, TurboModule, ViewStyle } from 'react-native';

import { languages as appLanguages } from '@private-email/localization';
import { draftTextIssue } from '@private-email/mail-core/assistance';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
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
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { Action } from './action.tsx';
import {
  MenuButton,
  OnDeviceMarker,
  SFSymbol,
  useOutcomeAnnouncement,
} from './design.tsx';
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
  menu: { alignSelf: 'flex-start', minHeight: 44 },
  popUp: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
  title: { ...textStyles.subheadline, fontWeight: '600' },
  text: { ...textStyles.reading.body },
  secondary: { ...textStyles.subheadline },
  // The reader's panel is the frames' Translation Banner: the quiet fill without a border. iPad
  // draws it as the iPhone recipe at 1.15×.
  banner: {
    borderWidth: 0,
    gap: 10,
    paddingVertical: spacing.m,
    paddingHorizontal: spacing.l,
  },
  padBanner: {
    gap: 9.2,
    paddingVertical: 9.2,
    paddingHorizontal: 13.8,
    borderRadius: radius.card * 1.15,
  },
  heading: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  // Translate | ⌄: iPhone draws it as a 44pt capsule on the content surface, iPad as plain text
  // beside the panel's symbol.
  split: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    alignItems: 'center',
    minHeight: 44,
  },
  capsule: { borderRadius: 22, borderCurve: 'continuous', overflow: 'hidden' },
  splitHalf: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  divider: { width: 1, height: 18 },
});

const pad = Platform.OS === 'ios' && Platform.isPad;

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

// A failed list is not an empty one: only the failure offers Try Again.
type Languages =
  | readonly TranslationLanguage[]
  | 'loading'
  | 'unavailable'
  | 'failed';

function useLanguages(translation: NativeTranslation, enabled: () => boolean) {
  const [languages, setLanguages] = useState<Languages>('loading');
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!enabled()) {
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
        // Try Again or a later panel asks the device again.
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

// The explicit choice of target language. Nothing is translated until one is chosen.
function TargetLanguages({
  languages,
  reload,
  selected,
  onSelect,
}: {
  readonly languages: Languages;
  readonly reload: () => void;
  readonly selected: TranslationLanguage | undefined;
  readonly onSelect: (language: TranslationLanguage) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // The panel opened at the person's request, so its failure is announced each time it appears.
  useOutcomeAnnouncement(
    languages === 'failed' ? t('translation.languagesFailed') : undefined,
    false,
  );
  if (languages === 'loading') {
    return <ActivityIndicator accessibilityLabel={t('translation.loading')} />;
  }
  if (languages === 'failed') {
    return (
      <View style={styles.row}>
        <Text style={[styles.title, { color: colors.textPrimary }]}>
          {t('translation.languagesFailed')}
        </Text>
        <Action
          label={t('translation.tryAgain')}
          accessibilityLabel={t('translation.tryAgainLabel')}
          onPress={reload}
        />
      </View>
    );
  }
  if (languages === 'unavailable') {
    return (
      <Text
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('translation.noLanguages')}
      </Text>
    );
  }
  // A system menu that starts with no language chosen: opening it neither chooses nor translates.
  return (
    <MenuButton
      accessibilityLabel={t('translation.target')}
      accessibilityValue={
        selected === undefined ? undefined : { text: selected.name }
      }
      sections={[
        {
          items: languages.map((language) => ({
            key: `language:${language.code}`,
            title: language.name,
            symbol: '',
            checked: selected?.code === language.code,
            run: () => {
              onSelect(language);
            },
          })),
        },
      ]}
      style={styles.menu}>
      <View style={styles.popUp}>
        <Text style={[styles.secondary, { color: colors.textPrimary }]}>
          {selected === undefined
            ? t('translation.target')
            : t('translation.targetLabel', { language: selected.name })}
        </Text>
        <SFSymbol
          name="chevron.up.chevron.down"
          size={12}
          color={colors.textSecondary}
        />
      </View>
    </MenuButton>
  );
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
        {t('translation.title', { language: target })}
      </Text>
      <Text
        selectable
        style={[styles.text, { color: colors.textPrimary }]}>
        {state.text}
      </Text>
      {state.omitted ? (
        <Text style={[styles.secondary, { color: colors.textSecondary }]}>
          {t('translation.omitted')}
        </Text>
      ) : null}
      <OnDeviceMarker label={t('translation.disclaimer', { source, target })} />
    </>
  );
}

// The language choice, progress and outcome for one captured input, above the owner's actions.
function TranslationPanel({
  label,
  languages,
  chooser,
  target,
  translation,
  actions,
  style,
}: {
  readonly label: string;
  // The device's language list, which also names a translation's source language.
  readonly languages: Languages;
  readonly chooser: ReactNode;
  readonly target: TranslationLanguage | undefined;
  readonly translation: ReturnType<typeof useTranslation>;
  readonly actions: ReactNode;
  readonly style?: StyleProp<ViewStyle>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { state, retry, cancel } = translation;
  const retryable =
    state.kind !== 'idle' &&
    state.kind !== 'translating' &&
    state.kind !== 'ready' &&
    canRetryTranslation(state);
  return (
    <View
      accessibilityLabel={label}
      style={[
        styles.panel,
        { borderColor: colors.separator, backgroundColor: colors.fillQuiet },
        style,
      ]}>
      {chooser}
      {state.kind === 'translating' ? (
        <View style={styles.row}>
          <ActivityIndicator accessibilityLabel={t('translation.progress')} />
          <Text style={[styles.secondary, { color: colors.textSecondary }]}>
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
      {retryable || actions !== null ? (
        <View style={styles.row}>
          {retryable ? (
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
      ) : null}
    </View>
  );
}

// Whether a device language is the app language, in any region or script.
const isAppLanguage = (code: string, app: string) =>
  code.split('-')[0]?.toLowerCase() === app.split('-')[0]?.toLowerCase();

// The reader's Translate | ⌄. Translate is into the app language and needs no language list; the
// arrow's system menu offers the device's other languages and names the one chosen. A list the
// device could not give takes the arrow's place, and only a failure after Try Again is announced,
// so opening a message stays quiet.
function SplitTranslate({
  languages,
  reload,
  target,
  onTranslate,
  onSelect,
}: {
  readonly languages: Languages;
  readonly reload: () => void;
  readonly target: TranslationLanguage | undefined;
  readonly onTranslate: () => void;
  readonly onSelect: (language: TranslationLanguage) => void;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const [retried, setRetried] = useState(false);
  useOutcomeAnnouncement(
    retried && languages === 'failed'
      ? t('translation.languagesFailed')
      : undefined,
    false,
  );
  if (languages === 'unavailable') {
    return (
      <Text
        accessibilityRole="alert"
        style={[styles.secondary, { color: colors.textSecondary }]}>
        {t('translation.noLanguages')}
      </Text>
    );
  }
  // Another chosen language, which the arrow names.
  const other =
    target === undefined || isAppLanguage(target.code, settings.language)
      ? undefined
      : target;
  const label = [
    pad ? typography.ipadList.body : styles.title,
    { color: pad ? colors.textPrimary : colors.accentInk },
  ];
  const glyph = (
    <SFSymbol
      name="character.bubble"
      size={pad ? 16 : 18}
      color={colors.onDeviceInk}
    />
  );
  const split = (
    <View
      style={[
        styles.split,
        pad
          ? { gap: spacing.s }
          : [styles.capsule, { backgroundColor: colors.surfaceContent }],
      ]}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={t('translation.translateMessageLabel')}
        onPress={onTranslate}
        style={({ pressed }) => [
          styles.splitHalf,
          pad ? null : { paddingLeft: 14, paddingRight: spacing.s },
          {
            backgroundColor: pressed
              ? colors.accentSelectionSubtle
              : 'transparent',
          },
        ]}>
        <Text style={label}>{t('translation.translate')}</Text>
      </Pressable>
      {typeof languages === 'string' ? null : (
        <>
          <View
            style={[styles.divider, { backgroundColor: colors.textSecondary }]}
          />
          <MenuButton
            accessibilityLabel={t('translation.target')}
            accessibilityValue={
              other === undefined ? undefined : { text: other.name }
            }
            sections={[
              {
                items: languages
                  .filter(({ code }) => !isAppLanguage(code, settings.language))
                  .map((language) => ({
                    key: `language:${language.code}`,
                    title: language.name,
                    symbol: '',
                    checked: other?.code === language.code,
                    run: () => {
                      onSelect(language);
                    },
                  })),
              },
            ]}
            style={[
              styles.splitHalf,
              pad ? null : { paddingLeft: spacing.s, paddingRight: 14 },
            ]}>
            <View style={styles.splitHalf}>
              {other === undefined ? null : (
                <Text style={label}>{other.name}</Text>
              )}
              <SFSymbol
                name="chevron.up.chevron.down"
                size={12}
                color={colors.textSecondary}
              />
            </View>
          </MenuButton>
        </>
      )}
      {languages === 'loading' ? (
        <ActivityIndicator accessibilityLabel={t('translation.loading')} />
      ) : null}
    </View>
  );
  const failure =
    languages === 'failed' ? (
      <View style={styles.row}>
        <Text style={[styles.title, { color: colors.textPrimary }]}>
          {t('translation.languagesFailed')}
        </Text>
        <Action
          label={t('translation.tryAgain')}
          accessibilityLabel={t('translation.tryAgainLabel')}
          onPress={() => {
            setRetried(true);
            reload();
          }}
        />
      </View>
    ) : null;
  if (pad) {
    return (
      <>
        <View style={styles.heading}>
          {glyph}
          {split}
        </View>
        {failure}
      </>
    );
  }
  return (
    <>
      <View style={styles.heading}>
        {glyph}
        <Text style={[styles.title, { color: colors.textPrimary }]}>
          {t('translation.translateMessageLabel')}
        </Text>
      </View>
      {split}
      {failure}
    </>
  );
}

function ReaderTranslation({
  translator,
  body,
}: {
  readonly translator: NativeTranslation;
  readonly body: ReaderText;
}) {
  const { t, settings } = useLocalization();
  // Each shown translation owns its queued native input; Dismiss retires it before rendering.
  const session = useRef(0);
  const generation = session.current;
  const [target, setTarget] = useState<TranslationLanguage>();
  const input =
    target === undefined
      ? undefined
      : messageTranslationInput(body, target.code);
  const current = () => generation === session.current;
  const translation = useTranslation(translator, input, current);
  const [languages, reload] = useLanguages(translator, translation.enabled);
  const translateInto = (language: TranslationLanguage) => {
    if (!current()) {
      return;
    }
    setTarget(language);
    translation.start(messageTranslationInput(body, language.code));
  };
  return (
    <TranslationPanel
      label={t('translation.messageRegion')}
      languages={languages}
      chooser={
        <SplitTranslate
          languages={languages}
          reload={reload}
          target={target}
          onTranslate={() => {
            translateInto({
              code: settings.language,
              name:
                appLanguages.find(({ code }) => code === settings.language)
                  ?.name ?? settings.language,
            });
          }}
          onSelect={translateInto}
        />
      }
      target={target}
      translation={translation}
      style={[styles.banner, pad ? styles.padBanner : null]}
      actions={
        target === undefined ? null : (
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
            }}
          />
        )
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

// Review of a translation of captured Draft text. The Draft changes only when the person applies
// it; the owner then replaces exactly the captured selection as one undoable edit.
export function DraftTranslation({
  translator,
  text,
  onApply,
  onClose,
}: {
  readonly translator: NativeTranslation;
  readonly text: string;
  readonly onApply: (translated: string) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [target, setTarget] = useState<TranslationLanguage>();
  const input =
    target === undefined ? undefined : draftTranslationInput(text, target.code);
  const translation = useTranslation(translator, input);
  const [languages, reload] = useLanguages(translator, translation.enabled);
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
      languages={languages}
      chooser={
        <TargetLanguages
          languages={languages}
          reload={reload}
          selected={target}
          onSelect={(language) => {
            setTarget(language);
            translation.start(draftTranslationInput(text, language.code));
          }}
        />
      }
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
