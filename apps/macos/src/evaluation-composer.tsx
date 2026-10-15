import type { Command } from '@private-email/draft-editor/messages';
import type { CapturedDraftText } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { SendRefusal } from '@private-email/mail-core/outbox';

import {
  commandScript,
  decodeMessage,
  knownAssets,
} from '@private-email/draft-editor/messages';
import { editorPage } from '@private-email/draft-editor/page';
import {
  captureDraftText,
  draftReplacement,
  sameDraftAssistanceSource,
} from '@private-email/mail-core/assistance';
import {
  addRecipients,
  draftOf,
  entryOf,
  isEmptyDraft,
  withAsset,
  withSender,
} from '@private-email/mail-core/drafts';
import {
  clip,
  imagesOf,
  replaceSelection,
} from '@private-email/mail-core/semantic-document';
import {
  use,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { WebView } from 'react-native-webview';

import type { Closing } from './composer.tsx';
import type { PageState } from './evaluation-composer-controls.tsx';

import {
  CapturedAssistance,
  Composer,
  ComposerNotices,
  composerStyles,
  DraftAssets,
  Notice,
  retires,
  SendingMailbox,
} from './composer.tsx';
import { Button, MenuPresence, ToolbarButton } from './design.tsx';
import {
  PageFormatBar,
  DraftFields,
  SaveBackground,
  SaveSheet,
} from './evaluation-composer-controls.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import {
  useComposerNavigation,
  useDraftStore,
  useDrafts,
  useOutbox,
} from './mailbox.tsx';
import { AssistanceContext } from './message-summary.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const s = composerStyles;
const styles = StyleSheet.create({
  controls: { zIndex: 1 },
  scroll: { flexGrow: 1 },
  // The regular composer's minimum body height.
  body: { flex: 1, minHeight: 160 },
});

// The Tiptap evaluation editor for one Draft, in the current composer's layout: the packaged page
// edits the body, and native controls format it, add files and offer writing tools. Nothing is
// saved until the person chooses Save on Close, as in Mail; Don't Save removes the Draft.
function EvaluationEditor({
  page,
  initial,
  onClose,
  onRebind,
  expanded = false,
  onExpand,
}: {
  readonly page: string;
  readonly initial: Draft;
  readonly onClose: () => void;
  readonly onRebind: (id: string) => void;
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const store = useDraftStore();
  const state = useDrafts();
  const outbox = useOutbox();
  const colors = usePalette();
  const { t } = useLocalization();
  // Page messages and field edits can arrive before React commits an earlier edit or a rebind.
  const authored = useRef(initial);
  const getDraft = useCallback(() => authored.current, []);
  // The version the store holds: the Draft as opened, until Save or Send stores this one.
  const stored = useRef(initial);
  const [draft, setDraft] = useState(initial);
  // Undefined until the page reports that it is ready for commands.
  const [pageState, setPageState] = useState<PageState>();
  const pageNow = useRef<PageState>(undefined);
  const view = useRef<WebView>(null);
  const pageStopped = useRef(false);
  const [open, setOpen] = useState<'save' | 'tools'>();
  const [closing, setClosing] = useState<Closing>();
  // Why the last Send left this Draft here.
  const [refused, setRefused] = useState<SendRefusal>();
  const [sending, setSending] = useState(false);
  // Save, Don't Save and Send each finish before another starts.
  const busy = useRef(false);
  const paused = useRef<((ready: boolean) => void) | undefined>(undefined);
  const leaving = useRef<((allowed: boolean) => void) | undefined>(undefined);
  const answerLeave = useCallback((allowed: boolean) => {
    const answer = leaving.current;
    leaving.current = undefined;
    answer?.(allowed);
  }, []);
  const [stopped, setStopped] = useState(false);
  const mounted = useRef(true);
  const onRebindNow = useRef(onRebind);
  useLayoutEffect(() => {
    onRebindNow.current = onRebind;
  }, [onRebind]);
  const rebind = useCallback((id: string) => {
    const previous = authored.current;
    authored.current = { ...previous, id, conflict: true };
    stored.current =
      stored.current === previous
        ? authored.current
        : { ...stored.current, id, conflict: true };
    if (mounted.current) {
      setDraft(authored.current);
      onRebindNow.current(id);
    }
  }, []);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      paused.current?.(false);
      leaving.current?.(false);
      if (!busy.current) {
        store.release(rebind);
      }
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
    paused.current?.(false);
    pageNow.current = undefined;
    forget();
    setStopped(true);
  };
  const run = useCallback((command: Command) => {
    if (mounted.current && !pageStopped.current) {
      view.current?.injectJavaScript(commandScript(command));
    }
  }, []);
  // An edit in this editor only; the store learns of it on Save or Send.
  const change = (next: Draft) => {
    if (busy.current && paused.current === undefined) {
      return;
    }
    authored.current = next;
    setDraft(next);
    if (!busy.current) {
      setClosing(undefined);
      setRefused(undefined);
    }
  };
  // Every asset this editor gave its page, as native code last settled it. The page reports only
  // these, and Undo in the page can restore any of them.
  const known = useRef(
    new Map(
      [...imagesOf(initial.body), ...(initial.attachments ?? [])].map(
        (asset) => [asset.id, asset],
      ),
    ),
  );
  // An import settles in this editor, and the store keeps every asset the page can restore while
  // the Draft exists.
  useLayoutEffect(
    () =>
      store.onSettle((id, next) => {
        const asset = known.current.get(id);
        if (asset !== undefined) {
          known.current.set(id, next(asset));
        }
        const previous = authored.current;
        authored.current = withAsset(previous, id, next);
        stored.current =
          stored.current === previous
            ? authored.current
            : withAsset(stored.current, id, next);
        if (mounted.current) {
          setDraft(authored.current);
        }
        return [
          authored.current,
          { ...authored.current, attachments: [...known.current.values()] },
        ];
      }),
    [store],
  );
  // Files the person chose become Attachments, and images placed inline go at the page's
  // selection, as one edit in the page; native code then imports their bytes.
  const add = async (from: PickSource, inline: boolean) => {
    const files = await store.pick(
      from,
      () => mounted.current && !pageStopped.current && !busy.current,
    );
    const imports = files.map((file) => ({ file, asset: store.prepare(file) }));
    for (const { asset } of imports) {
      known.current.set(asset.id, asset);
    }
    const inlined = imports.filter(
      ({ file }) => inline && file.type.startsWith('image/'),
    );
    if (imports.length > 0) {
      run({
        type: 'add',
        images: inlined.map(({ asset }) => asset),
        attachments: imports
          .filter((each) => !inlined.includes(each))
          .map(({ asset }) => asset),
      });
    }
    for (const { asset, file } of imports) {
      void store.importAsset(asset, file.source);
    }
  };
  const removeAsset = (id: string) => {
    void store.cancelImport(id);
    run({ type: 'remove', id });
  };
  // Verified thumbnails of the body's images, which the image rows read and read again on
  // Try again or when storage becomes available. A page that loads later receives all of them.
  const previews = useRef(new Map<string, string>());
  const showPreview = useCallback(
    (id: string, uri: string | null) => {
      if (uri === null) {
        previews.current.delete(id);
      } else {
        previews.current.set(id, uri);
      }
      if (pageNow.current !== undefined) {
        run({ type: 'previews', previews: { [id]: uri } });
      }
    },
    [run],
  );
  const ready = pageState !== undefined;
  useEffect(() => {
    if (ready && previews.current.size > 0) {
      run({
        type: 'previews',
        previews: Object.fromEntries(previews.current),
      });
    }
  }, [ready, run]);
  const capture = (purpose: CapturedDraftText['purpose']) => {
    setOpen(undefined);
    const reported = pageNow.current;
    if (
      !mounted.current ||
      busy.current ||
      !assistanceEnabled() ||
      reported === undefined
    ) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...captureDraftText(purpose, authored.current, reported.selection),
      id: captureGeneration.current,
    };
    captureNow.current = next;
    setCaptured(next);
  };
  // Replaces exactly the captured text with its reviewed result, in the body revision it was
  // captured from, as one undoable edit in the page.
  const applyCaptured = (replacement: string) => {
    const latest = authored.current;
    const reported = pageNow.current;
    if (
      !mounted.current ||
      busy.current ||
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
      `window.draftEditor = ${JSON.stringify({ document: initial.body, attachments: initial.attachments ?? [], label: t('drafts.body') })}; true;`,
  );
  // Entries still being typed become recipients; an invalid one keeps the Draft here.
  const finishEntries = () => {
    let finished = authored.current;
    for (const field of ['to', 'cc', 'bcc'] as const) {
      finished = addRecipients(finished, {
        field,
        text: entryOf(finished, field),
        all: true,
      }).draft;
    }
    authored.current = finished;
    setDraft(finished);
    return finished.entries === undefined;
  };
  // Runs one Save, Don't Save or Send; `finish` resolves whether the editor may close. One that
  // fails without explaining why offers to try saving again.
  const finishing = async (finish: () => Promise<boolean>) => {
    if (busy.current) {
      return false;
    }
    busy.current = true;
    setOpen(undefined);
    setClosing('saving');
    let closed = false;
    try {
      // A WebKit edit may still be queued when a native control is pressed. Freeze the page and
      // receive its final document before storing or admitting exactly that version.
      const pageReady =
        pageStopped.current || pageNow.current === undefined
          ? true
          : // oxlint-disable-next-line promise/avoid-new -- The page acknowledges its ordered edit flush.
            await new Promise<boolean>((resolve) => {
              paused.current = resolve;
              run({ type: 'editable', editable: false });
            });
      paused.current = undefined;
      closed = pageReady && (await finish());
    } catch {
      // An unexpected storage rejection keeps the composer open and retryable too.
    }
    paused.current = undefined;
    busy.current = false;
    if (!mounted.current) {
      store.release(rebind);
    }
    setSending(false);
    answerLeave(closed);
    if (!closed) {
      run({ type: 'editable', editable: true });
    }
    if (closed && mounted.current) {
      mounted.current = false;
      onClose();
    } else if (!closed) {
      setClosing((current) => (current === 'saving' ? 'blocked' : current));
    }
    return closed;
  };
  // Stores this editor's version, then saves it; a Draft that changed elsewhere since it was
  // opened becomes a conflicting copy.
  const saveDraft = () =>
    finishing(async () => {
      if (!finishEntries()) {
        setClosing('recipients');
        return false;
      }
      void store.update(authored.current, stored.current, rebind);
      stored.current = authored.current;
      return store.save();
    });
  const deleteDraft = () =>
    finishing(async () => {
      if (
        await store.discard(() => authored.current.id, {
          expected: () => stored.current,
        })
      ) {
        return true;
      }
      setClosing('discard-blocked');
      return false;
    });
  // Stores and admits the Draft as this editor shows it to the Outbox, then closes; a refusal
  // keeps it open.
  const send = () =>
    finishing(async () => {
      if (!finishEntries()) {
        setClosing(undefined);
        setRefused('entries');
        return false;
      }
      forget();
      setSending(true);
      const shown = authored.current;
      void store.update(shown, stored.current, rebind);
      stored.current = shown;
      const refusal = await outbox.send(() => ({
        ...shown,
        id: authored.current.id,
        ...(authored.current.conflict ? { conflict: true as const } : {}),
      }));
      if (refusal === undefined) {
        return true;
      }
      setClosing(undefined);
      setRefused(refusal);
      return false;
    });
  // Close asks to save changes, including ones a failed Save left unsaved; an empty Draft is
  // removed and an unchanged one closes.
  const close = async () => {
    if (busy.current) {
      return false;
    }
    return finishing(async () => {
      if (isEmptyDraft(authored.current) && isEmptyDraft(stored.current)) {
        return store.discard(() => authored.current.id, {
          onlyIfEmpty: true,
          expected: () => stored.current,
        });
      }
      if (
        authored.current === stored.current &&
        state.kind === 'ready' &&
        state.save === 'saved'
      ) {
        return true;
      }
      setClosing(undefined);
      setOpen('save');
      return false;
    });
  };
  // Leaving for another destination asks the same question first.
  const navigation = useComposerNavigation();
  useLayoutEffect(() =>
    navigation.register(async () => {
      if (await close()) {
        return true;
      }
      if (busy.current || !mounted.current) {
        return false;
      }
      // oxlint-disable-next-line promise/avoid-new -- Navigation waits for Save, Delete or dismissal.
      return new Promise<boolean>((resolve) => {
        leaving.current = resolve;
      });
    }),
  );
  useEffect(() => {
    if (open !== 'save' && !busy.current) {
      answerLeave(false);
    }
  }, [answerLeave, open]);
  useEffect(() => {
    if (open === 'save') {
      run({ type: 'editable', editable: false });
    } else if (!busy.current) {
      run({ type: 'editable', editable: true });
    }
  }, [open, run]);
  const title = clip(draft.subject) || t('drafts.newMessage');
  const titleLabel =
    title.length < draft.subject.length
      ? t('drafts.titleShortened', { title })
      : title;
  // Quoted correspondence and its images stay as the Draft has them.
  const { quoted: _quoted, ...owned } = draft;
  // Controls appear once the page reports that it is ready for commands.
  const shown = stopped || closing === 'saving' ? undefined : pageState;
  return (
    <View style={[s.fill, { backgroundColor: colors.surfaceContent }]}>
      <SaveBackground active={open === 'save'}>
        <View style={s.header}>
          <ToolbarButton
            disabled={closing === 'saving'}
            icon="xmark"
            label={t('drafts.close')}
            onPress={() => {
              void close();
            }}
          />
          <View
            accessible
            accessibilityLabel={titleLabel}
            accessibilityRole="header"
            style={s.grow}>
            <Text
              numberOfLines={1}
              style={[s.title, { color: colors.textPrimary }]}>
              {title}
            </Text>
          </View>
          {onExpand === undefined ? null : (
            <ToolbarButton
              icon={
                expanded
                  ? 'arrow.down.right.and.arrow.up.left'
                  : 'arrow.up.left.and.arrow.down.right'
              }
              label={t(expanded ? 'drafts.collapse' : 'drafts.expand')}
              onPress={onExpand}
            />
          )}
        </View>
        <MenuPresence
          open={shown !== undefined}
          origin="top"
          style={styles.controls}>
          {pageState === undefined ? null : (
            <PageFormatBar
              draft={draft}
              page={pageState}
              tools={open === 'tools'}
              run={run}
              onTools={(next) => {
                setOpen(next ? 'tools' : undefined);
              }}
              onAdd={(from, inline) => {
                void add(from, inline);
              }}
              onCapture={capture}
            />
          )}
        </MenuPresence>
        {/* The body, files and fields scroll together in a short window. */}
        <ScrollView contentContainerStyle={styles.scroll}>
          <ComposerNotices
            closing={closing}
            draft={draft}
            refused={refused}
            onClose={() => {
              void saveDraft();
            }}
            onDiscard={() => {
              void deleteDraft();
            }}
            onKeepEditing={() => {
              setClosing(undefined);
            }}
          />
          {stopped ? (
            <Notice
              alert
              style={[s.notice, { color: colors.textPrimary }]}>
              {t('drafts.evaluation.stopped')}
            </Notice>
          ) : null}
          {captured === undefined ? null : (
            <View style={s.review}>
              <CapturedAssistance
                key={captured.id}
                captured={captured}
                assistance={assistance}
                translation={translation}
                onApply={applyCaptured}
                onClose={forget}
              />
            </View>
          )}
          {stopped ? (
            <View style={s.fill} />
          ) : (
            <WebView
              ref={view}
              allowsInlineMediaPlayback={false}
              allowsLinkPreview={false}
              cacheEnabled={false}
              dataDetectorTypes="none"
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
                const message = decodeMessage(nativeEvent.data);
                // The page refused a paste carrying files; the Mac has no native pasteboard import
                // for the page, so pasted images are not added here.
                if (message === undefined || message.type === 'paste') {
                  return;
                }
                const {
                  document: reported,
                  attachments: attached = [],
                  type: _,
                  frozen,
                  ...next
                } = message;
                const flushed =
                  frozen && next.revision === pageNow.current?.revision;
                pageNow.current = next;
                setPageState(next);
                if (reported === undefined || flushed) {
                  if (frozen) {
                    paused.current?.(true);
                  }
                  return;
                }
                // Editing again retires captured text, as in the current composer.
                forget();
                const previous = authored.current;
                const { body, attachments } = knownAssets(known.current, {
                  document: reported,
                  attachments: attached,
                });
                change({
                  ...previous,
                  body,
                  ...(attachments.length === 0 &&
                  previous.attachments === undefined
                    ? {}
                    : { attachments }),
                });
                if (frozen) {
                  paused.current?.(true);
                }
              }}
              // Only the page itself loads; every navigation it could start is cancelled.
              onShouldStartLoadWithRequest={({ url, navigationType }) =>
                url === 'about:blank' && navigationType === 'other'
              }
              pointerEvents={closing === 'saving' ? 'none' : 'auto'}
              originWhitelist={['*']}
              setSupportMultipleWindows={false}
              source={source}
              style={[styles.body, { backgroundColor: colors.surfaceContent }]}
            />
          )}
          <DraftAssets
            draft={owned}
            editable={shown !== undefined}
            onCancel={(id) => {
              void store.cancelImport(id);
            }}
            onConvert={(id) => {
              run({ type: 'convert', id });
            }}
            onPreview={showPreview}
            onRemove={removeAsset}
          />
          <DraftFields
            draft={draft}
            getDraft={getDraft}
            editable={closing !== 'saving' && !sending}
            onChange={change}
            onCaretMove={() => {
              setOpen(undefined);
            }}
          />
        </ScrollView>
        <View style={[s.actions, { borderTopColor: colors.separator }]}>
          <SendingMailbox
            draft={draft}
            editable={closing !== 'saving' && !sending}
            onChange={(mailbox) => {
              change(withSender(authored.current, mailbox));
            }}
          />
          <View style={s.grow} />
          <Button
            disabled={closing === 'saving'}
            label={t('drafts.send')}
            fill="accent"
            onPress={() => {
              void send();
            }}
          />
        </View>
      </SaveBackground>
      <SaveSheet
        open={open === 'save'}
        onSave={() => {
          void saveDraft();
        }}
        onDelete={() => {
          void deleteDraft();
        }}
        onCancel={() => {
          setOpen(undefined);
        }}
      />
    </View>
  );
}

// A Draft that is not available yet, or never was, stays with the current composer's own views.
// Once open, the editor keeps its unsaved version even if the Draft is removed elsewhere, so
// Save can still keep it as a copy.
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
  const draft = draftOf(state, id);
  // The editor stays mounted when it moves to its own copy, and remounts for another Draft.
  const [editor, setEditor] = useState({
    key: id,
    followed: id,
    opened: draft,
  });
  if (editor.followed !== id) {
    setEditor({ key: id, followed: id, opened: draft });
  } else if (editor.opened === undefined && draft !== undefined) {
    setEditor({ ...editor, opened: draft });
  }
  const rebind = useCallback(
    (copy: string) => {
      setEditor((current) => ({ ...current, followed: copy }));
      onRebind(copy);
    },
    [onRebind],
  );
  const opened = editor.followed === id ? editor.opened : draft;
  if (opened === undefined) {
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
  return (
    <EvaluationEditor
      key={editor.key}
      page={page}
      initial={opened}
      expanded={expanded}
      onClose={onClose}
      onExpand={onExpand}
      onRebind={rebind}
    />
  );
}

type ComposerProps = Readonly<{
  id: string;
  onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  onRebind: (id: string) => void;
  // The window-level expand control.
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
