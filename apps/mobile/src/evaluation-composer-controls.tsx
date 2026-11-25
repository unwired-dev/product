import type { Command, Update } from '@private-email/draft-editor/messages';
import type { DraftTextPurpose } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { Link } from '@private-email/mail-core/semantic-document';
import type { ReactNode, RefObject } from 'react';
import type { ViewInstance } from 'react-native';

import {
  canRewrite,
  canSuggestReply,
} from '@private-email/mail-core/assistance';
import {
  clip,
  editableLinkAt,
  selectedText,
  textOf,
} from '@private-email/mail-core/semantic-document';
import { spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import { use } from 'react';
import { Platform, StyleSheet, Text, TextInput, View } from 'react-native';

import type { LinkEditorState } from './composer-controls.tsx';

import { Action } from './action.tsx';
import { CommandInput, usePaletteHeader } from './command-palette.tsx';
import { FormatBar, LinkEditor, OverflowMenu } from './composer-controls.tsx';
import {
  assetPickers,
  CloseButton,
  ComposerLayoutContext,
  composerStyles,
  fieldSlop,
  layoutStyles,
  Recipients,
  SendButton,
  textToolLabel,
  textToolSymbols,
} from './composer.tsx';
import {
  GlassGroup,
  MenuButton,
  scaledToolbar,
  SFSymbol,
  ToolbarButton,
  useMenuMotion,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { AssistanceContext } from './message-summary.tsx';
import { usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const s = composerStyles;
const iphone = Platform.OS === 'ios' && !Platform.isPad;
const styles = StyleSheet.create({
  header: { flexWrap: 'wrap' },
  headerLeading: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  regularHeaderLeading: { flexBasis: '50%' },
  headerTrailing: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    maxWidth: '100%',
    marginLeft: 'auto',
  },
  sender: { flexShrink: 1 },
});

export type PageState = Omit<Update, 'type' | 'document' | 'attachments'>;
// The Close question, or on iPhone the Format panel in place of the keyboard.
export type Open = 'close' | 'format';
type Add = (source: PickSource, inline: boolean) => void;
type Capture = (purpose: DraftTextPurpose) => void;
type EditLink = (link: Link, text: string, href?: string) => void;

// The writing tools the Draft's body offers now, in the system menu: today's Rewrite, Translate and
// Suggest Reply. They appear only where assistance or translation is available.
function WritingTools({
  draft,
  page,
  popover,
  onCapture,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly popover: boolean;
  readonly onCapture: Capture;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  if (assistance === undefined && translation === undefined) {
    return null;
  }
  const { selection } = page;
  const rewrite = {
    key: 'rewrite',
    title: t('assistance.rewrite'),
    accessibilityLabel: t(textToolLabel('rewrite', selection)),
    symbol: textToolSymbols.rewrite,
    disabled: !canRewrite(draft.body, selection),
    run: () => {
      onCapture('rewrite');
    },
  };
  const translate = {
    key: 'translate',
    title: t('translation.translate'),
    accessibilityLabel: t('translation.translateSelectionLabel'),
    symbol: 'translate',
    disabled: !hasTranslatableText(
      selectedText(textOf(draft.body), selection, translationInputLimit + 1),
    ),
    run: () => {
      onCapture('translate');
    },
  };
  const suggestReply = {
    key: 'reply',
    title: t('assistance.suggestReply'),
    accessibilityLabel: t('assistance.suggestReplyLabel'),
    symbol: '',
    run: () => {
      onCapture('reply');
    },
  };
  const menu = (
    <MenuButton
      accessibilityLabel={t('drafts.writingTools')}
      alignMenuToRowEnd={iphone && !popover}
      sections={[
        {
          items: [
            ...(assistance === undefined ? [] : [rewrite]),
            ...(translation === undefined ? [] : [translate]),
            ...(assistance !== undefined && canSuggestReply(draft)
              ? [suggestReply]
              : []),
          ],
        },
      ]}
      style={s.menuControl}>
      <SFSymbol
        name="sparkles"
        size={popover ? scaledToolbar.symbol : 20}
        color={colors.textPrimary}
      />
    </MenuButton>
  );
  // On iPhone the menu floats in its own glass beside the pill.
  return popover ? menu : <GlassGroup style={s.pillGroup}>{menu}</GlassGroup>;
}

// Finishing retires input immediately while the controls' menus complete their exit.
export function useRetainedControls(
  page: PageState | undefined,
  active: boolean,
  size: 'compact' | 'regular',
) {
  const motion = useMenuMotion(active, 'menu');
  const retained = motion.shown ? page : undefined;
  const pointerEvents: 'box-none' | 'none' = active ? 'box-none' : 'none';
  return {
    phone: size === 'compact' ? retained : undefined,
    pad: size === 'regular' ? retained : undefined,
    input: {
      accessibilityElementsHidden: !active,
      pointerEvents,
    },
  };
}

// Leave room to scroll the final field above the 52pt controls and their 8pt insets.
export function phoneControlsInset(
  page: PageState | undefined,
  open: Open | undefined,
) {
  return page === undefined || open === 'format'
    ? 0
    : 44 + 2 * spacing.xs + 2 * spacing.s;
}

// iPhone adds files and offers writing tools from a floating Liquid Glass pill and button, whose
// Format control opens the panel that replaces the keyboard.
export function PhoneControls({
  draft,
  page,
  open,
  run,
  onOpen,
  onAdd,
  onCapture,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly open: Open | undefined;
  readonly run: (command: Command) => void;
  readonly onOpen: (open: Open | undefined) => void;
  readonly onAdd: Add;
  readonly onCapture: Capture;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return open === 'format' ? null : (
    <View
      collapsable={!iphone}
      pointerEvents="box-none"
      style={s.pill}>
      <GlassGroup style={[s.pillGroup, iphone && s.formatPill]}>
        <ToolbarButton
          icon="textformat"
          label={t('drafts.format')}
          onPress={() => {
            run({ type: 'blur' });
            onOpen('format');
          }}
        />
        <MenuButton
          accessibilityLabel={t('drafts.assets.toolbar')}
          alignMenuToRowEnd={iphone}
          sections={[
            {
              items: assetPickers.map(([label, from, inline, icon]) => ({
                key: label,
                title: t(label),
                // The paperclip opens this menu, so its Attach File row shows a document.
                symbol: from === 'files' ? 'doc' : icon,
                run: () => {
                  onAdd(from, inline);
                },
              })),
            },
          ]}
          style={s.menuControl}>
          <SFSymbol
            name="paperclip"
            size={20}
            color={colors.textPrimary}
          />
        </MenuButton>
      </GlassGroup>
      <WritingTools
        draft={draft}
        page={page}
        popover={false}
        onCapture={onCapture}
      />
    </View>
  );
}

// iPad keeps the current composer's format bar, with Writing tools in place of its separate
// assistance buttons.
export function PadFormatBar({
  draft,
  page,
  run,
  onAdd,
  onCapture,
  onLink,
  linkEditor,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly run: (command: Command) => void;
  readonly onAdd: Add;
  readonly onCapture: Capture;
  readonly onLink: EditLink;
  readonly linkEditor: LinkEditorState;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const travels = [
    {
      key: 'undo',
      title: t('drafts.undo'),
      symbol: 'arrow.uturn.backward',
      disabled: !page.undo,
      run: () => {
        run({ type: 'undo' });
      },
    },
    {
      key: 'redo',
      title: t('drafts.redo'),
      symbol: 'arrow.uturn.forward',
      disabled: !page.redo,
      run: () => {
        run({ type: 'redo' });
      },
    },
  ];
  const assets = assetPickers.map(([label, from, inline, icon]) => ({
    key: label,
    title: t(label),
    symbol: icon,
    run: () => {
      onAdd(from, inline);
    },
  }));
  return (
    <FormatBar
      active={page.marks}
      kind={page.kind}
      disabled={false}
      onBlock={(kind) => {
        run({ type: 'block', kind });
      }}
      onMark={(mark) => {
        run({ type: 'mark', mark });
      }}>
      {(lists) => (
        <>
          <LinkEditor
            state={linkEditor}
            disabled={false}
            link={editableLinkAt(textOf(draft.body), page.selection)}
            popover
            {...(lists === undefined
              ? {}
              : {
                  renderMenu: (link) => (
                    <OverflowMenu
                      accessibilityLabel={t('drafts.moreLists')}
                      disabled={false}
                      sections={[
                        { items: [...lists, link] },
                        { items: travels },
                      ]}
                    />
                  ),
                })}
            onChange={onLink}
          />
          {lists === undefined ? (
            <>
              <View
                style={[s.divider, { backgroundColor: colors.separator }]}
              />
              {travels.map((item) => (
                <ToolbarButton
                  key={item.key}
                  disabled={item.disabled}
                  icon={item.symbol}
                  label={item.title}
                  onPress={() => {
                    item.run();
                  }}
                />
              ))}
            </>
          ) : null}
          <View style={s.grow} />
          <WritingTools
            draft={draft}
            page={page}
            popover
            onCapture={onCapture}
          />
          <View style={[s.divider, { backgroundColor: colors.separator }]} />
          {assets.slice(0, lists === undefined ? undefined : 1).map((item) => (
            <ToolbarButton
              key={item.key}
              icon={item.symbol}
              label={item.title}
              onPress={() => {
                item.run();
              }}
            />
          ))}
          {lists === undefined ? null : (
            <OverflowMenu
              accessibilityLabel={t('drafts.moreFileActions')}
              disabled={false}
              sections={[{ items: assets.slice(1) }]}
            />
          )}
        </>
      )}
    </FormatBar>
  );
}

// Subject, To, and Cc and Bcc once shown, below the body.
export function DraftFields({
  draft,
  getDraft,
  editable,
  onChange,
  onCaretMove,
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly editable: boolean;
  readonly onChange: (draft: Draft) => void;
  readonly onCaretMove: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { size } = use(ComposerLayoutContext);
  const sized = layoutStyles[size];
  // Once Cc or Bcc is shown or holds a recipient, both stay shown for the Draft.
  const copiesShown =
    draft.copies === true || draft.cc.length + draft.bcc.length > 0;
  const recipients = (field: 'to' | 'cc' | 'bcc', trailing?: ReactNode) => (
    <Recipients
      draft={draft}
      getDraft={getDraft}
      editable={editable}
      field={field}
      onChange={onChange}
      onCaretMove={onCaretMove}
      trailing={trailing}
    />
  );
  return (
    <View style={[s.fields, sized.fields]}>
      <View
        style={[s.field, sized.field, { borderTopColor: colors.separator }]}>
        <Text
          style={[
            s.fieldLabel,
            sized.fieldLabel,
            { color: colors.textSecondary },
          ]}>
          {`${t('drafts.subject')}:`}
        </Text>
        <TextInput
          accessibilityLabel={t('drafts.subject')}
          editable={editable}
          accessibilityState={{ disabled: !editable }}
          onChangeText={(subject) => {
            onChange({ ...getDraft(), subject });
          }}
          hitSlop={fieldSlop[size]}
          // iPad's Subject label already names the empty field.
          placeholder={size === 'regular' ? undefined : t('drafts.subject')}
          placeholderTextColor={colors.textSecondary}
          style={[s.input, sized.input, { color: colors.textPrimary }]}
          value={draft.subject}
        />
      </View>
      {recipients(
        'to',
        copiesShown ? undefined : (
          <Action
            variant="composer"
            disabled={!editable}
            accessibilityLabel={t('drafts.showCcBcc')}
            label={t('drafts.ccBcc')}
            onPress={() => {
              onChange({ ...getDraft(), copies: true });
            }}
          />
        ),
      )}
      {copiesShown ? (
        <>
          {recipients('cc')}
          {recipients('bcc')}
        </>
      ) : null}
    </View>
  );
}

// The current composer's header: the glass Close, the title, which opens the Command Palette by a
// downward swipe as other screens' do, the window's expand control and Send. On iPad,
// From stays beside Send; that pair wraps together when the reading pane is narrow.
export function EditorHeader({
  subject,
  busy,
  closeOpen,
  closeAnchor,
  sender,
  expanded = false,
  onExpand,
  onClose,
  onSend,
}: {
  readonly subject: string;
  // Save Draft, Delete Draft or Send is running.
  readonly busy: boolean;
  readonly closeOpen: boolean;
  readonly closeAnchor: RefObject<ViewInstance | null>;
  readonly sender: ReactNode;
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
  readonly onClose: () => void;
  readonly onSend: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const paletteHeader = usePaletteHeader();
  const regular = use(ComposerLayoutContext).size === 'regular';
  const title = clip(subject) || t('drafts.newMessage');
  const titleLabel =
    title.length < subject.length
      ? t('drafts.titleShortened', { title })
      : title;
  return (
    <>
      <View
        style={[s.header, regular ? styles.header : null]}
        {...paletteHeader.swipe}>
        <View
          style={[
            styles.headerLeading,
            regular ? styles.regularHeaderLeading : null,
          ]}>
          <CloseButton
            disabled={busy}
            expanded={closeOpen}
            anchor={closeAnchor}
            onPress={onClose}
          />
          <Text
            accessibilityLabel={titleLabel}
            accessibilityRole="header"
            numberOfLines={1}
            style={[s.grow, s.title, { color: colors.textPrimary }]}
            {...paletteHeader.action}>
            {title}
          </Text>
          <CommandInput />
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
        <View style={styles.headerTrailing}>
          {regular ? <View style={styles.sender}>{sender}</View> : null}
          <SendButton
            disabled={busy}
            onPress={onSend}
          />
        </View>
      </View>
      {regular ? null : (
        <View style={s.fromRow}>
          <View style={s.bar}>{sender}</View>
        </View>
      )}
    </>
  );
}
