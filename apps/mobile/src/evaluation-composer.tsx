import type { Command, Update } from '@private-email/draft-editor/messages';
import type { CapturedDraftText } from '@private-email/mail-core/assistance';
import type { Draft } from '@private-email/mail-core/drafts';

import { supported } from '@private-email/draft-editor/conversion';
import {
  commandScript,
  decodeUpdate,
} from '@private-email/draft-editor/messages';
import { editorPage } from '@private-email/draft-editor/page';
import {
  canRewrite,
  canSuggestReply,
  captureDraftText,
  draftReplacement,
  sameDraftAssistanceSource,
} from '@private-email/mail-core/assistance';
import { draftOf, isEmptyDraft } from '@private-email/mail-core/drafts';
import {
  replaceSelection,
  selectedText,
} from '@private-email/mail-core/semantic-document';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import { use, useCallback, useLayoutEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';
import { WebView } from 'react-native-webview';

import { blockControls, markControls } from './composer-controls.tsx';
import {
  Action,
  CapturedAssistance,
  Composer,
  retires,
  rewriteLabel,
} from './composer.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import { useComposerNavigation, useDrafts, useDraftStore } from './mailbox.tsx';
import { AssistanceContext } from './message-summary.tsx';
import { textStyles, usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.xl,
    gap: spacing.l,
  },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  grow: { flex: 1 },
  title: { ...textStyles.headline },
  status: { ...textStyles.footnote },
  notice: { ...textStyles.subheadline },
  format: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
  },
  body: { flex: 1, backgroundColor: 'transparent' },
});

type PageState = Omit<Update, 'type' | 'document'>;

// The current composer's formatting, history and assistance controls, acting on the page. Each
// press is one page command; the page reports the formatting at its selection.
function Toolbar({
  page,
  draft,
  run,
  capture,
}: {
  readonly page: PageState;
  readonly draft: Draft;
  readonly run: (command: Command) => void;
  readonly capture: (purpose: CapturedDraftText['purpose']) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  const { selection } = page;
  return (
    <View
      accessibilityLabel={t('drafts.formatting')}
      accessibilityRole="toolbar"
      style={styles.bar}>
      <Action
        disabled={!page.undo}
        label={t('drafts.undo')}
        onPress={() => {
          run({ type: 'undo' });
        }}
      />
      <Action
        disabled={!page.redo}
        label={t('drafts.redo')}
        onPress={() => {
          run({ type: 'redo' });
        }}
      />
      {markControls.map(([mark, label, name, style]) => (
        <Pressable
          key={mark}
          accessibilityLabel={t(name)}
          accessibilityRole="button"
          accessibilityState={{ selected: page.marks.includes(mark) }}
          onPress={() => {
            run({ type: 'mark', mark });
          }}
          style={[
            styles.format,
            page.marks.includes(mark) && {
              backgroundColor: colors.accentSelectionSubtle,
              borderWidth: 2,
              borderColor: colors.textPrimary,
            },
          ]}>
          <Text style={[{ color: colors.textPrimary }, style]}>{label}</Text>
        </Pressable>
      ))}
      {blockControls.map(([kind, label, name]) => (
        <Pressable
          key={kind}
          accessibilityLabel={t(name)}
          accessibilityRole="button"
          accessibilityState={{ selected: page.kind === kind }}
          onPress={() => {
            run({ type: 'block', kind });
          }}
          style={[
            styles.format,
            page.kind === kind && {
              backgroundColor: colors.accentSelectionSubtle,
              borderWidth: 2,
              borderColor: colors.textPrimary,
            },
          ]}>
          <Text style={{ color: colors.textPrimary }}>{label}</Text>
        </Pressable>
      ))}
      {translation === undefined ? null : (
        <Action
          disabled={
            !hasTranslatableText(
              selectedText(draft.body, selection, translationInputLimit + 1),
            )
          }
          label={t('translation.translate')}
          accessibilityLabel={t('translation.translateSelectionLabel')}
          onPress={() => {
            capture('translate');
          }}
        />
      )}
      {assistance === undefined ? null : (
        <Action
          disabled={!canRewrite(draft.body, selection)}
          label={t('assistance.rewrite')}
          accessibilityLabel={t(rewriteLabel(selection))}
          onPress={() => {
            capture('rewrite');
          }}
        />
      )}
      {assistance !== undefined && canSuggestReply(draft) ? (
        <Action
          label={t('assistance.suggestReply')}
          accessibilityLabel={t('assistance.suggestReplyLabel')}
          onPress={() => {
            capture('reply');
          }}
        />
      ) : null}
    </View>
  );
}

// The Tiptap evaluation editor for one Draft: the packaged page edits the body, and each change
// saves through the Draft store like the current composer's edits. Assistance captures the body
// the page last reported, and an accepted result replaces it in the page as one undoable edit.
function EvaluationEditor({
  page,
  initial,
  onClose,
  onRebind,
}: {
  readonly page: string;
  readonly initial: Draft;
  readonly onClose: () => void;
  readonly onRebind: (id: string) => void;
}) {
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  // Page messages can arrive before React commits an earlier edit or a rebind.
  const authored = useRef(initial);
  const [draft, setDraft] = useState(initial);
  // Undefined until the page reports that it is ready for commands.
  const [pageState, setPageState] = useState<PageState>();
  const pageNow = useRef<PageState>(undefined);
  const view = useRef<WebView>(null);
  const pageStopped = useRef(false);
  const [closing, setClosing] = useState<'saving' | 'blocked'>();
  const [stopped, setStopped] = useState(false);
  const mounted = useRef(true);
  const onRebindNow = useRef(onRebind);
  useLayoutEffect(() => {
    onRebindNow.current = onRebind;
  }, [onRebind]);
  const rebind = useCallback((id: string) => {
    authored.current = { ...authored.current, id, conflict: true };
    if (mounted.current) {
      onRebindNow.current(id);
    }
  }, []);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      store.release(rebind);
    };
  }, [rebind, store]);
  // Body text captured for an explicitly requested translation, rewrite or reply suggestion, until
  // its result is applied or the original kept.
  const [captured, setCaptured] = useState<
    CapturedDraftText & { readonly id: number }
  >();
  const captureNow = useRef<typeof captured>(undefined);
  const captureGeneration = useRef(0);
  const forget = useCallback(() => {
    captureNow.current = undefined;
    setCaptured(undefined);
  }, []);
  const assistanceEnabled = useMailAssistanceLifetime(forget);
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  if (
    captured !== undefined &&
    retires(captured, draft, { assistance, translation })
  ) {
    setCaptured(undefined);
  }
  const stop = () => {
    pageStopped.current = true;
    pageNow.current = undefined;
    forget();
    setStopped(true);
  };
  const run = (command: Command) => {
    if (mounted.current && !pageStopped.current) {
      view.current?.injectJavaScript(commandScript(command));
    }
  };
  const capture = (purpose: CapturedDraftText['purpose']) => {
    const reported = pageNow.current;
    if (!mounted.current || !assistanceEnabled() || reported === undefined) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...captureDraftText(purpose, authored.current, reported.selection),
      id: captureGeneration.current,
    };
    captureNow.current = next;
    setCaptured(next);
    // The software keyboard would cover the review panel; the page keeps its selection.
    run({ type: 'blur' });
  };
  // Replaces exactly the captured text with its reviewed result, in the body revision it was
  // captured from. The page saves the result through its next update.
  const applyCaptured = (replacement: string) => {
    const latest = authored.current;
    const reported = pageNow.current;
    if (
      !mounted.current ||
      reported === undefined ||
      captured === undefined ||
      captureNow.current !== captured ||
      !sameDraftAssistanceSource(captured.draft, latest, captured.purpose)
    ) {
      return;
    }
    forget();
    const result = replaceSelection(
      latest.body,
      captured.selection,
      draftReplacement(captured.text, replacement),
    );
    run({
      type: 'replace',
      revision: reported.revision,
      document: result.document,
      selection: result.selection ?? captured.selection,
    });
  };
  // The page loads once with the opened body; later edits never reload it.
  // oxlint-disable-next-line react/hook-use-state -- The mounted page keeps its original source.
  const [source] = useState(() => ({ html: page }));
  // oxlint-disable-next-line react/hook-use-state -- Injected once, before the page's script.
  const [injected] = useState(
    () =>
      `window.draftEditor = ${JSON.stringify({ document: initial.body, label: t('drafts.body') })}; true;`,
  );
  const close = useCallback(async () => {
    if (!mounted.current) {
      return false;
    }
    setClosing('saving');
    let closed = false;
    try {
      closed = isEmptyDraft(authored.current)
        ? await store.discard(() => authored.current.id, {
            onlyIfEmpty: true,
            expected: () => authored.current,
          })
        : await store.save();
    } catch {
      // An unexpected storage rejection keeps the composer open and retryable too.
    }
    if (!mounted.current) {
      return closed;
    }
    if (closed) {
      mounted.current = false;
      onClose();
      return true;
    }
    setClosing('blocked');
    return false;
  }, [onClose, store]);
  const navigation = useComposerNavigation();
  useLayoutEffect(() => navigation.register(close), [navigation, close]);
  const save = state.kind === 'ready' ? state.save : 'failed';
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.content}>
        <View style={styles.bar}>
          <Action
            disabled={closing === 'saving'}
            label={t('drafts.close')}
            onPress={() => {
              void close();
            }}
          />
          <Text
            accessibilityRole="header"
            numberOfLines={1}
            style={[styles.grow, styles.title, { color: colors.textPrimary }]}>
            {t('drafts.evaluation.title')}
          </Text>
        </View>
        <Text style={[styles.status, { color: colors.textSecondary }]}>
          {t('drafts.from', { from: initial.from })}
        </Text>
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.status, { color: colors.textSecondary }]}>
          {t('drafts.status', { status: t(`drafts.save.${save}`) })}
        </Text>
        {closing === 'blocked' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.textPrimary },
              ]}>
              {t('drafts.evaluation.saveBlocked')}
            </Text>
            <Action
              label={t('common.retry')}
              onPress={() => {
                void close();
              }}
            />
          </View>
        ) : null}
        {stopped ? (
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.textPrimary }]}>
            {t('drafts.evaluation.stopped')}
          </Text>
        ) : null}
        {/* Controls appear once the page reports that it is ready for commands. */}
        {stopped || pageState === undefined ? null : (
          <Toolbar
            page={pageState}
            draft={draft}
            run={run}
            capture={capture}
          />
        )}
        {captured === undefined ? null : (
          <CapturedAssistance
            key={captured.id}
            captured={captured}
            assistance={assistance}
            translation={translation}
            onApply={applyCaptured}
            onClose={forget}
          />
        )}
      </View>
      {stopped ? null : (
        <WebView
          ref={view}
          allowsInlineMediaPlayback={false}
          allowsLinkPreview={false}
          automaticallyAdjustContentInsets={false}
          cacheEnabled={false}
          dataDetectorTypes="none"
          hideKeyboardAccessoryView
          incognito
          injectedJavaScriptBeforeContentLoaded={injected}
          javaScriptCanOpenWindowsAutomatically={false}
          mediaPlaybackRequiresUserAction
          onContentProcessDidTerminate={stop}
          onError={stop}
          onMessage={({ nativeEvent }) => {
            if (!mounted.current || pageStopped.current) {
              return;
            }
            const update = decodeUpdate(nativeEvent.data);
            if (update === undefined) {
              return;
            }
            const { document: body, type: _, ...next } = update;
            pageNow.current = next;
            setPageState(next);
            if (body === undefined) {
              return;
            }
            // Editing again replaces a failed Close's notice, as in the current composer, and
            // retires captured text.
            setClosing(undefined);
            forget();
            const previous = authored.current;
            authored.current = { ...previous, body };
            setDraft(authored.current);
            void store.update(authored.current, previous, rebind);
          }}
          // Only the page itself loads; every navigation it could start is cancelled.
          onShouldStartLoadWithRequest={({ url, navigationType }) =>
            url === 'about:blank' && navigationType === 'other'
          }
          originWhitelist={['*']}
          setSupportMultipleWindows={false}
          source={source}
          style={[styles.body, { backgroundColor: colors.surfaceContent }]}
        />
      )}
    </SafeAreaView>
  );
}

// A Draft the page cannot show without loss, or one that is not available, stays with the current
// composer's own views.
function EvaluationComposer({
  page,
  id,
  onClose,
  onRebind,
  expanded,
  onExpand,
}: {
  readonly page: string;
  readonly id: string;
  readonly onClose: () => void;
  readonly onRebind: (id: string) => void;
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  // The editor stays mounted when it moves to its own copy, and remounts for another Draft.
  const [editor, setEditor] = useState({ key: id, followed: id });
  if (editor.followed !== id) {
    setEditor({ key: id, followed: id });
  }
  const rebind = useCallback(
    (copy: string) => {
      setEditor((current) => ({ key: current.key, followed: copy }));
      onRebind(copy);
    },
    [onRebind],
  );
  const draft = draftOf(state, id);
  if (draft === undefined) {
    return (
      <Composer
        id={id}
        expanded={expanded}
        onClose={onClose}
        onExpand={onExpand}
        onRebind={onRebind}
      />
    );
  }
  if (!supported(draft.body)) {
    return (
      <SafeAreaView
        edges={{ top: true, bottom: true, left: true, right: true }}
        style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
        <View style={styles.content}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.textPrimary }]}>
            {t('drafts.evaluation.unsupported')}
          </Text>
          <Action
            label={t('drafts.close')}
            onPress={onClose}
          />
        </View>
      </SafeAreaView>
    );
  }
  return (
    <EvaluationEditor
      key={editor.key}
      page={page}
      initial={draft}
      onClose={onClose}
      onRebind={rebind}
    />
  );
}

type ComposerProps = Readonly<{
  id: string;
  onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  onRebind: (id: string) => void;
  // The window-level expand control, which only the current composer offers.
  expanded?: boolean | undefined;
  onExpand?: (() => void) | undefined;
}>;

// `registration-draft-editor` builds open Drafts in the Tiptap evaluation editor; every other
// build keeps the current composer.
export function DraftComposer(props: ComposerProps) {
  return editorPage === undefined ? (
    <Composer {...props} />
  ) : (
    <EvaluationComposer
      page={editorPage}
      {...props}
    />
  );
}
