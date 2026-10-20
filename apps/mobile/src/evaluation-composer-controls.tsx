import type { Command, Update } from '@private-email/draft-editor/messages';
import type { CapturedDraftText } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { ReactNode } from 'react';

import {
  canRewrite,
  canSuggestReply,
} from '@private-email/mail-core/assistance';
import { clip, selectedText } from '@private-email/mail-core/semantic-document';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import { use, useEffect } from 'react';
import {
  Keyboard,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { CommandInput, usePaletteHeader } from './command-palette.tsx';
import {
  blockControls,
  FormatBar,
  markControls,
  MenuItem,
} from './composer-controls.tsx';
import {
  Action,
  ComposerLayoutContext,
  composerStyles,
  Recipients,
  rewriteLabel,
} from './composer.tsx';
import {
  Glass,
  GlassGroup,
  GlassPanel,
  SFSymbol,
  ToolbarButton,
  useMenuMotion,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { AssistanceContext } from './message-summary.tsx';
import { textStyles, usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const s = composerStyles;
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
  // The iPhone controls float at the trailing edge above the keyboard, with their menus above.
  pill: {
    position: 'absolute',
    right: spacing.l,
    bottom: spacing.s,
    flexDirection: 'row',
    gap: 10,
  },
  pillGroup: { borderRadius: 26 },
  // Above the content below it, so the Writing tools menu opens over the body.
  padBar: { zIndex: 1 },
  padMenu: {
    position: 'absolute',
    top: '100%',
    right: spacing.l,
    minWidth: 240,
  },
  pillMenu: {
    position: 'absolute',
    zIndex: 4,
    right: spacing.l,
    bottom: 64,
    minWidth: 240,
  },
  format: { margin: spacing.s, marginTop: 0 },
  formatContent: { padding: spacing.l, gap: spacing.m },
  formatHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
  formatTitle: { ...textStyles.title3Emphasized, flex: 1 },
  formatClose: { borderRadius: radius.insetGroup },
  formatRow: {
    flexDirection: 'row',
    gap: spacing.s,
  },
  formatStyles: {
    flexDirection: 'row',
    padding: spacing.xs,
    borderRadius: radius.insetGroup,
  },
  formatGroup: {
    flex: 1,
    flexDirection: 'row',
    borderRadius: radius.insetGroup,
    overflow: 'hidden',
  },
  formatChoice: {
    flex: 1,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.insetGroup - spacing.xs,
  },
});

export type PageState = Omit<Update, 'type' | 'document' | 'attachments'>;
// The open menu, or on iPhone the Format panel in place of the keyboard.
export type Open = 'close' | 'attach' | 'tools' | 'format';
type Add = (source: PickSource, inline: boolean) => void;
type Capture = (purpose: CapturedDraftText['purpose']) => void;

// The current composer's file controls: the system pickers, and images on the pasteboard placed
// inline. Native code reads the chosen files.
const pickers = [
  ['drafts.assets.attachFile', 'files', false, 'paperclip'],
  ['drafts.assets.attachPhoto', 'photos', false, 'photo'],
  ['drafts.assets.insertImage', 'photos', true, 'photo.on.rectangle'],
  ['drafts.assets.pasteImage', 'paste', true, 'doc.on.clipboard'],
] as const;
const headings = ['heading1', 'heading2', 'heading3', 'paragraph'] as const;
const markGroups = {
  marks: markControls.slice(0, 4),
  code: markControls.slice(4),
};
const blockGroups = {
  lists: blockControls.slice(3, 5),
  text: blockControls.slice(5),
};

// The writing tools the Draft's body offers now: today's Rewrite, Translate and Suggest reply.
function WritingTools({
  draft,
  page,
  onCapture,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly onCapture: Capture;
}) {
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  const { selection } = page;
  return (
    <>
      {assistance === undefined ? null : (
        <MenuItem
          disabled={!canRewrite(draft.body, selection)}
          label={t('assistance.rewrite')}
          accessibilityLabel={t(rewriteLabel(selection))}
          selected={false}
          onPress={() => {
            onCapture('rewrite');
          }}
        />
      )}
      {translation === undefined ? null : (
        <MenuItem
          disabled={
            !hasTranslatableText(
              selectedText(draft.body, selection, translationInputLimit + 1),
            )
          }
          label={t('translation.translate')}
          accessibilityLabel={t('translation.translateSelectionLabel')}
          selected={false}
          onPress={() => {
            onCapture('translate');
          }}
        />
      )}
      {assistance !== undefined && canSuggestReply(draft) ? (
        <MenuItem
          label={t('assistance.suggestReply')}
          accessibilityLabel={t('assistance.suggestReplyLabel')}
          selected={false}
          onPress={() => {
            onCapture('reply');
          }}
        />
      ) : null}
    </>
  );
}

// Writing tools appear only where assistance or translation is available.
function useOffersTools() {
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  return assistance !== undefined || translation !== undefined;
}

// One choice in the Format panel, filled while it applies at the selection.
function FormatChoice({
  name,
  selected,
  command,
  run,
  children,
}: {
  readonly name: string;
  readonly selected: boolean;
  readonly command: Command;
  readonly run: (command: Command) => void;
  readonly children: (color: string) => ReactNode;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={name}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={() => {
        run(command);
      }}
      style={[
        styles.formatChoice,
        selected && { backgroundColor: colors.accentFill },
      ]}>
      {children(selected ? colors.accentOnFill : colors.textPrimary)}
    </Pressable>
  );
}

// The iPhone Format panel, which replaces the keyboard: Undo and Redo, text styles, marks and the
// remaining block kinds, each one page command.
export function FormatPanel({
  open,
  page,
  run,
  onClose,
  onHide,
}: {
  readonly open: boolean;
  readonly page: PageState;
  readonly run: (command: Command) => void;
  // Closes the panel and resumes typing; `onHide` only closes it.
  readonly onClose: () => void;
  readonly onHide: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // Tapping into the body again brings the keyboard back in place of the panel.
  useEffect(() => {
    if (!open) {
      return;
    }
    const shown = Keyboard.addListener('keyboardWillShow', onHide);
    return () => {
      shown.remove();
    };
  }, [onHide, open]);
  const rowFill = { backgroundColor: colors.fillQuiet };
  return (
    <GlassPanel
      open={open}
      style={styles.format}
      cornerRadius={radius.formatPanel}>
      <View
        accessibilityLabel={t('drafts.formatting')}
        accessibilityRole="toolbar"
        style={styles.formatContent}>
        <View style={styles.formatHeader}>
          <Text
            accessibilityRole="header"
            style={[styles.formatTitle, { color: colors.textPrimary }]}>
            {t('drafts.format')}
          </Text>
          <ToolbarButton
            disabled={!page.undo}
            icon="arrow.uturn.backward"
            label={t('drafts.undo')}
            onPress={() => {
              run({ type: 'undo' });
            }}
          />
          <ToolbarButton
            disabled={!page.redo}
            icon="arrow.uturn.forward"
            label={t('drafts.redo')}
            onPress={() => {
              run({ type: 'redo' });
            }}
          />
          <View style={[styles.formatClose, rowFill]}>
            <ToolbarButton
              icon="xmark"
              label={t('drafts.closeFormat')}
              onPress={onClose}
            />
          </View>
        </View>
        <View style={[styles.formatStyles, rowFill]}>
          {headings.map((kind) => {
            const name = t(
              `drafts.blocks.${kind === 'paragraph' ? 'body' : kind}`,
            );
            return (
              <FormatChoice
                key={kind}
                command={{ type: 'block', kind }}
                name={name}
                run={run}
                selected={page.kind === kind}>
                {(color) => (
                  <Text style={[textStyles.subheadline, { color }]}>
                    {name}
                  </Text>
                )}
              </FormatChoice>
            );
          })}
        </View>
        <View style={styles.formatRow}>
          {Object.entries(markGroups).map(([key, group]) => (
            <View
              key={key}
              style={[
                styles.formatGroup,
                rowFill,
                { minWidth: group.length * 44 },
              ]}>
              {group.map(([mark, , name]) => (
                <FormatChoice
                  key={mark}
                  command={{ type: 'mark', mark }}
                  name={t(name)}
                  run={run}
                  selected={page.marks.includes(mark)}>
                  {(color) => (
                    <SFSymbol
                      name={
                        mark === 'code'
                          ? 'chevron.left.forwardslash.chevron.right'
                          : mark
                      }
                      size={20}
                      color={color}
                    />
                  )}
                </FormatChoice>
              ))}
            </View>
          ))}
        </View>
        <View style={styles.formatRow}>
          {/* Lists, quotes and code blocks follow the three headings. */}
          {Object.entries(blockGroups).map(([key, group]) => (
            <View
              key={key}
              style={[styles.formatGroup, rowFill]}>
              {group.map(([kind, , name]) => (
                <FormatChoice
                  key={kind}
                  command={{ type: 'block', kind }}
                  name={t(name)}
                  run={run}
                  selected={page.kind === kind}>
                  {(color) =>
                    kind === 'bulleted' || kind === 'numbered' ? (
                      <SFSymbol
                        name={
                          kind === 'bulleted' ? 'list.bullet' : 'list.number'
                        }
                        size={20}
                        color={color}
                      />
                    ) : (
                      <SFSymbol
                        name={
                          kind === 'quote' ? 'quote.opening' : 'curlybraces'
                        }
                        size={20}
                        color={color}
                      />
                    )
                  }
                </FormatChoice>
              ))}
            </View>
          ))}
        </View>
      </View>
    </GlassPanel>
  );
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
  const { t } = useLocalization();
  const offersTools = useOffersTools();
  const toggle = (menu: Open) => {
    onOpen(open === menu ? undefined : menu);
  };
  return (
    <>
      <View
        accessibilityRole="menu"
        accessibilityElementsHidden={open !== 'attach'}
        pointerEvents={open === 'attach' ? 'box-none' : 'none'}
        style={styles.pillMenu}>
        <GlassPanel
          open={open === 'attach'}
          origin="bottom right">
          {pickers.map(([label, from, inline]) => (
            <MenuItem
              key={label}
              label={t(label)}
              selected={false}
              onPress={() => {
                onAdd(from, inline);
              }}
            />
          ))}
        </GlassPanel>
      </View>
      <View
        accessibilityRole="menu"
        accessibilityElementsHidden={open !== 'tools'}
        pointerEvents={open === 'tools' ? 'box-none' : 'none'}
        style={styles.pillMenu}>
        <GlassPanel
          open={open === 'tools'}
          origin="bottom right">
          <WritingTools
            draft={draft}
            page={page}
            onCapture={onCapture}
          />
        </GlassPanel>
      </View>
      {open === 'format' ? null : (
        <View
          pointerEvents="box-none"
          style={styles.pill}>
          <GlassGroup style={styles.pillGroup}>
            <ToolbarButton
              icon="textformat"
              label={t('drafts.format')}
              onPress={() => {
                run({ type: 'blur' });
                onOpen('format');
              }}
            />
            <ToolbarButton
              expanded={open === 'attach'}
              icon="paperclip"
              label={t('drafts.assets.toolbar')}
              onPress={() => {
                toggle('attach');
              }}
            />
          </GlassGroup>
          {offersTools ? (
            <GlassGroup style={styles.pillGroup}>
              <ToolbarButton
                expanded={open === 'tools'}
                icon="sparkles"
                label={t('drafts.writingTools')}
                onPress={() => {
                  toggle('tools');
                }}
              />
            </GlassGroup>
          ) : null}
        </View>
      )}
    </>
  );
}

// iPad keeps the current composer's format bar, with Writing tools in place of its separate
// assistance buttons.
export function PadFormatBar({
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
  const offersTools = useOffersTools();
  return (
    <View style={styles.padBar}>
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
        <View style={[s.divider, { backgroundColor: colors.separator }]} />
        <ToolbarButton
          disabled={!page.undo}
          icon="arrow.uturn.backward"
          label={t('drafts.undo')}
          onPress={() => {
            run({ type: 'undo' });
          }}
        />
        <ToolbarButton
          disabled={!page.redo}
          icon="arrow.uturn.forward"
          label={t('drafts.redo')}
          onPress={() => {
            run({ type: 'redo' });
          }}
        />
        <View style={s.grow} />
        {offersTools ? (
          <ToolbarButton
            expanded={open === 'tools'}
            icon="sparkles"
            label={t('drafts.writingTools')}
            onPress={() => {
              onOpen(open === 'tools' ? undefined : 'tools');
            }}
          />
        ) : null}
        <View style={[s.divider, { backgroundColor: colors.separator }]} />
        {pickers.map(([label, from, inline, icon]) => (
          <ToolbarButton
            key={label}
            icon={icon}
            label={t(label)}
            onPress={() => {
              onAdd(from, inline);
            }}
          />
        ))}
      </FormatBar>
      {/* The bar's controls scroll and would clip the menu, so it opens below the bar. */}
      <View
        accessibilityRole="menu"
        accessibilityElementsHidden={open !== 'tools'}
        pointerEvents={open === 'tools' ? 'box-none' : 'none'}
        style={styles.padMenu}>
        <GlassPanel open={open === 'tools'}>
          <WritingTools
            draft={draft}
            page={page}
            onCapture={onCapture}
          />
        </GlassPanel>
      </View>
    </View>
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
    <View style={s.fields}>
      <View style={[s.field, { borderTopColor: colors.separator }]}>
        <Text style={[s.fieldLabel, { color: colors.textSecondary }]}>
          {`${t('drafts.subject')}:`}
        </Text>
        <TextInput
          accessibilityLabel={t('drafts.subject')}
          editable={editable}
          accessibilityState={{ disabled: !editable }}
          onChangeText={(subject) => {
            onChange({ ...getDraft(), subject });
          }}
          placeholder={t('drafts.subject')}
          placeholderTextColor={colors.textSecondary}
          style={[s.input, { color: colors.textPrimary }]}
          value={draft.subject}
        />
      </View>
      {recipients(
        'to',
        copiesShown ? undefined : (
          <Action
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
          <Pressable
            accessibilityLabel={t('drafts.close')}
            accessibilityRole="button"
            accessibilityState={{ disabled: busy, expanded: closeOpen }}
            disabled={busy}
            onPress={onClose}
            style={[s.circle, { boxShadow: colors.smallGlassShadow }]}>
            <Glass cornerRadius={22} />
            <SFSymbol
              name="xmark"
              color={colors.textPrimary}
            />
          </Pressable>
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
          <Pressable
            accessibilityLabel={t('drafts.send')}
            accessibilityRole="button"
            accessibilityState={{ disabled: busy }}
            disabled={busy}
            onPress={onSend}
            style={[s.circle, { backgroundColor: colors.accentFill }]}>
            <SFSymbol
              name="arrow.up"
              color={colors.accentOnFill}
            />
          </Pressable>
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
