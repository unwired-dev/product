import type { Command, Update } from '@private-email/draft-editor/messages';
import type { CapturedDraftText } from '@private-email/mail-core/assistance';
import type { Draft, PickSource } from '@private-email/mail-core/drafts';
import type { Link } from '@private-email/mail-core/semantic-document';
import type { TranslationLanguage } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';

import { editableLinkAt } from '@private-email/mail-core/semantic-document';
import { Text, TextInput, View } from 'react-native';

import { Action } from './action.tsx';
import { FormatBar, LinkEditor } from './composer-controls.tsx';
import { composerStyles, Recipients, WritingTools } from './composer.tsx';
import { ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

const s = composerStyles;

export type PageState = Omit<Update, 'type' | 'document' | 'attachments'>;
type Capture = (
  purpose: CapturedDraftText['purpose'],
  target?: TranslationLanguage,
) => void;

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
  onLink,
}: {
  readonly draft: Draft;
  readonly page: PageState;
  readonly run: (command: Command) => void;
  readonly onAdd: (source: PickSource, inline: boolean) => void;
  readonly onCapture: Capture;
  readonly onLink: (link: Link, text: string, href?: string) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
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
      <LinkEditor
        disabled={false}
        link={editableLinkAt(draft.body, page.selection)}
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
      <WritingTools
        draft={draft}
        selection={page.selection}
        onCapture={onCapture}
      />
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
