import type {
  Command,
  PageMessage,
} from '@private-email/draft-editor/messages';
import type {
  CapturedDraftText,
  DraftTextPurpose,
  SlashTool,
} from '@private-email/mail-core/assistance';
import type {
  Draft,
  PickSource,
  SlashCommand,
} from '@private-email/mail-core/drafts';
import type { SendRefusal } from '@private-email/mail-core/outbox';
import type {
  Link,
  Selection,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { ComponentProps } from 'react';
import type { ViewInstance } from 'react-native';

import {
  commandScript,
  decodeMessage,
  knownAssets,
} from '@private-email/draft-editor/messages';
import { editorPage } from '@private-email/draft-editor/page';
import {
  canSuggestReply,
  captureDraftText,
  draftReplacement,
  isTextTool,
  sameDraftAssistanceSource,
  slashTools,
} from '@private-email/mail-core/assistance';
import {
  addRecipients,
  applySlashBlock,
  draftOf,
  entryOf,
  isEmptyDraft,
  profileOf,
  withAsset,
  withSender,
} from '@private-email/mail-core/drafts';
import {
  displayOf,
  editableLinkAt,
  imagesOf,
  replaceSelection,
  setLink,
  textOf,
  withText,
} from '@private-email/mail-core/semantic-document';
import { palette, spacing } from '@private-email/mail-core/theme';
import {
  use,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import { Platform, ScrollView, StyleSheet, Text, View } from 'react-native';
import { KeyboardAvoidingView } from 'react-native-keyboard-controller';
import { SafeAreaView } from 'react-native-screens/experimental';
import { WebView } from 'react-native-webview';

import type { Closing, Recovered } from './composer.tsx';
import type { Open, PageState } from './evaluation-composer-controls.tsx';

import { FormatPanel, useLinkEditor } from './composer-controls.tsx';
import {
  CapturedAssistance,
  CloseQuestion,
  Composer,
  ComposerLayoutContext,
  ComposerNotices,
  composerStyles,
  DraftAssets,
  isSlashInsert,
  isSlashTool,
  padFieldInset,
  retires,
  SendingMailbox,
  slashPickers,
  SlashMenuPanel,
  useSlashMenu,
} from './composer.tsx';
import {
  PhoneControls,
  phoneControlsInset,
  useRetainedControls,
  PadFormatBar,
  DraftFields,
  EditorHeader,
} from './evaluation-composer-controls.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceProfileContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { ProfileMailAssistanceGate } from './mail-assistance.tsx';
import {
  useComposerNavigation,
  useDraftStore,
  useDrafts,
  useOutbox,
} from './mailbox.tsx';
import { AssistanceContext } from './message-summary.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const s = composerStyles;
const styles = StyleSheet.create({
  scroll: { flexGrow: 1 },
  // The regular composer's minimum body height.
  // Over the fields below, for the Slash Command Menu.
  body: { flex: 1, minHeight: 160, zIndex: 1 },
  page: { flex: 1, backgroundColor: 'transparent' },
  // The Slash Command Menu floats over the body, from the caret's line.
  slashLine: {
    position: 'absolute',
    zIndex: 1,
    left: 0,
    right: 0,
    pointerEvents: 'box-none',
  },
  slashMenuBelow: { position: 'absolute', top: '100%', left: 0, right: 0 },
  slashMenuAbove: {
    position: 'absolute',
    bottom: '100%',
    left: 0,
    right: 0,
    paddingBottom: spacing.xs,
  },
  notice: { ...textStyles.subheadline, paddingHorizontal: spacing.l },
  // Menus float over the content below or above their control.
  // Over the body, and under the Close question, whose outside tap must reach it first.
  controls: { zIndex: 3 },
  padControls: { zIndex: 1 },
});

// On iPhone the body text starts 20pt in and just below From, with body's 22pt lines at 17pt
// in the primary text colour, as the sheet's frames draw it.
const phoneInsets =
  Platform.OS !== 'ios' || Platform.isPad
    ? ''
    : `document.documentElement.style.cssText = '--draft-inset-top: 4px; --draft-inset-x: 20px; --draft-line-height: calc(22 / 17); --draft-text: light-dark(${palette.light.textPrimary}, ${palette.dark.textPrimary})';`;

type PageKey = Extract<PageMessage, { type: 'key' }>['key'];

// The menu's Writing tools the page runs: each but Generate a Draft…, which has no prompt here.
const isPageTool = (tool: SlashTool): tool is Exclude<SlashTool, 'generate'> =>
  tool !== 'generate';

// The Slash Command Menu, as in the current composer: its rows follow the body and selection the
// page reports, with the Writing tools the page runs, and the page hands it its keys while it
// shows.
function usePageSlashMenu(
  draft: Draft,
  page: PageState | undefined,
  {
    closing,
    sending,
    busy,
    run,
  }: Readonly<{
    closing: Closing | undefined;
    sending: boolean;
    busy: Readonly<{ current: boolean }>;
    run: (command: Command) => void;
  }>,
) {
  const assistance = use(AssistanceContext);
  const menu = useSlashMenu(draft, page?.selection ?? { start: 0, end: 0 }, {
    paused: closing === 'saving' || sending,
    pausedNow: busy,
    tools: (body, query) =>
      assistance === undefined
        ? []
        : slashTools(body, query, canSuggestReply(draft)).filter(isPageTool),
  });
  const ready = page !== undefined;
  const shown = menu.shown !== undefined;
  useEffect(() => {
    if (ready) {
      run({ type: 'menu', open: shown });
    }
  }, [ready, run, shown]);
  return {
    ...menu,
    // Moving the caret without an edit closes the menu, as in the current composer; a scroll
    // reports the same selection.
    moved: (
      before: PageState | undefined,
      after: PageState,
      edited: boolean,
    ) => {
      const was = before?.selection;
      if (
        !edited &&
        (was?.start !== after.selection.start ||
          was.end !== after.selection.end)
      ) {
        menu.close();
      }
    },
    // After the page reports `next` in place of the `previous` body, edited at its selection: a typed
    // / opens the menu, and typing filters or closes it. What was typed includes what it replaced,
    // as in the current composer; an Undo or Redo types nothing.
    reported: (
      previous: Readonly<{
        body: SemanticDocument;
        selection: Selection | undefined;
      }>,
      next: Readonly<{
        body: SemanticDocument;
        selection: Selection;
        restored?: true;
      }>,
    ) => {
      const before = displayOf(previous.body).text;
      const after = displayOf(next.body).text;
      const at = previous.selection ?? next.selection;
      menu.typed(
        next.body,
        next.selection,
        next.restored
          ? ''
          : after.slice(at.start, at.end + after.length - before.length),
      );
    },
  };
}

// The page's Slash Command Menu under the caret's line, or over it when only there is room for it,
// staying inside the editor's `viewport` less `reserve` at its bottom, as the current composer
// places it.
function PageSlashMenu({
  page,
  viewport,
  reserve,
  shown,
  ...panel
}: Omit<
  ComponentProps<typeof SlashMenuPanel>,
  'shown' | 'origin' | 'maxHeight' | 'onContentHeight'
> & {
  readonly page: PageState | undefined;
  readonly viewport: Readonly<{ current: ViewInstance | null }>;
  readonly reserve: number;
  readonly shown: ComponentProps<typeof SlashMenuPanel>['shown'] | undefined;
}) {
  const { size } = use(ComposerLayoutContext);
  const line = useRef<ViewInstance>(null);
  const [rows, setRows] = useState(0);
  const [room, setRoom] =
    useState<Readonly<{ below: number; above: number }>>();
  const caret = page?.caret;
  if (shown === undefined || caret === undefined) {
    return null;
  }
  const measure = () => {
    const view = viewport.current?.getBoundingClientRect();
    const at = line.current?.getBoundingClientRect();
    if (view !== undefined && at !== undefined) {
      // Room less the menu's padding and margin.
      setRoom({
        below: view.bottom - reserve - at.bottom - 24,
        above: at.top - view.top - spacing.s - 24,
      });
    }
  };
  const flipped =
    room !== undefined && rows > room.below && room.above > room.below;
  return (
    <View
      ref={line}
      onLayout={measure}
      style={[
        styles.slashLine,
        { top: caret.top, height: caret.bottom - caret.top },
      ]}>
      <View
        style={[
          flipped ? styles.slashMenuAbove : styles.slashMenuBelow,
          // On iPad the panel keeps the native fields' inset; the page's text starts 16pt in, and
          // the menu 8pt left of it.
          size !== 'compact' && { left: 16 - spacing.s - padFieldInset },
        ]}>
        <SlashMenuPanel
          {...panel}
          shown={shown}
          origin={flipped ? 'bottom left' : 'top left'}
          maxHeight={
            room === undefined
              ? undefined
              : Math.max(flipped ? room.above : room.below, 0)
          }
          onContentHeight={setRows}
        />
      </View>
    </View>
  );
}

// The Tiptap evaluation editor for one Draft, in the current composer's layout: the packaged page
// edits the body, and native controls format it, add files and offer writing tools. Nothing is
// saved until the person chooses Save Draft on Close, as in Mail; Delete Draft removes the Draft.
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
  const layout = use(ComposerLayoutContext);
  // Page messages and field edits can arrive before React commits an earlier edit or a rebind.
  const authored = useRef(initial);
  const getDraft = useCallback(() => authored.current, []);
  // The version the store holds: the Draft as opened, until Save Draft or Send stores this one.
  const stored = useRef(initial);
  const [draft, setDraft] = useState(initial);
  // Undefined until the page reports that it is ready for commands.
  const [pageState, setPageState] = useState<PageState>();
  const pageNow = useRef<PageState>(undefined);
  // Selection reports may arrive before the body at their revision.
  const bodyRevision = useRef(0);
  // react-native-webview 14 defaults the class's extra props to `undefined`, which makes every
  // prop `never` (react-native-webview#3970); `object` adds none.
  const view = useRef<WebView<object>>(null);
  const pageStopped = useRef(false);
  const [open, setOpen] = useState<Open>();
  const closeAnchor = useRef<ViewInstance>(null);
  const hide = useCallback(() => {
    setOpen(undefined);
  }, []);
  // An open Link Editor outlives a resize between the iPad and iPhone layouts. On iPhone its sheet
  // opens from the Format panel.
  const linkEditor = useLinkEditor();
  if (layout.size === 'compact' && linkEditor.shown && open !== 'format') {
    setOpen('format');
  }
  const [closing, setClosing] = useState<Closing>();
  // Why the last Send left this Draft here.
  const [refused, setRefused] = useState<SendRefusal>();
  const [sending, setSending] = useState(false);
  // Save Draft, Delete Draft and Send each finish before another starts.
  const busy = useRef(false);
  const paused = useRef<((ready: boolean) => void) | undefined>(undefined);
  const leaving = useRef<((allowed: boolean) => void) | undefined>(undefined);
  // Whether the last Close opened its question rather than finishing or failing.
  const asked = useRef(false);
  const answerLeave = useCallback((allowed: boolean) => {
    const answer = leaving.current;
    leaving.current = undefined;
    answer?.(allowed);
  }, []);
  const [stopped, setStopped] = useState(false);
  // The editor's visible area, which the Slash Command Menu stays inside.
  const viewport = useRef<ViewInstance>(null);
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
  const profile = use(MailAssistanceProfileContext);
  const [captured, setCaptured] = useState<
    CapturedDraftText & { readonly id: number; readonly profile: string }
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
    retires(captured, draft, { assistance, translation, profile })
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
  // An edit in this editor only; the store learns of it on Save Draft or Send.
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
  const initialImages = imagesOf(textOf(initial.body));
  const known = useRef(
    new Map(
      [...initialImages, ...(initial.attachments ?? [])].map((asset) => [
        asset.id,
        asset,
      ]),
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
    setOpen(undefined);
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
  // Remove and Cancel already queued when Save Draft or Send starts leave the frozen version alone.
  const removeAsset = (id: string) => {
    if (busy.current) {
      return;
    }
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
  const capture = (purpose: DraftTextPurpose) => {
    setOpen(undefined);
    const reported = pageNow.current;
    if (
      !mounted.current ||
      busy.current ||
      !assistanceEnabled() ||
      reported === undefined ||
      // The selection must describe the body this editor holds.
      reported.revision !== bodyRevision.current
    ) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...captureDraftText(purpose, authored.current, reported.selection),
      id: captureGeneration.current,
      profile,
    };
    captureNow.current = next;
    setCaptured(next);
    // On iPad a text tool's review takes the whole window, as Expand does.
    if (isTextTool(purpose) && !expanded) {
      onExpand?.();
    }
    // The software keyboard would cover the review panel; the page keeps its selection.
    run({ type: 'blur' });
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
      reported.revision !== bodyRevision.current ||
      captured === undefined ||
      captureNow.current !== captured ||
      !sameDraftAssistanceSource(captured.draft, latest, captured.purpose)
    ) {
      return;
    }
    forget();
    const result = replaceSelection(
      textOf(latest.body),
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
  // Applies a Link Editor change to the body revision the page reported, as one undoable edit in
  // the page. A link or selection the page has moved or changed since the editor opened stays as
  // it is.
  const editLink = (link: Link, text: string, href?: string) => {
    const reported = pageNow.current;
    const body = textOf(authored.current.body);
    const current = reported && editableLinkAt(body, reported.selection);
    if (
      !mounted.current ||
      busy.current ||
      reported === undefined ||
      reported.revision !== bodyRevision.current ||
      current?.start !== link.start ||
      current.end !== link.end ||
      current.text !== link.text ||
      current.href !== link.href
    ) {
      return;
    }
    const result = setLink(body, link, { text, href });
    run({
      type: 'replace',
      revision: reported.revision,
      document: result.document,
      selection: result.selection ?? reported.selection,
    });
  };
  const slashMenu = usePageSlashMenu(draft, pageState, {
    closing,
    sending,
    busy,
    run,
  });
  // An Insert command's picker or a Writing tool chosen in the menu, which runs once the page
  // reports the edit the choice's replacement made; a page that refused it as stale runs neither.
  const slashNext =
    useRef<Readonly<{ revision: number; run: () => void }>>(undefined);
  const slashNextOf = (kind: SlashCommand) => {
    if (isSlashInsert(kind)) {
      return () => {
        void add(...slashPickers[kind]);
      };
    }
    if (isSlashTool(kind) && isPageTool(kind)) {
      return () => {
        capture(kind);
      };
    }
    return undefined;
  };
  // Choosing a block removes the query and sets the caret's block as one edit in the page, so one
  // Undo restores the text as typed. An Insert command removes the query and opens its picker, and
  // a Writing tool removes it and runs as from the format bar.
  const chooseSlash = (kind?: SlashCommand) => {
    const reported = pageNow.current;
    const body = textOf(authored.current.body);
    const choice = reported && slashMenu.choice(body, reported.selection, kind);
    if (
      !mounted.current ||
      busy.current ||
      reported === undefined ||
      reported.revision !== bodyRevision.current ||
      choice === undefined
    ) {
      return;
    }
    slashMenu.close();
    const blockKind =
      isSlashInsert(choice.kind) || isSlashTool(choice.kind)
        ? undefined
        : choice.kind;
    const result =
      blockKind === undefined
        ? replaceSelection(body, choice.query, '')
        : applySlashBlock(body, choice.query, blockKind);
    run({
      type: 'replace',
      revision: reported.revision,
      document: result.document,
      selection: result.selection ?? {
        start: choice.query.start,
        end: choice.query.start,
      },
    });
    const next = slashNextOf(choice.kind);
    slashNext.current = next && { revision: reported.revision, run: next };
  };
  const afterSlash = (replaced: number | undefined) => {
    const pending = slashNext.current;
    slashNext.current = undefined;
    if (pending !== undefined && pending.revision === replaced) {
      pending.run();
    }
  };
  // The keys the page hands over while the menu shows.
  const slashKey = (key: PageKey) => {
    const reported = pageNow.current;
    if (key === 'Escape') {
      slashMenu.close();
    } else if (key === 'Enter' || key === 'Tab') {
      chooseSlash();
    } else if (reported !== undefined && slashMenu.moving) {
      slashMenu.move(key, textOf(authored.current.body), reported.selection);
    }
  };
  // The page loads once with the opened body; later edits never reload it.
  // oxlint-disable-next-line react/hook-use-state -- The mounted page keeps its original source.
  const [source] = useState(() => ({ html: page }));
  // oxlint-disable-next-line react/hook-use-state -- Injected once, before the page's script.
  const [injected] = useState(
    () =>
      `window.draftEditor = ${JSON.stringify({ document: textOf(initial.body), attachments: initial.attachments ?? [], label: t('drafts.body') })}; ${phoneInsets} true;`,
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
  // Runs one Save Draft, Delete Draft or Send; `finish` resolves whether the editor may close.
  // One that fails without explaining why offers to try saving again.
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
  // Close asks to save or delete changes, including ones a failed Save Draft left unsaved; an
  // empty Draft is removed and an unchanged one closes.
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
      setOpen('close');
      asked.current = true;
      return false;
    });
  };
  // Leaving for another destination asks the same question first.
  const navigation = useComposerNavigation();
  useLayoutEffect(() =>
    navigation.register(async () => {
      asked.current = false;
      if (await close()) {
        return true;
      }
      // Only an open question can still answer; a refused Close leaves at once.
      if (!asked.current || busy.current || !mounted.current) {
        return false;
      }
      // oxlint-disable-next-line promise/avoid-new -- Navigation waits for Save, Delete or dismissal.
      return new Promise<boolean>((resolve) => {
        leaving.current = resolve;
      });
    }),
  );
  useEffect(() => {
    if (open !== 'close' && !busy.current) {
      answerLeave(false);
    }
  }, [answerLeave, open]);
  // Quoted correspondence and its images stay as the Draft has them.
  const { quoted: _quoted, ...owned } = draft;
  const controls = {
    draft,
    open,
    run,
    onOpen: setOpen,
    onAdd: (from: PickSource, inline: boolean) => {
      void add(from, inline);
    },
    onCapture: capture,
    onLink: editLink,
  };
  // Controls appear once the page reports that it is ready for commands.
  const shown = stopped || closing === 'saving' ? undefined : pageState;
  const phone = layout.size === 'compact' ? shown : undefined;
  const retained = useRetainedControls(
    pageState,
    shown !== undefined,
    layout.size,
  );
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[s.fill, { backgroundColor: colors.surfaceContent }]}>
      <KeyboardAvoidingView
        behavior="padding"
        enabled={layout.avoidKeyboard}
        keyboardVerticalOffset={layout.top}
        style={s.fill}>
        <View
          ref={viewport}
          style={s.fill}>
          <EditorHeader
            subject={draft.subject}
            busy={closing === 'saving'}
            closeOpen={open === 'close'}
            closeAnchor={closeAnchor}
            sender={
              <SendingMailbox
                draft={draft}
                editable={closing !== 'saving' && !sending}
                onChange={(mailbox) => {
                  change(withSender(authored.current, mailbox));
                }}
              />
            }
            expanded={expanded}
            onExpand={onExpand}
            onClose={() => {
              if (open === 'close') {
                setOpen(undefined);
              } else {
                void close();
              }
            }}
            onSend={() => {
              void send();
            }}
          />
          <CloseQuestion
            open={open === 'close'}
            anchor={closeAnchor}
            onDelete={() => {
              void deleteDraft();
            }}
            onSave={() => {
              void saveDraft();
            }}
            onCancel={() => {
              setOpen(undefined);
            }}
          />
          {retained.pad === undefined ? null : (
            <View
              style={styles.padControls}
              {...retained.input}>
              <PadFormatBar
                page={retained.pad}
                linkEditor={linkEditor}
                {...controls}
              />
            </View>
          )}
          {/* The body, files and fields scroll together when the keyboard leaves them too little
            room, as in landscape; the iPhone controls float over them above the keyboard. */}
          <ScrollView
            contentContainerStyle={[
              styles.scroll,
              { paddingBottom: phoneControlsInset(phone, open) },
            ]}
            keyboardShouldPersistTaps="handled">
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
              <Text
                accessibilityRole="alert"
                style={[styles.notice, { color: colors.textPrimary }]}>
                {t('drafts.evaluation.stopped')}
              </Text>
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
              <View style={styles.body}>
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
                  // Closing the Format panel returns to typing where the person left off.
                  keyboardDisplayRequiresUserAction={false}
                  mediaPlaybackRequiresUserAction
                  onContentProcessDidTerminate={stop}
                  onError={stop}
                  onMessage={({ nativeEvent }) => {
                    if (!mounted.current || pageStopped.current) {
                      return;
                    }
                    const message = decodeMessage(nativeEvent.data);
                    if (message === undefined) {
                      return;
                    }
                    // A paste carrying images, which native code reads from the pasteboard.
                    if (message.type === 'paste') {
                      void add('paste', true);
                      return;
                    }
                    if (message.type === 'key') {
                      slashKey(message.key);
                      return;
                    }
                    // A delayed report of an earlier body revision never replaces a newer one.
                    if (message.revision < (pageNow.current?.revision ?? 0)) {
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
                      frozen && next.revision === bodyRevision.current;
                    const was = pageNow.current?.selection;
                    slashMenu.moved(
                      pageNow.current,
                      next,
                      reported !== undefined,
                    );
                    pageNow.current = next;
                    setPageState(next);
                    if (reported === undefined || flushed) {
                      if (frozen) {
                        paused.current?.(true);
                      }
                      return;
                    }
                    bodyRevision.current = next.revision;
                    // Editing again retires captured text, as in the current composer.
                    forget();
                    const previous = authored.current;
                    // The host gives the page the Draft's text without its tables (#2865), and no paste
                    // makes a table, so the page reports none.
                    const { body, attachments } = knownAssets(known.current, {
                      document: textOf(reported),
                      attachments: attached,
                    });
                    change({
                      ...previous,
                      body: withText(previous.body, body),
                      ...(attachments.length === 0 &&
                      previous.attachments === undefined
                        ? {}
                        : { attachments }),
                    });
                    slashMenu.reported(
                      { body: textOf(previous.body), selection: was },
                      { ...next, body },
                    );
                    afterSlash(next.replaced);
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
                  style={[
                    styles.page,
                    { backgroundColor: colors.surfaceContent },
                  ]}
                />
                <PageSlashMenu
                  page={pageState}
                  viewport={viewport}
                  // On iPhone the menu ends 8pt above the floating controls.
                  reserve={Math.max(phoneControlsInset(phone, open), spacing.s)}
                  shown={slashMenu.shown}
                  titleOf={slashMenu.titleOf}
                  onChoose={chooseSlash}
                />
              </View>
            )}
            <DraftAssets
              draft={owned}
              editable={shown !== undefined}
              onCancel={(id) => {
                if (!busy.current) {
                  void store.cancelImport(id);
                }
              }}
              onConvert={(id) => {
                run({ type: 'convert', id });
              }}
              onPreview={showPreview}
              onRemove={removeAsset}
              onResize={(id, width) => {
                run({ type: 'resize', id, width: width ?? null });
              }}
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
          {retained.phone === undefined ? null : (
            <View
              style={[StyleSheet.absoluteFill, styles.controls]}
              {...retained.input}>
              <PhoneControls
                page={retained.phone}
                {...controls}
              />
            </View>
          )}
        </View>
        {retained.phone === undefined ? null : (
          <FormatPanel
            open={open === 'format'}
            active={retained.phone.marks}
            kind={retained.phone.kind}
            link={editableLinkAt(textOf(draft.body), retained.phone.selection)}
            linkEditor={linkEditor}
            undo={retained.phone.undo}
            redo={retained.phone.redo}
            disabled={false}
            onUndo={() => {
              run({ type: 'undo' });
            }}
            onRedo={() => {
              run({ type: 'redo' });
            }}
            onBlock={(kind) => {
              run({ type: 'block', kind });
            }}
            onMark={(mark) => {
              run({ type: 'mark', mark });
            }}
            onLink={editLink}
            onClose={() => {
              setOpen(undefined);
              run({ type: 'focus' });
            }}
            onHide={hide}
          />
        )}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

// A Draft that is not available yet, or never was, stays with the current composer's own views.
// Once open, the editor keeps its unsaved version even if the Draft is removed elsewhere, so
// Save Draft can still keep it as a copy.
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
  // The composer recovery record restored, which only the current composer opens.
  recovered?: Recovered | undefined;
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
  const draft = draftOf(useDrafts(), props.id);
  const mailboxes = use(AccountContext)?.mailboxes ?? [];
  // An editor outlives its Draft's removal elsewhere, so it keeps the sender it opened with.
  const [owner, setOwner] = useState({
    id: props.id,
    connection: draft?.connection,
  });
  if (
    draft !== undefined &&
    (owner.id !== props.id || owner.connection !== draft.connection)
  ) {
    setOwner({ id: props.id, connection: draft.connection });
  }
  const connection =
    owner.id === props.id ? owner.connection : draft?.connection;
  // Assistance for a Draft follows the consent of the Mail Profile that owns its sender.
  return (
    <ProfileMailAssistanceGate profile={profileOf(connection, mailboxes)}>
      {editorPage === undefined || props.recovered !== undefined ? (
        <Composer {...props} />
      ) : (
        <EvaluationComposer
          page={editorPage}
          {...props}
        />
      )}
    </ProfileMailAssistanceGate>
  );
}
