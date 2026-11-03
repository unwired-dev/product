import type { Command, Update } from '@private-email/draft-editor/messages';
import type { DraftTextPurpose } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { Link } from '@private-email/mail-core/semantic-document';
import type { ReactNode } from 'react';

import {
  canRewrite,
  canSuggestReply,
} from '@private-email/mail-core/assistance';
import {
  clip,
  editableLinkAt,
  selectedText,
} from '@private-email/mail-core/semantic-document';
import { spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import { use } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';

import { Action } from './action.tsx';
import { CommandInput, usePaletteHeader } from './command-palette.tsx';
import { FormatBar, LinkEditor, MenuItem } from './composer-controls.tsx';
import {
  assetPickers,
  CloseButton,
  ComposerLayoutContext,
  composerStyles,
  Recipients,
  SendButton,
  textToolLabel,
} from './composer.tsx';
import {
  GlassGroup,
  GlassPanel,
  ToolbarButton,
  useMenuMotion,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { AssistanceContext } from './message-summary.tsx';
import { usePalette } from './theme.ts';
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
});

export type PageState = Omit<Update, 'type' | 'document' | 'attachments'>;
// The open menu, or on iPhone the Format panel in place of the keyboard.
export type Open = 'close' | 'attach' | 'tools' | 'format';
type Add = (source: PickSource, inline: boolean) => void;
type Capture = (purpose: DraftTextPurpose) => void;
type EditLink = (link: Link, text: string, href?: string) => void;

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
          accessibilityLabel={t(textToolLabel('rewrite', selection))}
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
          {assetPickers.map(([label, from, inline]) => (
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
          style={s.pill}>
          <GlassGroup style={s.pillGroup}>
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
            <GlassGroup style={s.pillGroup}>
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
  onLink,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly open: Open | undefined;
  readonly run: (command: Command) => void;
  readonly onOpen: (open: Open | undefined) => void;
  readonly onAdd: Add;
  readonly onCapture: Capture;
  readonly onLink: EditLink;
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
        <LinkEditor
          disabled={false}
          link={editableLinkAt(draft.body, page.selection)}
          popover
          onChange={onLink}
        />
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
        {assetPickers.map(([label, from, inline, icon]) => (
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
          <CloseButton
            disabled={busy}
            expanded={closeOpen}
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
