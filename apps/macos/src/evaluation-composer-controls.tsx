import type { Command, Update } from '@private-email/draft-editor/messages';
import type { CapturedDraftText } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { ReactNode } from 'react';

import {
  canRewrite,
  canSuggestReply,
} from '@private-email/mail-core/assistance';
import { selectedText } from '@private-email/mail-core/semantic-document';
import { spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import { use, useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, TextInput, View } from 'react-native';

import { FormatBar, PopUp } from './composer-controls.tsx';
import {
  Action,
  composerStyles,
  Recipients,
  rewriteLabel,
} from './composer.tsx';
import {
  Button,
  GlassPanel,
  ModalBackground,
  ToolbarButton,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { AssistanceContext } from './message-summary.tsx';
import { textStyles, usePalette } from './theme.ts';
import { TranslationContext } from './translation.tsx';

const s = composerStyles;
const styles = StyleSheet.create({
  // The save question drops from the window's top edge, over the composer.
  sheet: {
    position: 'absolute',
    zIndex: 4,
    top: 52,
    alignSelf: 'center',
    width: 300,
  },
  sheetContent: { padding: 20, gap: spacing.s },
  sheetTitle: { ...textStyles.bodyEmphasized, textAlign: 'center' },
  sheetDetail: { ...textStyles.subheadline, textAlign: 'center' },
});

export type PageState = Omit<Update, 'type' | 'document' | 'attachments'>;
type Capture = (purpose: CapturedDraftText['purpose']) => void;

// The current composer's file controls, through the system open panel. Native code reads the
// chosen files.
const pickers = [
  ['drafts.assets.attachFilesPanel', 'files', false, 'paperclip'],
  ['drafts.assets.insertImagePanel', 'photos', true, 'photo.on.rectangle'],
] as const;

// The current composer's format bar, with Writing tools in place of its separate assistance
// buttons; each control is one page command.
export function PageFormatBar({
  draft,
  page,
  run,
  onAdd,
  onCapture,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly run: (command: Command) => void;
  readonly onAdd: (source: PickSource, inline: boolean) => void;
  readonly onCapture: Capture;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
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
      {assistance === undefined && translation === undefined ? null : (
        <PopUp
          accessibilityLabel={t('drafts.writingTools')}
          icon="sparkles"
          items={[
            ...(assistance === undefined
              ? []
              : [
                  {
                    key: 'rewrite',
                    title: t('assistance.rewrite'),
                    accessibilityLabel: t(rewriteLabel(page.selection)),
                    disabled: !canRewrite(draft.body, page.selection),
                    run: () => {
                      onCapture('rewrite');
                    },
                  },
                ]),
            ...(translation === undefined
              ? []
              : [
                  {
                    key: 'translate',
                    title: t('translation.translate'),
                    accessibilityLabel: t(
                      'translation.translateSelectionLabel',
                    ),
                    disabled: !hasTranslatableText(
                      selectedText(
                        draft.body,
                        page.selection,
                        translationInputLimit + 1,
                      ),
                    ),
                    run: () => {
                      onCapture('translate');
                    },
                  },
                ]),
            ...(assistance !== undefined && canSuggestReply(draft)
              ? [
                  {
                    key: 'reply',
                    title: t('assistance.suggestReply'),
                    accessibilityLabel: t('assistance.suggestReplyLabel'),
                    run: () => {
                      onCapture('reply');
                    },
                  },
                ]
              : []),
          ]}
        />
      )}
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

// Only the save choices remain interactive and accessible while the question is open.
export function SaveBackground({
  active,
  children,
}: {
  readonly active: boolean;
  readonly children: ReactNode;
}) {
  return (
    <ModalBackground
      accessibilityElementsHidden={active}
      pointerEvents={active ? 'none' : 'auto'}
      style={s.fill}>
      {children}
    </ModalBackground>
  );
}

// Asks whether to keep changed Draft content, as Mail does when a message window closes.
export function SaveSheet({
  open,
  onSave,
  onDelete,
  onCancel,
}: {
  readonly open: boolean;
  readonly onSave: () => void;
  readonly onDelete: () => void;
  readonly onCancel: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const buttons = useRef<Array<View | null>>([]);
  const [focused, setFocused] = useState<number>();
  if (!open && focused !== undefined) {
    setFocused(undefined);
  }
  const choices = [
    { label: t('drafts.saveAction'), onPress: onSave },
    { label: t('drafts.dontSave'), onPress: onDelete },
    { label: t('common.cancel'), onPress: onCancel },
  ];
  const focusChoice = (index: number) => {
    const button = buttons.current[index];
    if (button !== null && button !== undefined && 'focus' in button) {
      button.focus();
    }
  };
  useEffect(() => {
    if (!open) {
      for (const button of buttons.current) {
        if (button !== null && 'blur' in button) {
          button.blur();
        }
      }
      return;
    }
    const [first] = buttons.current;
    if (first !== null && first !== undefined && 'focus' in first) {
      first.focus();
    }
  }, [open]);
  return (
    <View
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'box-none' : 'none'}
      accessibilityViewIsModal={open}
      onAccessibilityEscape={onCancel}
      keyDownEvents={[
        { key: 'Escape' },
        { key: 'Tab' },
        { key: 'Tab', shiftKey: true },
      ]}
      onKeyDown={({ nativeEvent }) => {
        if (!open) {
          return;
        }
        if (nativeEvent.key === 'Escape') {
          onCancel();
        } else if (nativeEvent.key === 'Tab') {
          const step = nativeEvent.shiftKey ? -1 : 1;
          const from = focused ?? (step === -1 ? 0 : -1);
          focusChoice((from + step + choices.length) % choices.length);
        }
      }}
      style={styles.sheet}>
      <GlassPanel
        open={open}
        origin="top">
        <View style={styles.sheetContent}>
          <Text
            selectable
            accessibilityRole="header"
            style={[styles.sheetTitle, { color: colors.textPrimary }]}>
            {t('drafts.saveQuestion')}
          </Text>
          <Text
            selectable
            style={[styles.sheetDetail, { color: colors.textSecondary }]}>
            {t('drafts.saveQuestionDetail')}
          </Text>
          {choices.map(({ label, onPress }, index) => (
            <Button
              key={label}
              disabled={!open}
              ref={(button) => {
                buttons.current[index] = button;
              }}
              onFocus={() => {
                setFocused(index);
              }}
              onBlur={() => {
                setFocused(undefined);
              }}
              fill={index === 0 ? 'accent' : 'quiet'}
              label={label}
              onPress={onPress}
            />
          ))}
        </View>
      </GlassPanel>
    </View>
  );
}
