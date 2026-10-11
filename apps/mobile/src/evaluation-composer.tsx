import type { Draft } from '@private-email/mail-core/drafts';

import { supported } from '@private-email/draft-editor/conversion';
import { decodeChange } from '@private-email/draft-editor/messages';
import { editorPage } from '@private-email/draft-editor/page';
import { draftOf, isEmptyDraft } from '@private-email/mail-core/drafts';
import { spacing } from '@private-email/mail-core/theme';
import { useCallback, useLayoutEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';
import { WebView } from 'react-native-webview';

import { Action, Composer } from './composer.tsx';
import { useLocalization } from './localization.ts';
import { useComposerNavigation, useDrafts, useDraftStore } from './mailbox.tsx';
import { usePalette } from './theme.ts';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    paddingHorizontal: spacing.large,
    paddingTop: spacing.large,
    gap: spacing.medium,
  },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.small,
  },
  grow: { flex: 1 },
  title: { fontSize: 16, fontWeight: '600' },
  status: { fontSize: 13 },
  notice: { fontSize: 14 },
  body: { flex: 1, backgroundColor: 'transparent' },
});

// The Tiptap evaluation editor for one Draft: the packaged page edits plain paragraphs, and each
// change saves through the Draft store like the current composer's edits.
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
  // The page loads once with the opened body; later edits never reload it.
  // oxlint-disable-next-line react/hook-use-state -- The mounted page keeps its original source.
  const [source] = useState(() => ({ html: page }));
  // oxlint-disable-next-line react/hook-use-state -- Injected once, before the page's script.
  const [injected] = useState(
    () =>
      `window.draftEditor = ${JSON.stringify({ document: initial.body, label: t('drafts.body') })}; true;`,
  );
  const [closing, setClosing] = useState<'saving' | 'blocked'>();
  const [stopped, setStopped] = useState(false);
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
      style={[styles.fill, { backgroundColor: colors.background }]}>
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
            style={[styles.grow, styles.title, { color: colors.foreground }]}>
            {t('drafts.evaluation.title')}
          </Text>
        </View>
        <Text style={[styles.status, { color: colors.secondary }]}>
          {t('drafts.from', { from: initial.from })}
        </Text>
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.status, { color: colors.secondary }]}>
          {t('drafts.status', { status: t(`drafts.save.${save}`) })}
        </Text>
        {closing === 'blocked' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.foreground },
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
            style={[styles.notice, { color: colors.foreground }]}>
            {t('drafts.evaluation.stopped')}
          </Text>
        ) : null}
      </View>
      {stopped ? null : (
        <WebView
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
          onContentProcessDidTerminate={() => {
            setStopped(true);
          }}
          onError={() => {
            setStopped(true);
          }}
          onMessage={({ nativeEvent }) => {
            if (!mounted.current) {
              return;
            }
            const body = decodeChange(nativeEvent.data);
            if (body === undefined) {
              return;
            }
            // Editing again replaces a failed Close's notice, as in the current composer.
            setClosing(undefined);
            const previous = authored.current;
            authored.current = { ...previous, body };
            void store.update(authored.current, previous, rebind);
          }}
          // Only the page itself loads; every navigation it could start is cancelled.
          onShouldStartLoadWithRequest={({ url, navigationType }) =>
            url === 'about:blank' && navigationType === 'other'
          }
          originWhitelist={['*']}
          setSupportMultipleWindows={false}
          source={source}
          style={[styles.body, { backgroundColor: colors.background }]}
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
}: {
  readonly page: string;
  readonly id: string;
  readonly onClose: () => void;
  readonly onRebind: (id: string) => void;
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
        onClose={onClose}
        onRebind={onRebind}
      />
    );
  }
  if (!supported(draft.body)) {
    return (
      <SafeAreaView
        edges={{ top: true, bottom: true, left: true, right: true }}
        style={[styles.fill, { backgroundColor: colors.background }]}>
        <View style={styles.content}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.foreground }]}>
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
