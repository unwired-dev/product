import type { Translate } from '@private-email/localization';
import type {
  CapturedDraftText,
  DraftTextPurpose,
  NativeAssistance,
  TextTool,
} from '@private-email/mail-core/assistance';
import type {
  AssetPreview,
  BodyRecipientQuery,
  Draft,
  PickedFile,
  PickSource,
  Recipient,
  RecipientField,
  RecipientNotice,
  Recovery,
  SlashCommand,
} from '@private-email/mail-core/drafts';
import type {
  MailTemplate,
  StoredMailTemplate,
} from '@private-email/mail-core/mail-templates';
import type { SendCheck, SendRefusal } from '@private-email/mail-core/outbox';
import type {
  MailboxConnection,
  MailProvider,
} from '@private-email/mail-core/registration';
import type {
  Asset,
  BlockKind,
  ImageWidth,
  Link,
  Mark,
  Selection,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { SendReminder } from '@private-email/mail-core/send-reminders';
import type {
  NativeTranslation,
  TranslationLanguage,
} from '@private-email/mail-core/translation';
import type { ComponentProps, ReactNode } from 'react';
import type {
  KeyEvent,
  StyleProp,
  TextInputMacOSProps,
  TextStyle,
  ViewStyle,
} from 'react-native';

import {
  canGenerate,
  canRewrite,
  canSuggestReply,
  captureDraftText,
  capturePrompt,
  draftReplacement,
  isTextTool,
  sameDraftAssistanceSource,
} from '@private-email/mail-core/assistance';
import { draftCommands } from '@private-email/mail-core/commands';
import {
  acceptRecipient,
  addBodyRecipient,
  addingAsset,
  applySlashBlock,
  addRecipients,
  assetStates,
  bodyRecipientQuery,
  bodySuggestionSections,
  draftOf,
  entryOf,
  greetingName,
  isEmptyDraft,
  leftOutQuestion,
  onlyQueryIn,
  recipientLabel,
  recipientRole,
  draftSummary,
  profileOf,
  sendingMailboxes,
  pickLimit,
  recipientSuggestions,
  sameContent,
  sendingStateOf,
  slashCommands,
  slashQuery,
  unsendableAssets,
  prepareFiles,
  withAsset,
  withSender,
} from '@private-email/mail-core/drafts';
import { applyTemplate } from '@private-email/mail-core/mail-templates';
import { inboxMessages } from '@private-email/mail-core/mailboxes';
import { createRecoveryJournal } from '@private-email/mail-core/recovery-journal';
import {
  applyText,
  blockKindAt,
  displayOf,
  formatStyleOf,
  historyOf,
  imageCharacter,
  imagesOf,
  imageWidthOf,
  editableLinkAt,
  indentList,
  isListKind,
  listIndentAt,
  marksAt,
  clip,
  previewOf,
  record,
  redo,
  replaceSelection,
  selectedText,
  setBlockKind,
  setLink,
  textOf,
  toggled,
  toggleMark,
  undo,
  withImageWidth,
  withoutImage,
  withText,
} from '@private-email/mail-core/semantic-document';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import {
  Fragment,
  memo,
  use,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  AppState,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  NativeEventEmitter,
  processColor,
  useColorScheme,
} from 'react-native';

import type { IndentDirection, PopUpItem } from './composer-controls.tsx';

import { Action } from './action.tsx';
import { RegisterCommands, useCloseGuard } from './command-palette.tsx';
import {
  ComposerActions,
  FormatBar,
  kindStyles,
  LinkEditor,
  markStyle,
  PopUp,
  TemplatesMenu,
} from './composer-controls.tsx';
import { useContactAddresses } from './contacts.ts';
import {
  askForText,
  askInSheet,
  Notice as Banner,
  Button,
  ContextMenu,
  Glass,
  Popover,
  SFSymbol,
  ToolbarButton,
  useOutcomeAnnouncement,
} from './design.tsx';
import { DraftAssistance, DroppedAssistance } from './draft-assistance.tsx';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceProfileContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { MailboxesContext, useAllMailboxes } from './mailbox-list.ts';
import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useLeaveComposer,
  useMailTemplates,
  useOutbox,
  useProfile,
  useSendReminders,
} from './mailbox.tsx';
import { fileSize } from './message-body.tsx';
import { AssistanceContext } from './message-summary.tsx';
import { AccountContext } from './registration-gate.tsx';
import { ReminderBanner, SendMenu } from './send-reminder.tsx';
import { windowHost } from './settings-window-client.ts';
import { textStyles, usePalette } from './theme.ts';
import {
  DraftTranslation,
  TranslationContext,
  useTargetLanguages,
} from './translation.tsx';

// The body sits 32pt in; fields, chips and notices 24pt, with a 64pt right-aligned label column.
const bodyInset = 32;
const fieldInset = spacing.xxl;
const fieldLabelWidth = 64;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  grow: { flex: 1 },
  // Above the rows that follow it, so the Compose actions menu opens over them.
  header: {
    zIndex: 2,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: spacing.m,
    paddingBottom: spacing.xs,
    paddingHorizontal: spacing.l,
  },
  title: { ...textStyles.bodyEmphasized },
  // The Generate a Draft popover, per the Mac Compose Generate a Draft frames.
  // Its insets match the Link Editor popover's; the prompt is a control, so it uses Body.
  generate: {
    width: 360,
    gap: 10,
    paddingVertical: 14,
    paddingHorizontal: spacing.l,
  },
  generateTitle: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  generatePrompt: { ...textStyles.body, minHeight: 32 },
  generateActions: { flexDirection: 'row', justifyContent: 'flex-end' },
  alerts: {
    gap: spacing.s,
    paddingHorizontal: fieldInset,
    paddingBottom: spacing.s,
  },
  divider: { width: StyleSheet.hairlineWidth, height: 16, marginHorizontal: 2 },
  // The body takes the height the fields leave, so they sit directly above the action row.
  content: { flexGrow: 1, paddingBottom: spacing.s },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  notice: { ...textStyles.body },
  review: { paddingHorizontal: fieldInset, paddingTop: spacing.m },
  body: {
    ...textStyles.reading.body,
    flexGrow: 1,
    minHeight: 160,
    paddingHorizontal: bodyInset,
    paddingTop: spacing.m,
    paddingBottom: spacing.l,
  },
  quoted: {
    marginHorizontal: bodyInset,
    marginBottom: spacing.l,
    gap: spacing.xs,
  },
  quotedText: {
    ...textStyles.reading.body,
    paddingLeft: spacing.m,
    borderLeftWidth: 2,
  },
  assets: {
    paddingHorizontal: fieldInset,
    paddingBottom: spacing.m,
    gap: spacing.s,
  },
  assetChips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  assetChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    maxWidth: '100%',
    paddingLeft: 10,
    paddingRight: 6,
    paddingVertical: 6,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  assetMeta: { flexShrink: 1 },
  assetName: { ...textStyles.bodyEmphasized },
  assetStatusRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  assetStatus: { ...textStyles.subheadline, flexShrink: 1 },
  // The small indicator's 20 pt box fits the 14 pt status line, so a checking chip keeps its height.
  assetChecking: { marginVertical: -3 },
  thumbnail: { width: 28, height: 28, borderRadius: radius.control },
  fields: { paddingHorizontal: fieldInset, paddingBottom: 6 },
  field: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
    gap: spacing.s,
    minHeight: 36,
    paddingVertical: spacing.xs,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  // Recipients and the entry wrap within the value column, beside the label.
  entries: {
    flex: 1,
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  // Centred on the first 28pt line, so a wrapped recipient row keeps its label at the top.
  fieldLabel: {
    ...textStyles.body,
    width: fieldLabelWidth,
    paddingVertical: 6,
    textAlign: 'right',
  },
  fieldNotice: {
    paddingLeft: fieldLabelWidth + spacing.s,
    paddingBottom: spacing.xs,
  },
  // The frame starts the reason a field inset beyond the field's text.
  reason: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingLeft: fieldInset + fieldLabelWidth + spacing.s,
    paddingBottom: 6,
  },
  reasonText: { ...textStyles.subheadline, flexShrink: 1 },
  // Its text centred on the first 28pt line, level with the field's label.
  input: {
    ...textStyles.body,
    flex: 1,
    minWidth: 120,
    minHeight: 28,
    paddingVertical: 6,
  },
  // Recipient Suggestions open upward over the message, as the fields sit beneath it.
  suggestions: {
    position: 'absolute',
    bottom: '100%',
    left: fieldLabelWidth,
    right: 0,
    maxWidth: 340,
    padding: 6,
    borderRadius: radius.card + 2,
    borderCurve: 'continuous',
  },
  suggestionSection: {
    ...textStyles.subheadlineEmphasized,
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  suggestion: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 40,
    paddingHorizontal: spacing.s + 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  suggestionName: { ...textStyles.body },
  suggestionAddress: { ...textStyles.subheadline },
  suggestionEmpty: {
    ...textStyles.body,
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  suggestionNote: {
    ...textStyles.subheadline,
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  // A Slash Command Menu row, as a Mac menu item draws it.
  slashRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    height: 28,
    paddingHorizontal: spacing.s + 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  slashIcon: {
    width: 18,
    height: 16,
    alignItems: 'center',
    justifyContent: 'center',
  },
  slashGlyph: { fontSize: 10, lineHeight: 16, fontWeight: '600' },
  slashSection: { lineHeight: 16, paddingVertical: 3 },
  // The Body Recipient Shortcut's suggestions open under the query's @, over what follows.
  bodySuggestions: {
    position: 'absolute',
    zIndex: 1,
    width: 320,
    padding: 6,
    borderRadius: radius.card + 2,
    borderCurve: 'continuous',
  },
  // The whole 28pt row height removes the recipient; its chip stays compact.
  token: { minHeight: 28, justifyContent: 'center' },
  tokenFill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.s,
    paddingVertical: 2,
    outlineWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  tokenText: { ...textStyles.body },
  actions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: spacing.s,
    paddingBottom: spacing.m,
    paddingLeft: fieldInset,
    paddingRight: spacing.l,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  sender: { flexShrink: 1 },
  section: {
    ...textStyles.bodyEmphasized,
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.s,
  },
  row: {
    marginHorizontal: spacing.s,
    padding: 14,
    gap: 4,
    borderWidth: 2,
    borderRadius: radius.row,
    borderCurve: 'continuous',
  },
  rowTitle: { flexDirection: 'row', gap: spacing.s, alignItems: 'center' },
  badge: { ...textStyles.subheadline, fontWeight: '600' },
  rowSubject: { ...textStyles.body, flex: 1 },
  rowDetail: { ...textStyles.body },
  footer: { ...textStyles.body, paddingHorizontal: spacing.xl },
});

// What keeps the composer from closing, or asks before it does.
export type Closing =
  | 'saving'
  | 'blocked'
  | 'discard-blocked'
  | 'discard'
  | 'recipients';

// A quiet banner beside the content it explains, with its actions under the message. VoiceOver
// announces an action's outcome when it appears; macOS ignores live regions.
function Alert({
  message,
  outcome = false,
  children,
}: {
  readonly message: string;
  readonly outcome?: boolean;
  readonly children?: ReactNode;
}) {
  useEffect(() => {
    if (outcome) {
      AccessibilityInfo.announceForAccessibility(message);
    }
  }, [outcome, message]);
  return (
    <Banner
      icon="exclamationmark.triangle"
      message={message}
      messageRole="alert">
      {children}
    </Banner>
  );
}

// React Native macOS exposes plain Text to accessibility only through an accessible parent.
export function Notice({
  children,
  alert = false,
  style,
}: {
  readonly children: string;
  readonly alert?: boolean;
  readonly style: StyleProp<TextStyle>;
}) {
  return (
    <View
      accessible
      accessibilityLabel={children}
      accessibilityLiveRegion="polite"
      accessibilityRole={alert ? 'alert' : 'text'}
      style={styles.grow}>
      <Text style={style}>{children}</Text>
    </View>
  );
}

// Matching keys consume native input. Keep Delete/Backspace native; onKeyDown still reports them.
const shortcuts = [
  { key: 'b', metaKey: true },
  { key: 'i', metaKey: true },
  { key: 'u', metaKey: true },
  { key: 'z', metaKey: true },
  { key: 'z', metaKey: true, shiftKey: true },
  // AppKit keeps Shift in the reported key, so Shift-Command-Z arrives as an uppercase Z.
  { key: 'Z', metaKey: true, shiftKey: true },
];

const rowLabel = (conflict: boolean, shortened: boolean) => {
  if (conflict) {
    return shortened
      ? 'drafts.conflictRowLabelShortened'
      : 'drafts.conflictRowLabel';
  }
  return shortened ? 'drafts.rowLabelShortened' : 'drafts.rowLabel';
};

// One Draft in the Inbox list, labelled apart from received mail.
function DraftRowView({
  draft,
  selected,
  onOpen,
}: {
  readonly draft: Draft;
  readonly selected: boolean;
  readonly onOpen: (id: string) => Promise<void>;
}) {
  const colors = usePalette();
  const primaryColor = selected ? colors.accentOnFill : colors.textPrimary;
  const secondaryColor = selected ? colors.accentOnFill : colors.textSecondary;
  const focusColor = selected ? colors.accentOnFill : colors.accentInk;
  const { t } = useLocalization();
  const [focused, setFocused] = useState(false);
  // The sending mailbox stays visible whatever the body holds.
  const preview = previewOf(textOf(draft.body));
  // One line each: long metadata is cut before it is rendered or announced.
  const { subject, recipients, from, shortened } = draftSummary(t, draft);
  return (
    <Pressable
      accessibilityLabel={t(rowLabel(draft.conflict === true, shortened), {
        subject,
        recipients,
        from,
      })}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      // The row's accent/ink ring replaces the system focus ring.
      enableFocusRing={false}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={() => {
        void onOpen(draft.id);
      }}
      style={({ pressed }) => [
        styles.row,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.surfaceContent,
          borderColor: focused ? focusColor : 'transparent',
        },
        selected && { backgroundColor: colors.accentFill },
      ]}>
      <View style={styles.rowTitle}>
        <Text
          style={[
            styles.badge,
            { color: selected ? colors.accentOnFill : colors.accentInk },
          ]}>
          {draft.conflict === true
            ? t('drafts.conflictBadge')
            : t('drafts.badge')}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.rowSubject, { color: primaryColor }]}>
          {subject}
        </Text>
      </View>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: secondaryColor }]}>
        {recipients}
      </Text>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: secondaryColor }]}>
        {t('drafts.from', { from })}
      </Text>
      {preview === '' ? null : (
        <Text
          numberOfLines={1}
          style={[styles.rowDetail, { color: secondaryColor }]}>
          {preview}
        </Text>
      )}
    </Pressable>
  );
}

export const DraftRow = memo(DraftRowView);

// Opens a Draft in the composer once the open one, if another, can be left.
export function useOpenDraft(
  composing: string | undefined,
  onCompose: (id: string) => void,
) {
  const leave = useLeaveComposer();
  return useCallback(
    async (id: string) => {
      if (id !== composing && (await leave(id))) {
        onCompose(id);
      }
    },
    [composing, leave, onCompose],
  );
}

// The Inbox list's Drafts storage status. The Draft rows themselves are list items, so a long
// list stays virtualized.
export function DraftList() {
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  if (state.kind === 'closed') {
    return null;
  }
  return (
    <View>
      {state.kind === 'locked' || state.kind === 'failed' ? (
        <View style={[styles.bar, { paddingHorizontal: spacing.xl }]}>
          <Notice
            alert
            style={[styles.notice, { color: colors.textPrimary }]}>
            {state.kind === 'locked'
              ? t('drafts.listLocked')
              : t('drafts.listFailed')}
          </Notice>
          <Action
            variant="composer"
            label={t('common.retry')}
            onPress={() => {
              void store.load();
            }}
          />
        </View>
      ) : null}
      {state.kind === 'ready' &&
      (state.save === 'failed' || state.save === 'locked') ? (
        <View style={[styles.bar, { paddingHorizontal: spacing.xl }]}>
          <Notice
            alert
            style={[styles.notice, { color: colors.textPrimary }]}>
            {t(`drafts.unsaved.${state.save}`)}
          </Notice>
          <Action
            variant="composer"
            label={t('drafts.saveDrafts')}
            onPress={() => {
              void store.save();
            }}
          />
        </View>
      ) : null}
    </View>
  );
}

export function DraftHeading() {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View
      accessible
      accessibilityLabel={t('drafts.heading')}
      accessibilityRole="header">
      <Text style={[styles.section, { color: colors.textSecondary }]}>
        {t('drafts.heading')}
      </Text>
    </View>
  );
}

// The From pop-up: the retained sending mailbox, with the Draft's Profile's other senders in
// its menu. Why it cannot send, if it cannot, is explained by SendingNotice.
export function SendingMailbox({
  draft,
  onChange,
  editable,
}: {
  readonly draft: Draft;
  readonly editable: boolean;
  readonly onChange: (mailbox: MailboxConnection) => void;
}) {
  const account = use(AccountContext);
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const state = sendingStateOf(draft, mailboxes);
  // Only the Draft's own Mail Profile can send it.
  const senders = sendingMailboxes(
    mailboxes,
    profileOf(draft.connection, mailboxes),
  );
  const from = clip(draft.from);
  const shortened = from.length < draft.from.length;
  let label = t(shortened ? 'drafts.sendFromShortened' : 'drafts.sendFrom', {
    address: from,
  });
  if (state !== 'available') {
    label = t(shortened ? 'drafts.cannotSendShortened' : 'drafts.cannotSend', {
      from,
    });
  }
  return (
    <View style={styles.sender}>
      <PopUp
        accessibilityLabel={label}
        disabled={!editable}
        label={t('drafts.fromAddress', { address: from })}
        items={senders.map((mailbox) => ({
          key: mailbox.id,
          title: mailbox.address,
          checked: state === 'available' && mailbox.id === draft.connection,
          disabled: !editable,
          run: () => {
            onChange(mailbox);
          },
        }))}
      />
    </View>
  );
}

function SendingNotice({ draft }: { readonly draft: Draft }) {
  const account = use(AccountContext);
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const state = sendingStateOf(draft, mailboxes);
  const microsoft =
    mailboxes.find(({ id }) => id === draft.connection)?.provider ===
    'microsoft-graph';
  return state === 'available' ? null : (
    <Alert
      message={t(
        state === 'authorization' && microsoft
          ? 'drafts.sending.authorization_microsoft'
          : `drafts.sending.${state}`,
      )}
    />
  );
}

// The keys a recipient field handles while it shows Recipient Suggestions, without modifiers, so
// Shift-Tab still moves back and modified arrows still move the caret. Escape is listed so it
// dismisses the suggestions without ending editing.
const plainKey = {
  shiftKey: false,
  altKey: false,
  ctrlKey: false,
  metaKey: false,
};
const suggestionKeys = ['ArrowUp', 'ArrowDown', 'Tab', 'Escape'].map((key) => ({
  key,
  ...plainKey,
}));
// The body takes these while it shows Recipient Suggestions: Up and Down move, Return and Tab
// choose, Escape closes. With no match it takes only Escape.
const choosingKeys = ['ArrowUp', 'ArrowDown', 'Enter', 'Tab', 'Escape'].map(
  (key) => ({ key, ...plainKey }),
);
const closingKeys = [{ key: 'Escape', ...plainKey }];
const noIndents = { outdent: false, indent: false };
// In a list, Tab and Shift-Tab indent and outdent its items.
const listTabs = [
  { key: 'Tab', ...plainKey },
  { key: 'Tab', ...plainKey, shiftKey: true },
];
// In a list, Tab and Shift-Tab indent and outdent its items, unless Tab chooses a Recipient
// Suggestion or a Slash Command Menu block.
const listTabsOn = (recipients: boolean, slash: boolean, kind: BlockKind) =>
  !recipients && !slash && isListKind(kind);
// The keys the body takes from the text view: formatting shortcuts, Recipient Suggestions' keys
// and, in a list, Tab and Shift-Tab.
const bodyKeys = (recipientKeys: typeof choosingKeys, tabs: boolean) => [
  ...shortcuts,
  ...recipientKeys,
  ...(tabs ? listTabs : []),
];

// Where the text view leaves the selection, without reporting it, when JavaScript replaces its
// text (RCTTextInputComponentView's _setAttributedString on macOS): a caret stays as far from the
// end, or goes to the end; a selection stays while it fits, else collapses to the end.
const keptByTextView = (
  at: Selection,
  before: number,
  after: number,
): Selection => {
  if (at.start !== at.end) {
    return at.end <= after ? at : { start: after, end: after };
  }
  const caret = after - before + at.start;
  return caret < 0
    ? { start: after, end: after }
    : { start: caret, end: caret };
};

// Recipient Suggestions in a glass menu, Recent then Contacts, with the active one highlighted;
// `empty` shows when none matches, and `note` beneath them.
function SuggestionMenu({
  sections,
  active,
  onAccept,
  style,
  empty,
  note,
  roleOf,
}: {
  readonly sections: Readonly<{
    recent: readonly Recipient[];
    contacts: readonly Recipient[];
  }>;
  readonly active: Recipient | undefined;
  readonly onAccept: (recipient: Recipient) => void;
  readonly style: StyleProp<ViewStyle>;
  readonly empty?: string | undefined;
  readonly note?: string | undefined;
  // The field a person already on the Draft is in, shown at the row's trailing edge.
  readonly roleOf?: ((recipient: Recipient) => string | undefined) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const none = sections.recent.length + sections.contacts.length === 0;
  return (
    <MenuPanel
      label={t('drafts.suggestions.title')}
      style={style}>
      {none && empty !== undefined ? (
        <Text style={[styles.suggestionEmpty, { color: colors.textSecondary }]}>
          {empty}
        </Text>
      ) : null}
      {(['recent', 'contacts'] as const).map((section) =>
        sections[section].length === 0 ? null : (
          <Fragment key={section}>
            <Text
              style={[
                styles.suggestionSection,
                { color: colors.textSecondary },
              ]}>
              {t(`drafts.suggestions.${section}`)}
            </Text>
            {sections[section].map((recipient) => {
              const chosen = recipient === active;
              const primary = chosen ? colors.accentOnFill : colors.textPrimary;
              const secondary = chosen
                ? colors.accentOnFill
                : colors.textSecondary;
              const role = roleOf?.(recipient);
              const label =
                recipient.name === undefined
                  ? recipient.address
                  : t('drafts.suggestions.named', {
                      name: recipient.name,
                      address: recipient.address,
                    });
              return (
                <Pressable
                  key={recipient.address}
                  accessibilityLabel={
                    role === undefined
                      ? label
                      : t('drafts.suggestions.inRole', { label, role })
                  }
                  accessibilityRole="button"
                  accessibilityState={{ selected: chosen }}
                  // The field keeps focus, so typing continues after a click.
                  focusable={false}
                  onPress={() => {
                    onAccept(recipient);
                  }}
                  style={({ pressed }) => [
                    styles.suggestion,
                    pressed
                      ? { backgroundColor: colors.accentSelectionSubtle }
                      : null,
                    chosen ? { backgroundColor: colors.accentFill } : null,
                  ]}>
                  <SFSymbol
                    name="person.fill"
                    color={secondary}
                    size={11}
                  />
                  <View style={styles.grow}>
                    <Text
                      numberOfLines={1}
                      style={[styles.suggestionName, { color: primary }]}>
                      {recipient.name ?? recipient.address}
                    </Text>
                    {recipient.name === undefined ? null : (
                      <Text
                        numberOfLines={1}
                        style={[
                          styles.suggestionAddress,
                          { color: secondary },
                        ]}>
                        {recipient.address}
                      </Text>
                    )}
                  </View>
                  {role === undefined ? null : (
                    <Text style={[styles.suggestionName, { color: secondary }]}>
                      {role}
                    </Text>
                  )}
                </Pressable>
              );
            })}
          </Fragment>
        ),
      )}
      {note === undefined ? null : (
        <Text style={[styles.suggestionNote, { color: colors.textSecondary }]}>
          {note}
        </Text>
      )}
    </MenuPanel>
  );
}

// A glass menu over the composer, `style` placing it.
function MenuPanel({
  label,
  style,
  children,
}: {
  readonly label: string;
  readonly style: StyleProp<ViewStyle>;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View
      accessibilityLabel={label}
      style={[style, { boxShadow: colors.macMenuGlassShadow }]}>
      {/* React Native's legacy view interop mounts a nested native view without its offset,
          so the glass sits in a plain view. */}
      <View
        collapsable={false}
        style={StyleSheet.absoluteFill}>
        <Glass
          cornerRadius={radius.card + 2}
          panel
        />
      </View>
      {children}
    </View>
  );
}

// Senders of the mail held on this device for the Draft's Mail Profile, never another Profile's,
// newest first, and the Profile's own addresses, which are never suggested.
function correspondentsFor(
  draft: Draft,
  connections: readonly MailboxConnection[],
  held: ReturnType<typeof useAllMailboxes>,
) {
  const profile = profileOf(draft.connection, connections);
  return {
    correspondents: inboxMessages(
      held.filter((mailbox) => mailbox.profile === profile),
      { profile },
    ).map(({ message }) => message),
    // Including connections awaiting authorization, which hold no mail here.
    excluded: connections.flatMap((mailbox) =>
      mailbox.profile === profile ? [mailbox.address] : [],
    ),
  };
}

// Whether Cc and Bcc show: also for text saved in them, which would otherwise hide why Send waits.
const showsCopies = (draft: Draft) =>
  draft.copies === true ||
  draft.cc.length + draft.bcc.length > 0 ||
  entryOf(draft, 'cc') !== '' ||
  entryOf(draft, 'bcc') !== '';

// Why Send is unavailable, under the field that causes it; announced once when it follows an
// action, as macOS ignores live regions.
function SendBlockedReason({
  message,
  announce = false,
}: {
  readonly message: string;
  readonly announce?: boolean;
}) {
  const colors = usePalette();
  useEffect(() => {
    if (announce) {
      AccessibilityInfo.announceForAccessibility(message);
    }
  }, [announce, message]);
  return (
    <View
      accessible
      accessibilityLabel={message}
      accessibilityRole="text"
      style={styles.reason}>
      <View collapsable={false}>
        <SFSymbol
          name="exclamationmark.triangle.fill"
          size={11}
          color={colors.statusWarning}
        />
      </View>
      <Text style={[styles.reasonText, { color: colors.textSecondary }]}>
        {message}
      </Text>
    </View>
  );
}

export function Recipients({
  draft,
  getDraft,
  field,
  onChange,
  onCaretMove,
  editable,
  required = false,
  trailing,
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly field: RecipientField;
  readonly editable: boolean;
  // Whether Send waits for a recipient, which this field then asks for.
  readonly required?: boolean;
  // A typing step when only the unfinished entry changed.
  readonly onChange: (draft: Draft, typing: boolean, field: string) => void;
  readonly onCaretMove: () => void;
  // A control at the row's trailing edge, such as the one revealing Cc and Bcc.
  readonly trailing?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [notice, setNotice] = useState<RecipientNotice>();
  const selection = useRef<Selection>({ start: 0, end: 0 });
  const caret = useRef<number | undefined>(undefined);
  const [focused, setFocused] = useState<string>();
  // Recipient Suggestions show while the field is being typed in, until Escape dismisses them;
  // typing again shows them again.
  const [entering, setEntering] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  // Escape ends editing in AppKit too; that end keeps the unfinished entry as typed.
  const escaped = useRef(false);
  const [highlighted, setHighlighted] = useState(0);
  const account = use(AccountContext);
  const held = useAllMailboxes();
  const contacts = useContactAddresses(entering && editable).addresses;
  const name = t(`drafts.fields.${field}`);
  // Recent correspondents of the Draft's Mail Profile, then Apple Contacts not already suggested.
  const sections = useMemo(() => {
    if (!entering || !editable || dismissed) {
      return { recent: [], contacts: [] };
    }
    const { correspondents, excluded } = correspondentsFor(
      draft,
      account?.mailboxes ?? [],
      held,
    );
    const recent = recipientSuggestions(draft, field, {
      correspondents,
      excluded,
    });
    const matched = recipientSuggestions(draft, field, {
      correspondents: contacts,
      excluded: [...excluded, ...recent.map(({ address }) => address)],
    });
    // Three rows fit above To over Subject and the minimum body; a matching contact keeps one.
    const shown = recent.slice(0, matched.length === 0 ? 3 : 2);
    return { recent: shown, contacts: matched.slice(0, 3 - shown.length) };
  }, [entering, editable, dismissed, draft, field, account, held, contacts]);
  // Up and Down move through both sections as one list.
  const suggestions = [...sections.recent, ...sections.contacts];
  const active = Math.min(highlighted, suggestions.length - 1);
  const accept = (recipient: Recipient) => {
    onChange(acceptRecipient(getDraft(), field, recipient), false, field);
    setNotice(undefined);
    setHighlighted(0);
  };
  const add = (value: string, all: boolean, typing = false) => {
    if (!editable) {
      return;
    }
    const current = getDraft();
    const result = addRecipients(current, { field, text: value, all });
    if (result.draft !== current) {
      onChange(
        result.draft,
        typing && result.draft[field] === current[field],
        field,
      );
    }
    setNotice(result.notice);
  };
  // Text Send would leave in the field, once it is no longer typed in, is not an address it can use.
  const entry = addRecipients(draft, {
    field,
    text: entryOf(draft, field),
    all: true,
  }).text;
  const incomplete = !entering && entry !== '';
  const requiredReason = required ? t('drafts.recipient.required') : undefined;
  const reason = incomplete
    ? t('drafts.recipient.incomplete', { address: entry })
    : requiredReason;
  return (
    <View>
      {suggestions.length === 0 ? null : (
        <SuggestionMenu
          sections={sections}
          active={suggestions[active]}
          onAccept={accept}
          style={styles.suggestions}
        />
      )}
      <View style={[styles.field, { borderTopColor: colors.separator }]}>
        <Text style={[styles.fieldLabel, { color: colors.textSecondary }]}>
          {`${name}:`}
        </Text>
        <View style={styles.entries}>
          {draft[field].map((recipient) => (
            <Pressable
              key={recipient.address}
              accessibilityHint={t('drafts.removeRecipient')}
              accessibilityLabel={t('drafts.recipientLabel', {
                field: name,
                recipient: recipientLabel(recipient),
              })}
              accessibilityRole="button"
              accessibilityState={{ disabled: !editable }}
              disabled={!editable}
              // The token's accent/ink ring replaces the system focus ring.
              enableFocusRing={false}
              focusable
              onBlur={() => {
                setFocused(undefined);
              }}
              onFocus={() => {
                setFocused(recipient.address);
              }}
              onPress={() => {
                const current = getDraft();
                onChange(
                  {
                    ...current,
                    [field]: current[field].filter(
                      (each) => each.address !== recipient.address,
                    ),
                  },
                  false,
                  field,
                );
              }}
              style={styles.token}>
              {({ pressed }) => (
                <View
                  style={[
                    styles.tokenFill,
                    {
                      backgroundColor: pressed
                        ? colors.accentSelectionSubtle
                        : colors.fillQuiet,
                      opacity: editable ? 1 : 0.4,
                      outlineColor:
                        focused === recipient.address && editable
                          ? colors.accentInk
                          : 'transparent',
                    },
                  ]}>
                  <Text
                    style={[styles.tokenText, { color: colors.textPrimary }]}>
                    {recipient.name ?? recipient.address}
                  </Text>
                  <SFSymbol
                    name="xmark"
                    size={10}
                    color={colors.textSecondary}
                  />
                </View>
              )}
            </Pressable>
          ))}
          <TextInput
            accessibilityLabel={name}
            accessibilityHint={incomplete ? reason : undefined}
            editable={editable}
            accessibilityState={{ disabled: !editable }}
            autoCapitalize="none"
            autoComplete="email"
            autoCorrect={false}
            submitBehavior="submit"
            inputMode="email"
            // Up and Down move through Recipient Suggestions and Tab accepts one; otherwise they
            // move as usual.
            keyDownEvents={
              suggestions.length === 0 ? undefined : suggestionKeys
            }
            onBlur={() => {
              setEntering(false);
              if (escaped.current) {
                escaped.current = false;
                return;
              }
              add(entryOf(getDraft(), field), true);
            }}
            onChangeText={(value) => {
              setEntering(true);
              setDismissed(false);
              setHighlighted(0);
              const text = entryOf(getDraft(), field);
              caret.current =
                selection.current.end + value.length - text.length;
              const word =
                value.length === text.length + 1 &&
                !/\s/u.test(value[selection.current.start] ?? ' ');
              add(value, false, word);
            }}
            onSelectionChange={({ nativeEvent }) => {
              const next = nativeEvent.selection;
              if (next.start !== next.end || next.start !== caret.current) {
                onCaretMove();
              }
              caret.current = undefined;
              selection.current = next;
            }}
            onKeyDown={({ nativeEvent }) => {
              const last = suggestions.length - 1;
              if (
                nativeEvent.shiftKey ||
                nativeEvent.altKey ||
                nativeEvent.ctrlKey ||
                nativeEvent.metaKey
              ) {
                return;
              }
              if (nativeEvent.key === 'ArrowDown') {
                setHighlighted((index) => Math.min(index + 1, last));
              } else if (nativeEvent.key === 'ArrowUp') {
                setHighlighted((index) =>
                  Math.max(Math.min(index, last) - 1, 0),
                );
              } else if (nativeEvent.key === 'Tab') {
                const suggestion = suggestions[active];
                if (suggestion !== undefined) {
                  accept(suggestion);
                }
              }
            }}
            // AppKit reports Escape in a text input as a key press.
            onKeyPress={({ nativeEvent }) => {
              if (nativeEvent.key === 'Escape' && suggestions.length > 0) {
                escaped.current = true;
                setDismissed(true);
              }
            }}
            onSubmitEditing={() => {
              const suggestion = suggestions[active];
              if (suggestion === undefined) {
                add(entryOf(getDraft(), field), true);
              } else {
                accept(suggestion);
              }
            }}
            placeholder={t('drafts.recipientPlaceholder')}
            placeholderTextColor={colors.textSecondary}
            returnKeyType="next"
            style={[styles.input, { color: colors.textPrimary }]}
            textContentType="emailAddress"
            value={entryOf(draft, field)}
          />
        </View>
        {trailing}
      </View>
      {reason === undefined ? null : (
        <SendBlockedReason
          announce={incomplete}
          message={reason}
        />
      )}
      {reason !== undefined || notice === undefined ? null : (
        <View style={styles.fieldNotice}>
          <Notice style={[styles.notice, { color: colors.textSecondary }]}>
            {t(`drafts.recipient.${notice}`)}
          </Notice>
        </View>
      )}
    </View>
  );
}

// What a Draft's file or image is on this device now.
const assetStatus = (
  t: Translate,
  size: (bytes: number) => string,
  {
    asset,
    running,
    checking,
    preview,
  }: Readonly<{
    asset: Asset;
    running: boolean;
    checking: boolean;
    preview: AssetPreview | undefined;
  }>,
) => {
  if (checking) {
    return t('drafts.assets.status.checking');
  }
  if (asset.state === 'complete') {
    if (
      preview?.kind === 'damaged' ||
      preview?.kind === 'missing' ||
      preview?.kind === 'incomplete' ||
      preview?.kind === 'locked'
    ) {
      return t(`drafts.assets.status.${preview.kind}`, {
        size: size(asset.size),
      });
    }
    return size(asset.size);
  }
  if (asset.state === 'importing') {
    return t(
      running
        ? 'drafts.assets.status.adding'
        : 'drafts.assets.status.interrupted',
    );
  }
  if (asset.state === 'cancelled') {
    return t('drafts.assets.status.cancelled');
  }
  return t(
    'reason' in asset
      ? 'drafts.assets.status.tooLarge'
      : 'drafts.assets.status.failed',
  );
};

// A `data:` URL's media type, which a pasteboard item without its own type still carries.
const typeOf = (uri: string) => {
  const [, type = ''] =
    /^data:(?<type>[\w.+-]+\/[\w.+-]+)[;,]/u.exec(uri) ?? [];
  const lower = type.toLowerCase();
  return lower === 'image/jpg' ? 'image/jpeg' : lower;
};

// Files and images that the pasteboard or a drag carries: a dropped or pasted file arrives as a
// path, a pasted image as `data:` bytes.
const transferred = (
  pasted: string,
  transfer:
    | Readonly<{
        files: ReadonlyArray<
          Readonly<{
            name?: string | undefined;
            type?: string | null | undefined;
            uri: string;
          }>
        >;
      }>
    | undefined,
): readonly PickedFile[] =>
  (transfer?.files ?? []).slice(0, pickLimit).map(({ name, type, uri }) => ({
    name: name ?? pasted,
    type:
      type === undefined || type === null || type === '' ? typeOf(uri) : type,
    source: { kind: uri.startsWith('data:') ? 'data' : 'file', uri },
  }));

// A verify-only Send check updates availability without replacing an inline thumbnail.
const sendPreview = (
  kind: AssetPreview['kind'] | undefined,
  preview: AssetPreview | undefined,
): AssetPreview | undefined => {
  if (kind === undefined || kind === 'ready') {
    return undefined;
  }
  return kind === 'verified' && preview?.kind === 'ready' ? preview : { kind };
};

// A Send result replaces the row's previous availability for this asset revision.
const afterSend = (
  asset: Asset,
  {
    kind,
    shown,
    attempt,
  }: Readonly<{
    kind: AssetPreview['kind'] | undefined;
    shown: AssetPreview | undefined;
    attempt: number;
  }>,
) => {
  const preview = sendPreview(kind, shown);
  return asset.state !== 'complete' || preview === undefined
    ? undefined
    : { id: asset.id, digest: asset.digest, attempt, preview };
};

// A complete asset's bytes checked against its digest, read again when it completes or changes;
// an inline image's are also returned to show. A check refused while storage was locked runs
// again when the app becomes active, or when asked. A Send check updates the same status.
function usePreview(
  asset: Asset,
  inline: boolean,
  check: SendCheck | undefined,
) {
  const store = useDraftStore();
  const complete = asset.state === 'complete' ? asset : undefined;
  const id = complete?.id;
  const digest = complete?.digest;
  const type = complete?.type;
  const [preview, setPreview] = useState<
    Readonly<{
      id: string;
      digest: string;
      attempt: number;
      preview: AssetPreview;
    }>
  >();
  // Each retry reads again; the last finished read stays shown meanwhile.
  const [attempt, setAttempt] = useState(0);
  const retry = useCallback(() => {
    setAttempt((current) => current + 1);
  }, []);
  const checked = check?.get(asset.id);
  const sendResult = useRef<AssetPreview['kind']>(undefined);
  useLayoutEffect(() => {
    if (checked !== undefined) {
      sendResult.current = checked;
    }
  }, [checked]);
  const shown =
    preview?.id === id && preview?.digest === digest
      ? preview?.preview
      : undefined;
  // A locked check, or bytes another device has not uploaded yet, may succeed later.
  const waiting = shown?.kind === 'locked' || shown?.kind === 'incomplete';
  useEffect(() => {
    if (!waiting) {
      return undefined;
    }
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active') {
        retry();
      }
    });
    return () => {
      subscription.remove();
    };
  }, [waiting, retry]);
  useEffect(() => {
    if (id === undefined || digest === undefined || type === undefined) {
      return undefined;
    }
    let showing = true;
    // New reads can recover; an older read must preserve the newer Send result and any thumbnail.
    sendResult.current = undefined;
    const read = async () => {
      const next = await store.readAsset(
        { id, digest, type },
        { preview: inline },
      );
      if (showing) {
        setPreview({
          id,
          digest,
          attempt,
          preview: sendPreview(sendResult.current, next) ?? next,
        });
      }
    };
    void read();
    return () => {
      showing = false;
    };
  }, [store, id, digest, type, inline, attempt]);
  const [found, setFound] = useState(checked);
  if (found !== checked) {
    setFound(checked);
    const next = afterSend(asset, { kind: checked, shown, attempt });
    if (next !== undefined) {
      setPreview(next);
      // Send verified the bytes; a missing inline thumbnail can load separately.
      if (inline && next.preview.kind === 'verified') {
        retry();
      }
    }
  }
  return {
    preview: shown,
    retry,
    checking: check?.has(asset.id) === true && checked === undefined,
  };
}

// A file's status; while Send reads it, Checking… beside an indeterminate spinner.
function AssetStatus({
  checking,
  preview,
  status,
}: Readonly<{
  checking: boolean;
  preview: AssetPreview | undefined;
  status: string;
}>) {
  const colors = usePalette();
  return (
    <View style={styles.assetStatusRow}>
      {checking ? (
        <ActivityIndicator
          size="small"
          color={colors.textSecondary}
          style={styles.assetChecking}
        />
      ) : null}
      <Text
        numberOfLines={1}
        style={[
          styles.assetStatus,
          {
            color:
              preview?.kind === 'damaged' && !checking
                ? colors.statusDestructive
                : colors.textSecondary,
          },
        ]}>
        {status}
      </Text>
    </View>
  );
}

// The display sizes an inline image offers, as in the approved #1735 frames; Original names the
// image's own size.
const imageSizes = [
  ['small', 320],
  ['medium', 640],
  ['large', 1024],
  ['original', undefined],
] as const;

const sizeTitle = (
  t: Translate,
  size: (typeof imageSizes)[number][0],
  width: number | undefined,
) =>
  width === undefined
    ? t(`drafts.assets.size.${size}`)
    : t('drafts.assets.size.withWidth', {
        size: t(`drafts.assets.size.${size}`),
        width,
      });

// An asset row's context menu and VoiceOver actions: an image in the body offers its display
// sizes in an Image Size submenu, and Remove Image; an editor that converts offers that, with
// Remove.
const assetMenu = (
  t: Translate,
  {
    asset,
    inline,
    width,
    dimensions,
    onConvert,
    onRemove,
    onResize,
  }: Readonly<{
    asset: Asset;
    inline: boolean;
    width: ImageWidth | null | undefined;
    // The image's own pixel size, once its preview names one.
    dimensions: Readonly<{ width: number; height: number }> | undefined;
    onConvert: ((id: string) => void) | undefined;
    onRemove: (id: string) => void;
    onResize: ((width: ImageWidth | undefined) => void) | undefined;
  }>,
) => {
  const toAttachment = inline ? 'toAttachment' : 'toInline';
  const sizes =
    onResize === undefined
      ? []
      : imageSizes.map(([size, sizeWidth]) => ({
          key: `size:${size}:${asset.id}`,
          title: sizeTitle(t, size, sizeWidth ?? dimensions?.width),
          symbol: '',
          checked: width === sizeWidth,
          accessibilityLabel:
            sizeWidth === undefined && dimensions !== undefined
              ? t('drafts.assets.size.originalLabel', {
                  name: asset.name,
                  ...dimensions,
                })
              : t('drafts.assets.size.label', {
                  name: asset.name,
                  size: t(`drafts.assets.size.${size}`),
                }),
          run: () => {
            onResize(sizeWidth);
          },
        }));
  const convert =
    onConvert !== undefined && (inline || asset.type.startsWith('image/'))
      ? [
          {
            key: `convert:${asset.id}`,
            title: t(`drafts.assets.${toAttachment}`),
            symbol: inline ? 'paperclip' : 'photo',
            run: () => {
              onConvert(asset.id);
            },
          },
        ]
      : [];
  if (sizes.length + convert.length === 0) {
    return { sections: [], actions: [] };
  }
  // The size menu's Remove Image, as the frames show it, has no symbol.
  const remove = {
    key: `remove:${asset.id}`,
    title: t(
      sizes.length > 0 ? 'drafts.assets.removeImage' : 'drafts.assets.remove',
    ),
    symbol: sizes.length > 0 ? '' : 'trash',
    destructive: true,
    run: () => {
      onRemove(asset.id);
    },
  };
  return {
    sections: [
      {
        items:
          sizes.length > 0
            ? [
                {
                  title: t('drafts.assets.size.menu'),
                  symbol: '',
                  items: sizes,
                },
              ]
            : [],
      },
      { items: [...convert, remove] },
    ],
    // VoiceOver on the Mac speaks an action's name, so each name is its spoken label.
    actions: [
      ...convert.map(({ run }) => ({
        name: t(`drafts.assets.${toAttachment}Label`, { name: asset.name }),
        run,
      })),
      ...sizes.map(({ accessibilityLabel, run }) => ({
        name: accessibilityLabel,
        run,
      })),
    ],
  };
};

function AssetRow({
  asset,
  editable,
  inline,
  running,
  check,
  width,
  onRemove,
  onCancel,
  onConvert,
  onPreview,
  onResize,
}: {
  readonly asset: Asset;
  readonly inline: boolean;
  readonly running: boolean;
  readonly editable: boolean;
  readonly check: SendCheck | undefined;
  // The display width every use of an inline image in the body shares: undefined at its original
  // size, null when they differ.
  readonly width?: ImageWidth | null | undefined;
  readonly onRemove: (id: string) => void;
  readonly onCancel: (id: string) => void;
  readonly onConvert?: ((id: string) => void) | undefined;
  // An editor that shows Inline Images itself receives each verified thumbnail.
  readonly onPreview?: ((id: string, uri: string | null) => void) | undefined;
  // Given only for an image in the body, which offers its display sizes.
  readonly onResize?: ((width: ImageWidth | undefined) => void) | undefined;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const sizeFormat = useMemo(
    () => new Intl.NumberFormat(settings.locale, { maximumFractionDigits: 1 }),
    [settings.locale],
  );
  const { preview, retry, checking } = usePreview(asset, inline, check);
  const uri = inline && preview?.kind === 'ready' ? preview.uri : undefined;
  useEffect(() => {
    if (inline) {
      onPreview?.(asset.id, uri ?? null);
    }
  }, [asset.id, inline, onPreview, uri]);
  const status = assetStatus(t, (bytes) => fileSize(t, sizeFormat, bytes), {
    asset,
    running,
    checking,
    preview,
  });
  const menu = assetMenu(t, {
    asset,
    inline,
    width,
    dimensions: preview?.kind === 'ready' ? preview.dimensions : undefined,
    onConvert,
    onRemove,
    onResize,
  });
  const chip = (
    <View style={[styles.assetChip, { backgroundColor: colors.fillQuiet }]}>
      {preview?.kind === 'ready' ? (
        <Image
          accessibilityIgnoresInvertColors
          accessibilityLabel={t('drafts.assets.inlineImage', {
            name: asset.name,
          })}
          source={{ uri: preview.uri }}
          style={styles.thumbnail}
        />
      ) : (
        <SFSymbol
          name={inline ? 'photo' : 'doc'}
          color={colors.textSecondary}
        />
      )}
      <View
        accessible
        accessibilityLabel={t('drafts.assets.row', {
          name: asset.name,
          status,
        })}
        {...(menu.actions.length > 0 && editable
          ? {
              accessibilityActions: menu.actions.map(({ name }) => ({
                name,
                label: name,
              })),
              onAccessibilityAction: ({ nativeEvent }) => {
                menu.actions
                  .find(({ name }) => name === nativeEvent.actionName)
                  ?.run();
              },
            }
          : {})}
        style={styles.assetMeta}>
        <Text
          numberOfLines={1}
          style={[styles.assetName, { color: colors.textPrimary }]}>
          {asset.name}
        </Text>
        <AssetStatus
          checking={checking}
          preview={preview}
          status={status}
        />
      </View>
      {preview?.kind === 'locked' || preview?.kind === 'incomplete' ? (
        <Action
          variant="composer"
          disabled={!editable}
          accessibilityLabel={t('drafts.assets.retryLabel', {
            name: asset.name,
          })}
          label={t('common.retry')}
          onPress={retry}
        />
      ) : null}
      {running ? (
        <Action
          variant="composer"
          disabled={!editable}
          accessibilityLabel={t('drafts.assets.cancelLabel', {
            name: asset.name,
          })}
          label={t('common.cancel')}
          onPress={() => {
            onCancel(asset.id);
          }}
        />
      ) : null}
      <ToolbarButton
        disabled={!editable}
        icon="xmark"
        label={t('drafts.assets.removeLabel', { name: asset.name })}
        onPress={() => {
          onRemove(asset.id);
        }}
      />
    </View>
  );
  return menu.actions.length > 0 && editable ? (
    <ContextMenu sections={menu.sections}>{chip}</ContextMenu>
  ) : (
    chip
  );
}

// A Draft's attachments and inline images, with what can still be done to each. An editor that
// converts between the two offers that too.
export function DraftAssets({
  draft,
  editable,
  check,
  onRemove,
  onCancel,
  onConvert,
  onPreview,
  onResize,
}: {
  readonly draft: Draft;
  readonly editable: boolean;
  // The files Send is checking; each shows Checking… until its read finishes.
  readonly check?: SendCheck | undefined;
  readonly onRemove: (id: string) => void;
  readonly onCancel: (id: string) => void;
  readonly onConvert?: ((id: string) => void) | undefined;
  // An editor that shows Inline Images itself receives each verified thumbnail.
  readonly onPreview?: ((id: string, uri: string | null) => void) | undefined;
  // Shows every use of a body image at a display width, or with none at its original size.
  readonly onResize: (id: string, width: ImageWidth | undefined) => void;
}) {
  const store = useDraftStore();
  const { t } = useLocalization();
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  const attachments = draft.attachments ?? [];
  const images = [
    ...new Map(
      [
        ...imagesOf(textOf(draft.body)),
        ...(draft.quoted === undefined ? [] : imagesOf(draft.quoted)),
      ].map((asset) => [asset.id, asset]),
    ).values(),
  ];
  if (attachments.length + images.length === 0) {
    return null;
  }
  const inBody = new Set(imagesOf(textOf(draft.body)).map(({ id }) => id));
  const rows = (assets: readonly Asset[], inline: boolean) =>
    assets.map((asset) => (
      <AssetRow
        key={asset.id}
        asset={asset}
        check={check}
        editable={editable}
        inline={inline}
        onCancel={onCancel}
        onConvert={onConvert}
        onPreview={onPreview}
        onRemove={onRemove}
        {...(inline && inBody.has(asset.id)
          ? {
              width: imageWidthOf(textOf(draft.body), asset.id),
              onResize: (width: ImageWidth | undefined) => {
                onResize(asset.id, width);
              },
            }
          : {})}
        running={running.has(asset.id)}
      />
    ));
  return (
    <View style={styles.assets}>
      {unsendableAssets(draft).length > 0 ? (
        <Alert message={t('drafts.assets.unsendable')} />
      ) : null}
      <View
        accessibilityLabel={t('drafts.assets.attachments')}
        accessibilityRole="list"
        style={styles.assetChips}>
        {rows(attachments, false)}
        {rows(images, true)}
      </View>
    </View>
  );
}

// A reply's or forward's quoted correspondence, read-only beneath the authored body when shown.
function QuotedText({ quoted }: { readonly quoted: SemanticDocument }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [shown, setShown] = useState(false);
  return (
    <View style={styles.quoted}>
      <Action
        variant="composer"
        expanded={shown}
        label={
          shown
            ? t('drafts.response.hideQuoted')
            : t('drafts.response.showQuoted')
        }
        onPress={() => {
          setShown((current) => !current);
        }}
      />
      {shown ? (
        <Text
          selectable
          style={[
            styles.quotedText,
            { color: colors.textSecondary, borderLeftColor: colors.separator },
          ]}>
          {displayOf(quoted).text.replaceAll(imageCharacter, '')}
        </Text>
      ) : null}
    </View>
  );
}

const textToolLabel = (tool: TextTool, at: Selection) =>
  at.start === at.end
    ? (`assistance.${tool}DraftLabel` as const)
    : (`assistance.${tool}SelectionLabel` as const);

const textToolSymbols: Readonly<Record<TextTool, string>> = {
  rewrite: 'pencil',
  proofread: 'text.badge.checkmark',
  paragraphs: 'text.alignleft',
  expand: 'arrow.up.and.down.text.horizontal',
  shorten: 'arrow.down.and.line.horizontal.and.arrow.up',
  friendly: 'face.smiling',
  neutral: 'face.dashed',
};

// The format bar's Writing tools menu. A choice reports its purpose; the composer checks it
// against its current Draft before capturing text. Generate a Draft first asks for a prompt in a
// popover below the menu; the prompt is never kept.
export function WritingTools({
  draft,
  selection,
  disabled = false,
  onCapture,
  onGenerate,
}: {
  readonly draft: Draft;
  readonly selection: Selection;
  readonly disabled?: boolean;
  readonly onCapture: (
    purpose: DraftTextPurpose,
    target?: TranslationLanguage,
  ) => void;
  readonly onGenerate: (prompt: string) => void;
}) {
  const { t } = useLocalization();
  const assistance = use(AssistanceContext);
  // Each opening of Generate a Draft is a new prompt; none outlives Mail Assistance.
  const [prompting, setPrompting] = useState(false);
  const [openings, setOpenings] = useState(0);
  if (prompting && assistance === undefined) {
    setPrompting(false);
  }
  const translation = use(TranslationContext);
  const targetLanguages = useTargetLanguages(
    translation,
    undefined,
    (language) => {
      onCapture('translate', language);
    },
  );
  const rewritable = canRewrite(draft.body, selection);
  const tools = (...names: TextTool[]): PopUpItem[] =>
    assistance === undefined
      ? []
      : names.map((tool) => ({
          key: tool,
          title: t(`assistance.${tool}`),
          symbol: textToolSymbols[tool],
          accessibilityLabel: t(textToolLabel(tool, selection)),
          disabled: !rewritable,
          run: () => {
            onCapture(tool);
          },
        }));
  return assistance === undefined && translation === undefined ? null : (
    <View>
      <PopUp
        disabled={disabled}
        accessibilityLabel={t('drafts.writingTools')}
        icon="sparkles"
        sections={[
          [
            ...(assistance === undefined
              ? []
              : [
                  {
                    key: 'generate',
                    title: t('assistance.generate'),
                    symbol: 'square.and.pencil',
                    accessibilityLabel: t('assistance.generateLabel'),
                    run: () => {
                      setOpenings(openings + 1);
                      setPrompting(true);
                    },
                  },
                ]),
            ...tools('rewrite'),
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
          ],
          tools('proofread', 'paragraphs'),
          translation === undefined
            ? []
            : [
                {
                  key: 'translate',
                  title: t('translation.translateTo'),
                  symbol: 'translate',
                  accessibilityLabel: t('translation.translateSelectionLabel'),
                  disabled: !hasTranslatableText(
                    selectedText(
                      textOf(draft.body),
                      selection,
                      translationInputLimit + 1,
                    ),
                  ),
                  items: targetLanguages,
                },
              ],
          tools('expand', 'shorten'),
          tools('friendly', 'neutral'),
        ].flatMap((items) => (items.length === 0 ? [] : [{ items }]))}
      />
      <GeneratePrompt
        key={openings}
        shown={prompting}
        disabled={disabled}
        onClose={() => {
          setPrompting(false);
        }}
        onGenerate={onGenerate}
      />
    </View>
  );
}

// One opening of Generate a Draft. Every dismissal settles it once, so already-queued input
// cannot generate a closed prompt. AppKit retains the content while fading out.
function GeneratePrompt({
  shown,
  disabled,
  onClose,
  onGenerate,
}: {
  readonly shown: boolean;
  readonly disabled: boolean;
  readonly onClose: () => void;
  readonly onGenerate: (prompt: string) => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const [prompt, setPrompt] = useState('');
  const settled = useRef(false);
  useLayoutEffect(() => {
    settled.current = false;
    return () => {
      settled.current = true;
    };
  }, []);
  const generable = !disabled && canGenerate(prompt);
  const close = () => {
    if (!settled.current) {
      settled.current = true;
      onClose();
    }
  };
  const generate = () => {
    if (generable && !settled.current) {
      close();
      onGenerate(prompt);
    }
  };
  useMailAssistanceLifetime(close);
  return (
    <Popover
      below
      title={t('assistance.generatePromptTitle')}
      shown={shown}
      onClose={close}>
      <View style={styles.generate}>
        <View style={styles.generateTitle}>
          <SFSymbol
            name="sparkles"
            color={colors.textPrimary}
            size={13}
          />
          <Text
            selectable
            accessibilityRole="header"
            style={[styles.title, styles.grow, { color: colors.textPrimary }]}>
            {t('assistance.generatePromptTitle')}
          </Text>
          <ToolbarButton
            icon="xmark"
            label={t('assistance.closeGenerate')}
            onPress={close}
          />
        </View>
        <TextInput
          multiline
          submitBehavior="submit"
          accessibilityLabel={t('assistance.generatePromptLabel')}
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- The person opened the popover to type a prompt; it focuses once AppKit gives it a window.
          autoFocus
          onChangeText={setPrompt}
          // AppKit reports Escape in a text input as a key press; it closes like the Close button.
          onKeyPress={({ nativeEvent }) => {
            if (nativeEvent.key === 'Escape') {
              close();
            }
          }}
          onSubmitEditing={generate}
          placeholder={t('assistance.generatePrompt')}
          placeholderTextColor={colors.textSecondary}
          style={[styles.generatePrompt, { color: colors.textPrimary }]}
          value={prompt}
        />
        <View style={styles.generateActions}>
          <Button
            disabled={!generable}
            fill="accent"
            label={t('assistance.generateAction')}
            accessibilityLabel={t('assistance.generateActionLabel')}
            onPress={generate}
          />
        </View>
      </View>
    </Popover>
  );
}

// The Draft with the entries still being typed in To, Cc and Bcc finished, as Send finishes them;
// invalid text stays in its field.
const finishedEntries = (draft: Draft) => {
  let finished = draft;
  for (const field of ['to', 'cc', 'bcc'] as const) {
    finished = addRecipients(finished, {
      field,
      text: entryOf(finished, field),
      all: true,
    }).draft;
  }
  return finished;
};

// The file Send Now waits for, while one is still being added.
const addingName = (draft: Draft, running: ReadonlySet<string>) =>
  addingAsset(draft, running)?.name;

// Why Send is unavailable, given the Outbox's `refusal`: files that were not added leave it
// available, since Send asks to send without them, though one still being added does not.
const blockedBy = (
  refusal: SendRefusal | undefined,
  draft: Draft,
  running: ReadonlySet<string>,
) =>
  refusal === 'assets' && addingAsset(draft, running) === undefined
    ? undefined
    : refusal;

// Why Send is unavailable now, or else why the last Send left the Draft in the composer, if it
// did; only the last Send's outcome is announced. A message sent through an IMAP connection's mail
// server or Microsoft is not limited by Gmail.
const tooLarge = {
  gmail: 'drafts.sendRefused.too-large',
  imap: 'drafts.sendRefused.too-large_imap',
  'microsoft-graph': 'drafts.sendRefused.too-large_microsoft',
} as const satisfies Readonly<Record<MailProvider, string>>;
function SendRefusalNotice({
  refused,
  blocked,
  connection,
}: {
  readonly refused: SendRefusal | undefined;
  readonly blocked: SendRefusal | undefined;
  readonly connection: string;
}) {
  const { t } = useLocalization();
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === connection,
  )?.provider;
  const shown = blocked ?? refused;
  return shown === undefined ? null : (
    <Alert
      outcome={shown === refused}
      message={t(
        shown === 'too-large'
          ? tooLarge[provider ?? 'gmail']
          : `drafts.sendRefused.${shown}`,
      )}
    />
  );
}

// Profile changes, source edits and disabled assistance retire captured input. Re-enabling
// assistance never restarts a retired request.
export const retires = (
  captured: CapturedDraftText & { readonly profile: string },
  draft: CapturedDraftText['draft'],
  {
    assistance,
    translation,
    profile,
  }: Readonly<{
    assistance: NativeAssistance | undefined;
    translation: NativeTranslation | undefined;
    profile: string;
  }>,
) =>
  captured.profile !== profile ||
  !sameDraftAssistanceSource(captured.draft, draft, captured.purpose) ||
  (captured.purpose === 'translate' ? translation : assistance) === undefined;

// The review panel for captured Draft text, while its framework is enabled.
export function CapturedAssistance({
  captured,
  assistance,
  translation,
  onApply,
  onClose,
  onPending,
}: {
  readonly captured: CapturedDraftText & {
    readonly target?: TranslationLanguage | undefined;
  };
  readonly assistance: NativeAssistance | undefined;
  readonly translation: NativeTranslation | undefined;
  readonly onApply: (text: string) => void;
  readonly onClose: () => void;
  readonly onPending?: ((pending: boolean) => void) | undefined;
}) {
  if (captured.purpose === 'translate') {
    return translation === undefined || captured.target === undefined ? null : (
      <DraftTranslation
        translator={translation}
        text={captured.text}
        target={captured.target}
        onApply={onApply}
        onClose={onClose}
      />
    );
  }
  return assistance === undefined ? null : (
    <DraftAssistance
      native={assistance}
      original={captured}
      purpose={captured.purpose}
      issue={captured.issue}
      input={captured.input}
      onApply={onApply}
      onClose={onClose}
      onPending={onPending}
    />
  );
}

// Why the composer stays open, or what it asks before discarding, above the format bar.
export function ComposerNotices({
  closing,
  draft,
  refused,
  blocked,
  onClose,
  onDiscard,
  onKeepEditing,
}: {
  readonly closing: Closing | undefined;
  readonly draft: Draft;
  readonly refused: SendRefusal | undefined;
  // Why Send is unavailable now; To, Cc and Bcc show their own reasons, and From the sender's.
  readonly blocked?: SendRefusal | undefined;
  readonly onClose: () => void;
  readonly onDiscard: () => void;
  readonly onKeepEditing: () => void;
}) {
  const { t } = useLocalization();
  return (
    <View style={styles.alerts}>
      {closing === 'blocked' || closing === 'discard-blocked' ? (
        <Alert
          outcome
          message={
            closing === 'discard-blocked'
              ? t('drafts.discardBlocked')
              : t('drafts.saveBlocked')
          }>
          <Button
            label={t('common.retry')}
            onPress={closing === 'discard-blocked' ? onDiscard : onClose}
          />
        </Alert>
      ) : null}
      {closing === 'recipients' ? (
        <Alert
          outcome
          message={t('drafts.invalidRecipients')}
        />
      ) : null}
      <SendRefusalNotice
        connection={draft.connection}
        refused={refused}
        blocked={
          blocked === 'recipients' ||
          blocked === 'entries' ||
          blocked === 'sender'
            ? undefined
            : blocked
        }
      />
      <SendingNotice draft={draft} />
      {closing === 'discard' ? (
        <Alert
          outcome
          message={t('drafts.discardConfirm')}>
          <Button
            destructive
            label={t('drafts.discardDraft')}
            onPress={onDiscard}
          />
          <Button
            label={t('drafts.keepEditing')}
            onPress={onKeepEditing}
          />
        </Alert>
      ) : null}
    </View>
  );
}

// A New Message window's toolbar row, which takes the composer's From, and its actions and Send,
// in place of its header and bottom row.
export type Toolbar = (from: ReactNode, actions: ReactNode) => ReactNode;
// A New Message window's way back to an Inbox window: before Save Draft, brings that window
// forward and resolves how to hand it the saved Draft, or undefined to keep the Draft here.
export type ReturnTo = () => Promise<((id: string) => void) | undefined>;
// An Inbox window composer's Draft, which a returning Draft first asks to save.
export type OpenDraft = Readonly<{
  title: () => string;
  save: () => Promise<boolean>;
}>;

// A new Mail Template's identifier: random lowercase letters and digits.
const templateId = () => {
  let id = '';
  while (id.length < 24) {
    id += Math.random().toString(36).slice(2);
  }
  return id.slice(0, 24);
};

// The format bar's Templates control: the Mail Profile's templates for the Draft from `connection`,
// read when it opens and after it saves one, and saving the Draft as `getDraft` gives it, when
// chosen, as a new template under the name asked for. The Draft itself does not change.
function DraftTemplates({
  connection,
  disabled,
  getDraft,
  onInsert,
}: {
  readonly connection: string;
  readonly disabled: boolean;
  readonly getDraft: () => Draft;
  readonly onInsert: (template: StoredMailTemplate) => void;
}) {
  const { t } = useLocalization();
  const store = useMailTemplates();
  const profile = profileOf(connection, use(AccountContext)?.mailboxes ?? []);
  const [templates, setTemplates] = useState<{
    readonly profile: string;
    readonly list: readonly StoredMailTemplate[];
  }>();
  // Only the latest read shows, and none once unmounted.
  const reads = useRef(0);
  const anchor = useRef<View>(null);
  const question = useRef<{ readonly retire: () => void }>(undefined);
  useLayoutEffect(
    () => () => {
      reads.current += 1;
      question.current?.retire();
    },
    [],
  );
  const read = useCallback(
    async (owner: string) => {
      reads.current += 1;
      const at = reads.current;
      const list = await store.templates(owner).catch(() => undefined);
      if (at === reads.current && list !== undefined) {
        setTemplates({ profile: owner, list });
      }
    },
    [store],
  );
  useEffect(() => {
    void read(profile);
  }, [read, profile]);
  // The Draft can move to another Profile while a save is pending; its list is the one to refresh.
  const profileNow = useRef(profile);
  useLayoutEffect(() => {
    profileNow.current = profile;
  });
  const notSaved = (detail: string) => {
    question.current = askInSheet(anchor.current, {
      title: t('drafts.templates.notSaved'),
      detail,
      buttons: [t('common.ok')],
    });
  };
  const save = async () => {
    const { subject, body: shown } = getDraft();
    const body = textOf(shown);
    const owner = profile;
    question.current?.retire();
    if (imagesOf(body).length > 0) {
      notSaved(t('drafts.templates.hasImages'));
      return;
    }
    if (shown.some((part) => part.kind === 'table')) {
      notSaved(t('drafts.templates.hasTables'));
      return;
    }
    const naming = askForText(anchor.current, {
      title: t('drafts.templates.nameTitle'),
      detail: t('drafts.templates.nameDetail'),
      buttons: [t('drafts.templates.save'), t('common.cancel')],
      field: t('drafts.templates.name'),
    });
    question.current = naming;
    const choice = await naming.answer;
    if (choice?.index !== 0) {
      return;
    }
    const name = choice.text.trim();
    if (name === '') {
      notSaved(t('drafts.templates.needsName'));
      return;
    }
    const saved = await store
      .save(owner, { id: templateId(), name, subject, body })
      .catch(() => false);
    if (anchor.current === null) {
      return;
    }
    if (saved) {
      void read(profileNow.current);
    } else {
      notSaved(t('drafts.templates.notSavedDetail'));
    }
  };
  return (
    <View
      ref={anchor}
      collapsable={false}>
      <TemplatesMenu
        disabled={disabled}
        templates={templates?.profile === profile ? templates.list : []}
        onInsert={onInsert}
        onSave={() => {
          void save();
        }}
      />
    </View>
  );
}

// Keeps the editor's unsaved version, which `unsaved` returns, in a composer recovery record
// through the shared journal (ADR 0077): a few seconds after each `edited` change and when the app
// returns to the foreground. The first returned function closes the journal on Draft `id` the
// editor closes on and resolves once its records are gone, so Quit waits for them. The
// second journals at once, as after a save that keeps the editor open.
export function useRecoveryJournal(
  edited: unknown,
  unsaved: () => Recovery | undefined,
  editor: (id: string) => void,
) {
  const store = useDraftStore();
  const journal = useMemo(
    () => createRecoveryJournal(store, unsaved, editor),
    [editor, store, unsaved],
  );
  useEffect(() => {
    journal.adopt();
  }, [journal]);
  const seen = useRef(edited);
  useEffect(() => {
    if (seen.current !== edited) {
      seen.current = edited;
      journal.edited();
    }
  });
  useEffect(() => {
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active') {
        journal.resume();
      }
    });
    return () => {
      subscription.remove();
      journal.dispose();
    };
  }, [journal]);
  return [journal.close, journal.write] as const;
}

// A Product Account's offer of the composer recovery records the previous run left: those already
// offered, and the window offering them. One window at a time offers, and keeps the offer while its
// restored composer is open; releasing it wakes the windows waiting for it.
interface RecoveryOffer {
  readonly offered: Set<string>;
  readonly waiting: Set<() => void>;
  window?: object;
}
const recoveryOffers = new WeakMap<
  object,
  Map<string | undefined, RecoveryOffer>
>();

// A restored composer recovery record: the unsaved `version` and the stored version its edits
// started from, or for a record without one, the Draft as listed when it was offered, which the
// editor saves against.
export interface Recovered {
  readonly version: Draft;
  readonly base: Draft;
}

const releaseOffer = (offer: RecoveryOffer | undefined, window: object) => {
  if (offer?.window === window) {
    delete offer.window;
    for (const wake of offer.waiting) {
      wake();
    }
  }
};

// Offers each composer recovery record the previous run left (ADR 0077) whose Draft and recovered
// sender belong to this window's Profile, in its own alert, once the Drafts open and while this
// window has no composer open. Restore passes the record to `onRestore`, which opens it in a
// composer, and Discard removes it unless an editor has its Draft open. A record changed or removed
// since it was read, an alert closed without an answer, a failed removal and a Draft no longer
// listed leave the record for the next launch. Returns the anchor for the window's root view.
export function useRecoveryOffer(
  composing: string | undefined,
  onRestore: (recovered: Recovered) => void,
) {
  const store = useDraftStore();
  const ready = useDrafts().kind === 'ready';
  const profile = useProfile();
  const accountContext = use(AccountContext);
  const mailboxes = accountContext?.mailboxes;
  const account = accountContext?.account;
  const { t } = useLocalization();
  const anchor = useRef<View>(null);
  const window = useRef({});
  const [round, setRound] = useState(0);
  // Whether the last records read was refused, and how often the app became active.
  const refused = useRef(false);
  const activations = useRef(0);
  useEffect(() => {
    const subscription = AppState.addEventListener('change', (next) => {
      if (next !== 'active') {
        return;
      }
      activations.current += 1;
      if (refused.current) {
        refused.current = false;
        setRound((count) => count + 1);
      }
    });
    return () => {
      subscription.remove();
    };
  }, []);
  // Each mailbox with the Profile it belongs to.
  const members = (mailboxes ?? [])
    .map(({ id }) => `${id} ${profileOf(id, mailboxes ?? [])}`)
    .join('\n');
  const latest = useRef({ onRestore, mailboxes, members });
  useLayoutEffect(() => {
    latest.current = { onRestore, mailboxes, members };
  });
  // The mailboxes and their Profiles when this window last found no record to offer. A mailbox
  // joining, leaving or moving between Profiles can make one its own, so it looks again; other
  // mailbox updates leave an open alert alone.
  const idle = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (idle.current !== undefined && idle.current !== members) {
      idle.current = undefined;
      setRound((count) => count + 1);
    }
  }, [members]);
  useEffect(
    () => () => {
      releaseOffer(recoveryOffers.get(store)?.get(account), window.current);
    },
    [account, store],
  );
  useEffect(() => {
    if (!ready) {
      return;
    }
    const offers =
      recoveryOffers.get(store) ?? new Map<string | undefined, RecoveryOffer>();
    recoveryOffers.set(store, offers);
    let offer = offers.get(account);
    if (offer === undefined) {
      offer = { offered: new Set(), waiting: new Set() };
      offers.set(account, offer);
    }
    const own = offer;
    const self = window.current;
    const wake = () => {
      setRound((count) => count + 1);
    };
    if (own.window === undefined && composing === undefined) {
      own.window = self;
    }
    if (own.window !== self || composing !== undefined) {
      own.waiting.add(wake);
      return () => {
        own.waiting.delete(wake);
      };
    }
    let current = true;
    let question: ReturnType<typeof askInSheet> | undefined = undefined;
    // The record `draft` as storage holds it now, if it has not changed since it was read.
    const unchanged = async (draft: Draft) => {
      const records = await store.recovered();
      return (
        records?.some(
          ({ version }) =>
            version.id === draft.id && sameContent(version, draft),
        ) === true
      );
    };
    // Whether record `draft` and its Draft as listed now belong to this window's Profile.
    const owned = (draft: Draft) => {
      const listed = draftOf(store.getSnapshot(), draft.id);
      const known = latest.current.mailboxes ?? [];
      return (
        listed !== undefined &&
        profileOf(listed.connection, known) === profile &&
        profileOf(draft.connection, known) === profile
      );
    };
    // An editor holding the Draft keeps its record; this one holds nothing.
    const discarding = () => undefined;
    const ask = async () => {
      const activated = activations.current;
      const records = await store.recovered();
      const pending = records?.find(
        ({ version }) => !own.offered.has(version.id) && owned(version),
      );
      if (!current) {
        return;
      }
      // A read storage refused, as while locked, is read again once the app is active again.
      if (records === undefined && activations.current !== activated) {
        wake();
      }
      refused.current =
        records === undefined && activations.current === activated;
      if (pending === undefined) {
        idle.current = latest.current.members;
        releaseOffer(own, self);
        return;
      }
      const draft = pending.version;
      // A record changed or removed since it was read, as by an editor in another window, is not
      // offered; it stays for the next launch. One whose Draft moved meanwhile stays for its Profile.
      const intact = await unchanged(draft);
      if (!current) {
        return;
      }
      if (!intact || !owned(draft)) {
        if (!intact) {
          own.offered.add(draft.id);
        }
        wake();
        return;
      }
      const base = pending.base ?? draftOf(store.getSnapshot(), draft.id);
      question = askInSheet(anchor.current, {
        title: t('drafts.recover.title'),
        detail: t('drafts.recover.detail'),
        buttons: [t('drafts.recover.restore'), t('drafts.recover.discard')],
        // Escape restores, so only an explicit Discard removes the record.
        cancel: 0,
        destructive: 1,
      });
      const choice = await question.answer;
      const kept = choice !== null && (await unchanged(draft));
      if (!current || base === undefined) {
        return;
      }
      // A kept record whose Draft moved to another Profile meanwhile stays for that Profile's windows.
      if (kept && !owned(draft)) {
        wake();
        return;
      }
      own.offered.add(draft.id);
      if (kept) {
        store.take(draft.id);
        if (choice === 0) {
          latest.current.onRestore({ version: draft, base });
          return;
        }
        await store.forget(draft.id, discarding);
      }
      wake();
    };
    // An offer that fails unexpectedly lets the other windows offer, unless a later attempt has
    // replaced it; store calls log their own failures.
    const offerNext = async () => {
      try {
        await ask();
      } catch {
        if (current) {
          releaseOffer(own, self);
        }
      }
    };
    idle.current = undefined;
    void offerNext();
    return () => {
      current = false;
      question?.retire();
    };
    // oxlint-disable-next-line react/exhaustive-effect-dependencies -- Each answer asks again.
  }, [account, composing, profile, ready, round, store, t]);
  return anchor;
}

// The Send Reminder `read` while it belongs to `draft` in `profile`: one read before the editor
// moved to a conflict copy or another Profile belongs to that Draft.
const reminderOf = (
  read: SendReminder | undefined,
  draft: string,
  profile: string,
) => (read?.draft === draft && read.profile === profile ? read : undefined);

// The Draft's Send Reminder banner, and the reminder change that last failed.
function DraftReminder({
  reminder,
  failed,
  ...banner
}: Omit<ComponentProps<typeof ReminderBanner>, 'reminder'> & {
  readonly reminder: SendReminder | undefined;
  readonly failed: 'set' | 'remove' | undefined;
}) {
  const { t } = useLocalization();
  return (
    <>
      {failed === undefined ? null : (
        <View style={styles.alerts}>
          <Alert
            outcome
            message={t(
              failed === 'set'
                ? 'drafts.reminder.setFailed'
                : 'drafts.reminder.removeFailed',
            )}
          />
        </View>
      )}
      {reminder === undefined ? null : (
        <View style={styles.alerts}>
          <ReminderBanner
            reminder={reminder}
            {...banner}
          />
        </View>
      )}
    </>
  );
}

// Up to four Recipient Suggestions for an @ in the body: recent correspondents of the Draft's
// Mail Profile and the people already on the Draft, then for typed text Apple Contacts.
function bodySuggestions(
  draft: Draft,
  query: BodyRecipientQuery,
  {
    connections,
    held,
    contacts,
  }: Readonly<{
    connections: readonly MailboxConnection[];
    held: ReturnType<typeof useAllMailboxes>;
    contacts: Iterable<Readonly<{ sender: string; address: string }>>;
  }>,
) {
  return bodySuggestionSections(draft, query, {
    ...correspondentsFor(draft, connections, held),
    contacts,
  });
}

const plainEvent = (event: KeyEvent['nativeEvent']) =>
  !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey;

// The Body Recipient Shortcut in an editor's body. Typing @ at a paragraph start or after
// whitespace opens Recipient Suggestions under it; a space, Escape, a caret move, leaving the body or a choice
// closes them, keeping the typed text.
function useBodyRecipients(
  draft: Draft,
  selection: Selection,
  {
    paused,
    pausedNow,
    bodyID,
  }: Readonly<{
    paused: boolean;
    // Ahead of rendering, as native events can arrive before a pause commits.
    pausedNow: Readonly<{ current: boolean }>;
    bodyID: string;
  }>,
) {
  const { t } = useLocalization();
  // The @ whose suggestions show.
  const [armed, setArmed] = useState<number>();
  const armedNow = useRef(armed);
  const [chosen, setChosen] = useState(0);
  // The statuses VoiceOver last heard for the shown suggestions.
  const heard = useRef<
    Readonly<{ empty?: string | undefined; note?: string | undefined }>
  >({});
  const arm = useCallback((at: number | undefined) => {
    armedNow.current = at;
    heard.current = {};
    setArmed(at);
    setChosen(0);
  }, []);
  const close = useCallback(() => {
    arm(undefined);
  }, [arm]);
  const query = useMemo(
    () => bodyRecipientQuery(textOf(draft.body), selection),
    [draft.body, selection],
  );
  const open = !paused && armed !== undefined && query?.start === armed;
  // Read once each time an @ arms, never asking for Contacts access.
  const contacts = useContactAddresses(armed !== undefined, false);
  const connections = use(AccountContext)?.mailboxes;
  const held = useAllMailboxes();
  const sections = useMemo(
    () =>
      open && query !== undefined
        ? bodySuggestions(draft, query, {
            connections: connections ?? [],
            held,
            contacts: contacts.addresses,
          })
        : undefined,
    [open, draft, query, connections, held, contacts.addresses],
  );
  const suggestions =
    sections === undefined ? [] : [...sections.recent, ...sections.contacts];
  const active = suggestions[Math.min(chosen, suggestions.length - 1)];
  // Where the body shows the @, and where the body sits, for the menu under the @. A new body
  // width reflows the text, so the @ is measured again for it.
  const [anchor, setAnchor] =
    useState<
      Readonly<{ at: number; width: number; left: number; top: number }>
    >();
  const [body, setBody] = useState({ x: 0, y: 0, width: 0 });
  const bodyWidth = body.width;
  useEffect(() => {
    if (armed === undefined) {
      return;
    }
    let current = true;
    void (async () => {
      try {
        const frame = await windowHost()?.composerCharacterFrame(bodyID, armed);
        if (current && frame !== null && frame !== undefined) {
          setAnchor({
            at: armed,
            width: bodyWidth,
            left: frame.x,
            top: frame.y + frame.height,
          });
        }
      } catch {
        // Without its place the menu stays closed; the typed text is kept.
      }
    })();
    return () => {
      current = false;
    };
  }, [armed, bodyID, bodyWidth]);
  // A bare @ with no recent correspondent shows nothing; typed text shows No Matches.
  const shown =
    sections !== undefined &&
    anchor !== undefined &&
    anchor.at === armed &&
    anchor.width === bodyWidth &&
    (suggestions.length > 0 || sections.query.text !== '')
      ? {
          sections,
          active,
          style: [
            styles.bodySuggestions,
            {
              // Under the @, kept inside the body near its trailing edge.
              left:
                body.x +
                Math.max(
                  0,
                  Math.min(
                    anchor.left - spacing.s,
                    body.width - styles.bodySuggestions.width,
                  ),
                ),
              top: body.y + anchor.top + spacing.s,
            },
          ],
          empty: t('drafts.bodyRecipient.noMatches'),
          note:
            contacts.failed && sections.query.text !== ''
              ? t('drafts.bodyRecipient.contactsUnsearchable')
              : undefined,
          roleOf: ({ address }: Recipient) => {
            const field = recipientRole(draft, address);
            return field === undefined
              ? undefined
              : t(`drafts.fields.${field}`);
          },
        }
      : undefined;
  // VoiceOver hears No Matches and the note once each appears, after the typed character, since
  // macOS ignores live regions. Renders between a typed character and its caret, when no query
  // is open, change nothing; a bare @ that hides the menu clears them.
  const emptyNow =
    shown !== undefined && suggestions.length === 0 ? shown.empty : undefined;
  const noteNow = shown?.note;
  const showing = shown !== undefined;
  const hidden = sections !== undefined && !showing;
  useEffect(() => {
    if (!showing) {
      if (hidden) {
        heard.current = {};
      }
      return;
    }
    const now = { empty: emptyNow, note: noteNow };
    for (const key of ['empty', 'note'] as const) {
      const words = now[key];
      if (words !== undefined && words !== heard.current[key]) {
        AccessibilityInfo.announceForAccessibilityWithOptions(words, {
          queue: true,
        });
      }
    }
    heard.current = now;
  }, [showing, hidden, emptyNow, noteNow]);
  let keys: typeof choosingKeys = [];
  if (shown !== undefined) {
    keys = suggestions.length === 0 ? closingKeys : choosingKeys;
  }
  return {
    shown,
    keys,
    // Typed Return and Tab choose the highlighted suggestion while any shows.
    choosing: keys === choosingKeys,
    close,
    placeBody: ({
      x,
      y,
      width,
    }: Readonly<{ x: number; y: number; width: number }>) => {
      setBody({ x, y, width });
    },
    // After a body edit inserting `inserted`: typing @ opens suggestions, and leaving its query
    // closes them.
    typed: (next: SemanticDocument, caret: Selection, inserted: string) => {
      const typed = bodyRecipientQuery(next, caret);
      if (inserted === '@' && typed?.text === '') {
        arm(typed.start);
      } else if (typed?.start === armedNow.current) {
        // The list changed, so the highlight starts over.
        setChosen(0);
      } else {
        arm(undefined);
      }
    },
    // The query a choice replaces in the latest body, while its suggestions show and the editor
    // takes edits.
    choosable: (latest: SemanticDocument, at: Selection) => {
      const current = bodyRecipientQuery(latest, at);
      return !pausedNow.current &&
        current?.start === armedNow.current &&
        current !== undefined
        ? current
        : undefined;
    },
    // What VoiceOver hears once a choice added the person, or inserted `text` for a person
    // already on the Draft.
    added: (recipient: Recipient, present: boolean, text: string) =>
      present
        ? t('drafts.bodyRecipient.inserted', { text })
        : t('drafts.bodyRecipient.added', {
            name: recipient.name ?? recipient.address,
          }),
    greeting: (recipient: Recipient) => {
      const name = greetingName(recipient, contacts.addresses);
      return name === undefined
        ? t('drafts.bodyRecipient.greetingUnnamed')
        : t('drafts.bodyRecipient.greeting', { name });
    },
    // In written text: the given name, else the display name, else the address.
    name: (recipient: Recipient) =>
      greetingName(recipient, contacts.addresses) ?? recipient.address,
    // Up and Down move, Return and Tab choose, Escape closes.
    keyDown: (
      event: KeyEvent['nativeEvent'],
      choose: (recipient: Recipient) => void,
    ) => {
      if (shown === undefined || !plainEvent(event)) {
        return;
      }
      const last = suggestions.length - 1;
      if (event.key === 'ArrowDown') {
        setChosen((index) => Math.min(index + 1, last));
      } else if (event.key === 'ArrowUp') {
        setChosen((index) => Math.max(Math.min(index, last) - 1, 0));
      } else if (event.key === 'Escape') {
        close();
      } else if (
        (event.key === 'Enter' || event.key === 'Tab') &&
        active !== undefined
      ) {
        choose(active);
      }
    },
  };
}

// The body's Recipient Suggestions while they show.
function BodyRecipientMenu({
  shown,
  onAccept,
}: {
  readonly shown: ReturnType<typeof useBodyRecipients>['shown'];
  readonly onAccept: (recipient: Recipient) => void;
}) {
  return shown === undefined ? null : (
    <SuggestionMenu
      {...shown}
      onAccept={onAccept}
    />
  );
}

// The Markdown marker that ends each Basic Block's row, as typed at a block's start.
const slashMarkers: Readonly<Record<BlockKind, string>> = {
  paragraph: '',
  heading1: '#',
  heading2: '##',
  heading3: '###',
  bulleted: '-',
  numbered: '1.',
  quote: '>',
  code: '```',
};
// The leading icon of each row: the frames' text glyphs, else an SF Symbol.
const slashIcons: Readonly<Record<BlockKind, string>> = {
  paragraph: 'textformat',
  heading1: 'H1',
  heading2: 'H2',
  heading3: 'H3',
  bulleted: 'list.bullet',
  numbered: 'list.number',
  quote: '”',
  code: 'curlybraces',
};
const slashGlyphs = new Set(['H1', 'H2', 'H3', '”']);
// The frames draw Text's and Code Block's symbols smaller than the list symbols.
const slashSymbolSizes: Readonly<Partial<Record<BlockKind, number>>> = {
  paragraph: 10.5,
  code: 11,
};
const isSlashBlock = (command: SlashCommand): command is BlockKind =>
  Object.hasOwn(slashMarkers, command);
// The menu's padding and section title, then 28pt rows.
const slashMenuHeight = (rows: number) => 12 + 22 + 28 * rows;
// How far the menu stays from the top and bottom of the composer's scrolling area.
const slashMenuMargin = 28;
// The frames hang the menu this far right of the / and this far from its line.
const slashMenuInset = 7;
const slashMenuGap = 3;

// Where a body shows the line of the / that opened its Slash Command Menu, from the / on.
type SlashLine = Readonly<{ left: number; top: number; bottom: number }>;

// The line of the character at `at` in the body's text view `bodyID`, once it is known.
function useCharacterLine(bodyID: string | undefined, at: number | undefined) {
  const [line, setLine] = useState<SlashLine & Readonly<{ at: number }>>();
  useEffect(() => {
    if (at === undefined || bodyID === undefined) {
      return;
    }
    let live = true;
    void (async () => {
      try {
        const frame = await windowHost()?.composerCharacterFrame(bodyID, at);
        if (live && frame !== null && frame !== undefined) {
          setLine({
            at,
            left: frame.x,
            top: frame.y,
            bottom: frame.y + frame.height,
          });
        }
      } catch {
        // Without its place the menu stays closed; the typed text is kept.
      }
    })();
    return () => {
      live = false;
    };
  }, [at, bodyID]);
  return line;
}
// A reported `line` for the / at `at`.
const lineAt = (line: SlashLine | undefined, at: number | undefined) =>
  line === undefined || at === undefined ? undefined : { ...line, at };

// The Slash Command Menu in an editor's body. Typing / as the first non-whitespace character of a
// body block outside code opens its Basic Blocks under the caret's line, or over it when more room
// is there; typing filters them. An empty result, a caret move, leaving the body, Escape or a choice
// closes it, keeping the typed text. The menu asks the body's text view `bodyID` where the / is, or
// hangs from the `line` a Draft editor page reports.
export function useSlashMenu(
  draft: Draft,
  selection: Selection,
  options: Readonly<{
    paused: boolean;
    // Ahead of rendering, as native events can arrive before a pause commits.
    pausedNow: Readonly<{ current: boolean }>;
  }> &
    (Readonly<{ bodyID: string }> | Readonly<{ line: SlashLine | undefined }>),
) {
  const { paused, pausedNow } = options;
  const bodyID = 'bodyID' in options ? options.bodyID : undefined;
  const { t } = useLocalization();
  const titleOf = useCallback(
    (kind: BlockKind) =>
      kind === 'paragraph'
        ? t('drafts.slashMenu.text')
        : t(`drafts.blocks.${kind}`),
    [t],
  );
  // What VoiceOver hears for a row: its title, then its Markdown marker.
  const labelOf = (kind: BlockKind) =>
    slashMarkers[kind] === ''
      ? titleOf(kind)
      : t('drafts.slashMenu.marked', {
          title: titleOf(kind),
          marker: slashMarkers[kind],
        });
  const blocksFor = useCallback(
    (typed: string) =>
      slashCommands(typed, (command) =>
        isSlashBlock(command) ? titleOf(command) : '',
      ).filter(isSlashBlock),
    [titleOf],
  );
  // Where the / that opened the menu is.
  const [armed, setArmed] = useState<number>();
  const armedNow = useRef(armed);
  // The row Up and Down Arrow highlighted, ahead of rendering; the first row without one.
  const [chosen, setChosen] = useState<BlockKind>();
  const chosenNow = useRef(chosen);
  const choose = (kind: BlockKind | undefined) => {
    chosenNow.current = kind;
    setChosen(kind);
  };
  // Where the composer's scrolling area is: always kept ahead of rendering, and rendered only
  // while the menu is open, so it keeps fitting as the window resizes or the composer scrolls.
  const viewport = useRef({ y: 0, height: 0 });
  const [room, setRoom] = useState({ y: 0, height: 0 });
  const arm = (at: number | undefined) => {
    armedNow.current = at;
    setArmed(at);
    setRoom(viewport.current);
    choose(undefined);
  };
  const close = () => {
    arm(undefined);
  };
  // The query and the blocks it lists for a body and caret, while the menu is open for it.
  const listed = (
    body: SemanticDocument,
    at: Selection,
    start: number | undefined,
  ) => {
    const query = slashQuery(body, at);
    return query === undefined || query.start !== start
      ? undefined
      : { query, kinds: blocksFor(query.text) };
  };
  const current = paused
    ? undefined
    : listed(textOf(draft.body), selection, armed);
  const kinds = current?.kinds ?? [];
  const active = kinds.find((kind) => kind === chosen) ?? kinds[0];
  const latest = (body: SemanticDocument, at: Selection) =>
    pausedNow.current ? undefined : listed(body, at, armedNow.current);
  // Where the body shows the /'s line, and where the body sits.
  const found = useCharacterLine(bodyID, armed);
  const anchor = 'line' in options ? lineAt(options.line, armed) : found;
  const [body, setBody] = useState({ x: 0, y: 0, width: 0 });
  const wanted = slashMenuHeight(kinds.length);
  const above =
    anchor === undefined ? 0 : body.y + anchor.top - room.y - slashMenuMargin;
  const below =
    anchor === undefined
      ? 0
      : room.y + room.height - body.y - anchor.bottom - slashMenuMargin;
  const over = wanted > below && above > below;
  // At least one row shows, however little room there is.
  const height =
    anchor === undefined
      ? 0
      : Math.max(Math.min(wanted, over ? above : below), slashMenuHeight(1));
  const shown =
    current === undefined ||
    active === undefined ||
    anchor === undefined ||
    anchor.at !== armed
      ? undefined
      : {
          query: current.query,
          kinds,
          active,
          height,
          style: [
            styles.bodySuggestions,
            {
              height,
              // Right of the /, kept inside the body near its trailing edge.
              left:
                body.x +
                Math.max(
                  0,
                  Math.min(
                    anchor.left + slashMenuInset,
                    body.width - styles.bodySuggestions.width,
                  ),
                ),
              top:
                body.y +
                (over
                  ? anchor.top - height - slashMenuGap
                  : anchor.bottom + slashMenuGap),
            },
          ],
        };
  // Up and Down move the highlight through the blocks listed for the latest `document` and caret
  // `at`, Return and Tab choose it, Escape closes.
  const press = (
    key: string,
    now: Readonly<{ document: SemanticDocument; at: Selection }>,
    apply: () => void,
  ) => {
    if (key === 'ArrowDown' || key === 'ArrowUp') {
      const listing = latest(now.document, now.at)?.kinds ?? [];
      const index =
        chosenNow.current === undefined
          ? 0
          : Math.max(listing.indexOf(chosenNow.current), 0);
      const step = key === 'ArrowDown' ? 1 : -1;
      const next =
        listing[Math.min(Math.max(index + step, 0), listing.length - 1)];
      if (next !== undefined && next !== listing[index]) {
        choose(next);
      }
    } else if (key === 'Escape') {
      close();
    } else if (key === 'Enter' || key === 'Tab') {
      apply();
    }
  };
  // Focus stays in the body, so VoiceOver hears each highlighted block as it shows.
  const heard = shown === undefined ? undefined : labelOf(shown.active);
  useEffect(() => {
    if (heard !== undefined) {
      AccessibilityInfo.announceForAccessibilityWithOptions(heard, {
        queue: true,
      });
    }
  }, [heard]);
  return {
    shown,
    titleOf,
    labelOf,
    keys: shown === undefined ? [] : choosingKeys,
    // Typed Return and Tab choose the highlighted block while the menu shows.
    choosing: shown !== undefined,
    close,
    placeBody: ({
      x,
      y,
      width,
    }: Readonly<{ x: number; y: number; width: number }>) => {
      setBody({ x, y, width });
    },
    placeViewport: (next: Partial<Readonly<{ y: number; height: number }>>) => {
      viewport.current = { ...viewport.current, ...next };
      if (armedNow.current !== undefined) {
        setRoom(viewport.current);
      }
    },
    // After a body edit inserting `inserted`: typing / first in a block opens the menu, and leaving
    // its query or filtering out every block closes it.
    typed: (next: SemanticDocument, caret: Selection, inserted: string) => {
      const typed = slashQuery(next, caret);
      if (inserted === '/' && typed?.text === '') {
        arm(typed.start);
        AccessibilityInfo.announceForAccessibilityWithOptions(
          t('drafts.slashMenu.title'),
          { queue: true },
        );
      } else if (
        typed !== undefined &&
        typed.start === armedNow.current &&
        blocksFor(typed.text).length > 0
      ) {
        // The list changed, so the highlight starts over.
        choose(undefined);
      } else if (armedNow.current !== undefined) {
        arm(undefined);
      }
    },
    // The query and the block a choice of `kind`, or Return without one, applies for the latest
    // body and caret, while the menu lists it.
    choice: (document: SemanticDocument, at: Selection, kind?: BlockKind) => {
      const open = latest(document, at);
      const picked =
        kind ??
        open?.kinds.find((each) => each === chosenNow.current) ??
        open?.kinds[0];
      return open === undefined ||
        picked === undefined ||
        !open.kinds.includes(picked)
        ? undefined
        : { query: open.query, kind: picked };
    },
    keyDown: (event: KeyEvent['nativeEvent'], apply: () => void) => {
      if (shown !== undefined && plainEvent(event)) {
        press(
          event.key,
          { document: textOf(draft.body), at: selection },
          apply,
        );
      }
    },
    // The keys a Draft editor page hands over while the menu shows, or Escape as the body leaves,
    // which may arrive before the latest report renders.
    press,
  };
}

// The body's Slash Command Menu while it shows: its Basic Blocks in a glass menu, the highlighted
// row filled and kept in view.
export function BodySlashMenu({
  shown,
  titleOf,
  labelOf,
  onChoose,
}: {
  readonly shown: ReturnType<typeof useSlashMenu>['shown'];
  readonly titleOf: (kind: BlockKind) => string;
  readonly labelOf: (kind: BlockKind) => string;
  readonly onChoose: (kind: BlockKind) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const list = useRef<ScrollView>(null);
  const scrolled = useRef(0);
  const index = shown === undefined ? -1 : shown.kinds.indexOf(shown.active);
  const height = shown?.height ?? 0;
  useEffect(() => {
    if (index < 0) {
      return;
    }
    // The first row shows the section title with it.
    const start = index === 0 ? 0 : 22 + 28 * index;
    const end = 22 + 28 * (index + 1);
    const visible = height - 12;
    if (start < scrolled.current) {
      list.current?.scrollTo({ y: start, animated: false });
    } else if (end > scrolled.current + visible) {
      list.current?.scrollTo({ y: end - visible, animated: false });
    }
  }, [index, height]);
  if (shown === undefined) {
    return null;
  }
  return (
    <MenuPanel
      label={t('drafts.slashMenu.title')}
      style={shown.style}>
      <ScrollView
        ref={list}
        onScroll={({ nativeEvent }) => {
          scrolled.current = nativeEvent.contentOffset.y;
        }}
        scrollEventThrottle={16}>
        <Text
          style={[
            styles.suggestionSection,
            styles.slashSection,
            { color: colors.textSecondary },
          ]}>
          {t('drafts.slashMenu.basicBlocks')}
        </Text>
        {shown.kinds.map((kind) => {
          const chosen = kind === shown.active;
          const primary = chosen ? colors.accentOnFill : colors.textPrimary;
          const secondary = chosen ? colors.accentOnFill : colors.textSecondary;
          const icon = slashIcons[kind];
          return (
            <Pressable
              key={kind}
              accessibilityLabel={labelOf(kind)}
              accessibilityRole="button"
              accessibilityState={{ selected: chosen }}
              // The body keeps focus, so typing continues after a click.
              focusable={false}
              onPress={() => {
                onChoose(kind);
              }}
              style={({ pressed }) => [
                styles.slashRow,
                pressed
                  ? { backgroundColor: colors.accentSelectionSubtle }
                  : null,
                chosen ? { backgroundColor: colors.accentFill } : null,
              ]}>
              <View style={styles.slashIcon}>
                {slashGlyphs.has(icon) ? (
                  <Text style={[styles.slashGlyph, { color: secondary }]}>
                    {icon}
                  </Text>
                ) : (
                  <SFSymbol
                    name={icon}
                    color={secondary}
                    size={slashSymbolSizes[kind] ?? 13}
                  />
                )}
              </View>
              <Text
                numberOfLines={1}
                style={[
                  styles.suggestionName,
                  styles.grow,
                  { color: primary },
                ]}>
                {titleOf(kind)}
              </Text>
              <Text style={[styles.suggestionName, { color: secondary }]}>
                {slashMarkers[kind]}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
    </MenuPanel>
  );
}

// Format › Increase Indent and Decrease Indent (Command-] and Command-[) offer what the body's
// selected list items allow while it takes edits, and run `run` for this body.
function useIndentMenu(
  body: string,
  allowed: Readonly<Record<IndentDirection, boolean>>,
  run: (direction: IndentDirection) => void,
) {
  const runNow = useRef(run);
  useLayoutEffect(() => {
    runNow.current = run;
  });
  const { outdent, indent } = allowed;
  useEffect(() => {
    windowHost()?.setComposerIndents(body, outdent, indent);
  }, [body, outdent, indent]);
  useEffect(() => {
    const host = windowHost();
    if (host === null) {
      return undefined;
    }
    const subscription = new NativeEventEmitter(host).addListener(
      'indent',
      (event: {
        readonly body: string;
        readonly direction: IndentDirection;
      }) => {
        if (event.body === body) {
          runNow.current(event.direction);
        }
      },
    );
    return () => {
      subscription.remove();
      host.setComposerIndents(body, false, false);
    };
  }, [body]);
}

function Editor({
  initial,
  opening,
  onClose,
  onClosedAfterRemoval,
  onRebind,
  onExpand,
  renderToolbar,
  returnTo,
  onOpenDraft,
}: {
  readonly initial: Draft;
  // The version the editor opens on: `initial`, or the unsaved version a composer recovery record
  // kept.
  readonly opening: Draft;
  readonly onClose: () => void;
  readonly onClosedAfterRemoval: (id: string) => void;
  // Another editor changed this Draft first, so this editor's version is now the copy `id`.
  readonly onRebind: (id: string) => void;
  // Moves the saved Draft into its own window, when offered.
  readonly onExpand?: ((id: string) => void) | undefined;
  readonly renderToolbar?: Toolbar | undefined;
  // In a New Message window, Close asks whether to save the Draft back to its Inbox window.
  readonly returnTo?: ReturnTo | undefined;
  // Follows this editor's Draft while it is open, for a returning Draft to save first.
  readonly onOpenDraft?: ((draft: OpenDraft | undefined) => void) | undefined;
}) {
  const store = useDraftStore();
  const colors = usePalette();
  const { t } = useLocalization();
  const [history, setHistory] = useState(() => historyOf(opening));
  const bodyID = `composer-body${useId()}`;
  // The body shows marks for typing before JavaScript renders them (ComposerFormatting.m); a
  // control or Undo that edits the body or toggles those marks ends that until its render shows,
  // whatever activated it.
  const fromControl = () => {
    windowHost()?.forgetComposerTyping(bodyID);
  };
  // The latest history, ahead of rendering, so consecutive events each build on the last one.
  const historyNow = useRef(history);
  const commitHistory = useCallback(
    (step: (current: typeof history) => typeof history) => {
      historyNow.current = step(historyNow.current);
      setHistory(historyNow.current);
    },
    [],
  );
  // Native events can arrive before React commits a rebind or an earlier edit.
  const authored = useRef(opening);
  const getDraft = useCallback(() => authored.current, []);
  // The version the store holds: the Draft as opened, until Save or Send stores this one.
  const stored = useRef(initial);
  // Whether storage may not hold the stored version yet, because its Save is pending or failed.
  const unsaved = useRef(false);
  const keepIdentity = useCallback((next: typeof history) => {
    if (next.present.id === authored.current.id) {
      return next;
    }
    const bound = (each: Draft): Draft => ({
      ...each,
      id: authored.current.id,
      conflict: true,
    });
    return {
      ...next,
      past: next.past.map(bound),
      present: bound(next.present),
      future: next.future.map(bound),
    };
  }, []);
  // Keeps editing, discarding and closing this editor's own version as its conflicting copy.
  const lifetime = useRef({ mounted: true, finishing: 0 });
  const onRebindNow = useRef(onRebind);
  useLayoutEffect(() => {
    onRebindNow.current = onRebind;
  }, [onRebind]);
  // One callback for this editor's lifetime, released when the editor and its operations finish.
  const rebind = useCallback(
    (id: string) => {
      const bound = (each: Draft): Draft => ({ ...each, id, conflict: true });
      const previous = authored.current;
      authored.current = bound(previous);
      stored.current =
        stored.current === previous ? authored.current : bound(stored.current);
      if (lifetime.current.mounted) {
        commitHistory((current) => ({
          ...current,
          past: current.past.map(bound),
          present: bound(current.present),
          future: current.future.map(bound),
        }));
        onRebindNow.current(id);
      }
    },
    [commitHistory],
  );
  useLayoutEffect(() => {
    const { current } = lifetime;
    current.mounted = true;
    store.hold(authored.current.id, rebind);
    return () => {
      current.mounted = false;
      // A pending Close or Discard still resolves its target through authored.current.
      if (current.finishing === 0) {
        store.release(rebind);
      }
    };
  }, [rebind, store]);
  const finishOperation = useCallback(() => {
    lifetime.current.finishing -= 1;
    if (!lifetime.current.mounted && lifetime.current.finishing === 0) {
      store.release(rebind);
    }
  }, [rebind, store]);
  const [selection, setSelection] = useState<Selection>({ start: 0, end: 0 });
  // Body text captured for an explicitly requested translation, rewrite or reply suggestion, until
  // its result is applied or the original kept.
  const profile = use(MailAssistanceProfileContext);
  const [captured, setCaptured] = useState<
    CapturedDraftText & {
      readonly id: number;
      readonly profile: string;
      // The language a translation was requested into.
      readonly target?: TranslationLanguage | undefined;
    }
  >();
  const captureNow = useRef<typeof captured>(undefined);
  // The capture whose request is running or whose result waits to be used.
  const pendingNow = useRef<number>(undefined);
  // The text tool whose result a body edit dropped, until Rewrite Again or Close.
  const [dropped, setDropped] = useState<TextTool>();
  const assistanceEnabled = useMailAssistanceLifetime(
    useCallback(() => {
      captureNow.current = undefined;
      setCaptured(undefined);
      setDropped(undefined);
    }, []),
  );
  const captureGeneration = useRef(0);
  // The latest body selection, ahead of rendering, for text events that follow a caret move.
  const selectionNow = useRef(selection);
  // Where the editor must place the caret after a change it did not type itself.
  const [placed, setPlaced] = useState<Selection>();
  // The text view reports no selection the editor places, so the format controls follow it here.
  const place = (next: Selection | undefined) => {
    setPlaced(next);
    if (next !== undefined) {
      setSelection(next);
    }
  };
  const bodyInput = useRef<TextInput>(null);
  // The Link Editor's fields take focus from the body, which then drops its selection; the
  // selection is kept, and Escape, Apply or Remove Link put it back with focus.
  const linking = useRef(false);
  // Marks toggled at a caret apply to the text typed there next.
  const [typing, setTyping] = useState<readonly Mark[]>();
  const typingNow = useRef(typing);
  const placeTyping = (next: readonly Mark[] | undefined) => {
    typingNow.current = next;
    setTyping(next);
  };
  const [closing, setClosing] = useState<Closing>();
  // Why the last Send left this Draft here.
  const [refused, setRefused] = useState<SendRefusal>();
  const [check, setCheck] = useState<SendCheck>();
  useOutcomeAnnouncement(
    check !== undefined && check.size > 0
      ? t('drafts.assets.checking')
      : undefined,
    false,
  );
  // While Save or Send is pending the editor accepts no edits, so nothing typed then is lost.
  const [paused, setPaused] = useState(false);
  // Native callbacks can arrive before the disabled props commit.
  const pausedNow = useRef(false);
  // A control that also waits while Save or Send is pending.
  const lockedUnless = (available: boolean) => paused || !available;
  const outbox = useOutbox();
  // Why Send is unavailable for the Draft shown, followed as its mailboxes change.
  const mailboxList = use(MailboxesContext);
  // Imports running now; an 'importing' file outside them was interrupted, so Send Now names only
  // a running one.
  const imports = useSyncExternalStore(store.subscribe, store.getImports);
  const blocked = blockedBy(
    useSyncExternalStore(mailboxList.subscribe, () =>
      outbox.refusal(finishedEntries(history.present)),
    ),
    history.present,
    imports,
  );
  const sendReminders = useSendReminders();
  // The Mail Profile owning this Draft, and so its Send Reminder.
  const draftProfile = profileOf(
    history.present.connection,
    use(AccountContext)?.mailboxes ?? [],
  );
  // The Draft's stored Send Reminder, once read, and which reminder change last failed.
  const [readReminder, setReadReminder] = useState<SendReminder>();
  const [reminderFailed, setReminderFailed] = useState<'set' | 'remove'>();
  // A pending Remove Reminder, which a reminder change waits for.
  const removingReminder = useRef(false);
  const draftID = history.present.id;
  const reminder = reminderOf(readReminder, draftID, draftProfile);
  // Read again after each stored change, such as one another device synchronized; only the
  // latest read applies.
  useEffect(() => {
    let latest = 0;
    const read = async () => {
      latest += 1;
      const mine = latest;
      const listed = await sendReminders.reminders(draftProfile);
      if (mine === latest && listed !== undefined) {
        setReadReminder(listed.find((each) => each.draft === draftID));
      }
    };
    void read();
    const unsubscribe = sendReminders.subscribe(() => void read());
    return () => {
      unsubscribe();
      latest += 1;
    };
  }, [sendReminders, draftProfile, draftID]);
  const caret = useRef<number | undefined>(undefined);
  const typingField = useRef<string | undefined>(undefined);
  const subjectSelection = useRef<Selection>({ start: 0, end: 0 });
  const subjectCaret = useRef<number | undefined>(undefined);
  const deletion = useRef<'backward' | 'forward' | undefined>(undefined);
  const draft = history.present;
  const [closeRecord, journalNow] = useRecoveryJournal(
    draft,
    useCallback(() => {
      if (authored.current === stored.current && !unsaved.current) {
        return undefined;
      }
      // No base while a save is pending or failed: storage may still hold the version before it.
      return unsaved.current
        ? { version: authored.current }
        : { version: authored.current, base: stored.current };
    }, []),
    rebind,
  );
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  if (
    captured !== undefined &&
    retires(captured, draft, { assistance, translation, profile })
  ) {
    setCaptured(undefined);
  }
  const breakTyping = () => {
    commitHistory((current) => ({ ...current, typing: false }));
  };
  const display = displayOf(textOf(draft.body));
  const recipientMenu = useBodyRecipients(draft, selection, {
    paused,
    pausedNow,
    bodyID,
  });
  const slashMenu = useSlashMenu(draft, selection, {
    paused,
    pausedNow,
    bodyID,
  });
  const appearance = useColorScheme() === 'dark' ? 'dark' : 'light';

  // Holds edits and finishing while Discard or Send runs.
  const discarded = useRef(false);
  const update = useCallback((next: Draft) => {
    const previous = authored.current;
    const bound =
      next.id === previous.id
        ? next
        : { ...next, id: previous.id, conflict: true as const };
    const capture = captureNow.current;
    if (
      bound.body !== previous.body ||
      (capture !== undefined &&
        !sameDraftAssistanceSource(capture.draft, bound, capture.purpose))
    ) {
      captureNow.current = undefined;
      setCaptured(undefined);
      if (
        capture !== undefined &&
        isTextTool(capture.purpose) &&
        pendingNow.current === capture.id
      ) {
        setDropped(capture.purpose);
      }
    }
    authored.current = bound;
    if (!discarded.current) {
      setRefused(undefined);
    }
  }, []);
  // Stores this editor's version; a Draft that changed elsewhere since it was opened becomes a
  // conflicting copy. False when the store declines it, as one moving into another Mail Profile:
  // it stays unstored, so Save tries it again and Close keeps its recovery record.
  const storeShown = useCallback(() => {
    if (authored.current === stored.current) {
      return true;
    }
    if (store.declines(authored.current, stored.current)) {
      return false;
    }
    void store.update(authored.current, stored.current, rebind);
    stored.current = authored.current;
    unsaved.current = true;
    return true;
  }, [rebind, store]);
  const storeAndSave = useCallback(async () => {
    const kept = storeShown();
    const saved = await store.save();
    if (saved) {
      unsaved.current = false;
    }
    return saved && kept;
  }, [store, storeShown]);
  const change = (next: Draft, word = false, field?: string) => {
    if (pausedNow.current) {
      return;
    }
    const continuing = typingField.current === field;
    commitHistory((current) =>
      keepIdentity(
        record(
          { ...current, typing: current.typing && continuing },
          next,
          word,
        ),
      ),
    );
    typingField.current = word ? field : undefined;
    if (!discarded.current && lifetime.current.finishing === 0) {
      setClosing(undefined);
    }
    update(next);
  };
  // An import settles in this editor's history before the store changes, so the next edit here
  // is not taken for a conflicting one.
  useLayoutEffect(
    () =>
      store.onSettle((id, next) => {
        // Keep shared body identity across the event-facing Draft and its history. Translation
        // ownership compares that identity, including after an import settles.
        const bodies = new Map<Draft['body'], Draft['body']>();
        const patch = (each: Draft) => {
          const patched = withAsset(each, id, next);
          const body = bodies.get(each.body) ?? patched.body;
          bodies.set(each.body, body);
          return { ...patched, body };
        };
        const previous = authored.current;
        authored.current = patch(previous);
        stored.current =
          stored.current === previous
            ? authored.current
            : patch(stored.current);
        commitHistory((current) => ({
          ...current,
          past: current.past.map(patch),
          present: patch(current.present),
          future: current.future.map(patch),
        }));
        const { past, present, future } = historyNow.current;
        return [...past, present, ...future];
      }),
    [commitHistory, store],
  );
  // Files become attachments; images placed inline go at the caret, replacing any selection.
  const addFiles = (files: readonly PickedFile[], inline: boolean) => {
    if (files.length === 0 || discarded.current || pausedNow.current) {
      return;
    }
    const prepared = prepareFiles(authored.current, {
      selection: selectionNow.current,
      files,
      inline,
    });
    change(prepared.draft);
    if (prepared.selection !== undefined) {
      caret.current = prepared.selection.start;
      selectionNow.current = prepared.selection;
      place(prepared.selection);
    }
    for (const { asset, file } of prepared.imports) {
      void store.importAsset(asset, file.source);
    }
  };
  const choose = async (source: PickSource, inline: boolean) => {
    if (discarded.current) {
      return;
    }
    addFiles(
      await store.pick(
        source,
        () =>
          lifetime.current.mounted &&
          lifetime.current.finishing === 0 &&
          !discarded.current,
      ),
      inline,
    );
  };
  // Removes files `ids` as one edit.
  const removeAssets = (ids: readonly string[]) => {
    if (pausedNow.current) {
      return;
    }
    for (const id of ids) {
      void store.cancelImport(id);
    }
    const without = (document: SemanticDocument) =>
      ids.reduce((remaining, id) => withoutImage(remaining, id), document);
    const latest = authored.current;
    const text = without(textOf(latest.body));
    change({
      ...latest,
      body: withText(latest.body, text),
      ...(latest.quoted === undefined
        ? {}
        : { quoted: without(latest.quoted) }),
      ...(latest.attachments === undefined
        ? {}
        : {
            attachments: latest.attachments.filter(
              (asset) => !ids.includes(asset.id),
            ),
          }),
    });
  };
  const removeAsset = (id: string) => {
    removeAssets([id]);
  };
  // Every use of a body image shows at `width`, as one edit; its current size changes nothing.
  const resizeAsset = (id: string, width: ImageWidth | undefined) => {
    if (pausedNow.current) {
      return;
    }
    const latest = authored.current;
    const body = withText(
      latest.body,
      withImageWidth(textOf(latest.body), id, width),
    );
    if (body !== latest.body) {
      change({ ...latest, body });
    }
  };
  // Undo and Redo step from the latest history, so repeated presses each move one step.
  const travel = (step: (current: typeof history) => typeof history) => {
    fromControl();
    if (pausedNow.current) {
      return;
    }
    // An Undo or Redo that restores a / does not open the menu.
    slashMenu.close();
    const before = displayOf(textOf(authored.current.body)).text.length;
    commitHistory((current) => keepIdentity(step(current)));
    placeTyping(undefined);
    update(historyNow.current.present);
    selectionNow.current = keptByTextView(
      selectionNow.current,
      before,
      displayOf(textOf(authored.current.body)).text.length,
    );
    place(selectionNow.current);
  };
  const edit = (text: string) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const textBefore = displayOf(textOf(latest.body)).text;
    // Native selection formatting reports its unchanged text to advance RN's event count.
    if (text === textBefore) {
      return;
    }
    const result = applyText(textOf(latest.body), text, {
      marks: typingNow.current,
      selection: at,
      deletion: deletion.current,
    });
    deletion.current = undefined;
    // One character added after the caret continues a typing step until a word ends.
    const added = text.length === textBefore.length + 1;
    const word = added && !/\s/u.test(text[at.start] ?? ' ');
    caret.current = at.end + text.length - textBefore.length;
    if (result.literal === undefined) {
      change(
        { ...latest, body: withText(latest.body, result.document) },
        word,
        'body',
      );
    } else {
      // The literal marker is its own step, so one Undo restores it.
      const withLiteral = {
        ...latest,
        body: withText(latest.body, result.literal),
      };
      const typed = { ...latest, body: withText(latest.body, result.document) };
      commitHistory((current) =>
        keepIdentity(record(record(current, withLiteral), typed)),
      );
      update(typed);
    }
    if (result.selection !== undefined) {
      caret.current = result.selection.start;
      selectionNow.current = result.selection;
      place(result.selection);
    }
    const typedAt = { start: caret.current, end: caret.current };
    // The typed text replaced the selection, so it ends where the selection's end moved to.
    const inserted = text.slice(
      at.start,
      at.end + text.length - textBefore.length,
    );
    recipientMenu.typed(result.document, typedAt, inserted);
    slashMenu.typed(result.document, typedAt, inserted);
  };
  const format = (mark: Mark) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const text = textOf(latest.body);
    if (at.start === at.end) {
      placeTyping(toggled(typingNow.current ?? marksAt(text, at), mark));
      return;
    }
    change({
      ...latest,
      body: withText(latest.body, toggleMark(text, at, mark)),
    });
  };
  // Replaces exactly the captured text with its reviewed result as one undoable edit; a prompted
  // draft captured no text, so it is inserted at the caret. Recipients,
  // the subject, quoted text, attachments and delivery state are left as they are.
  const applyCaptured = (replacement: string) => {
    const latest = authored.current;
    if (
      pausedNow.current ||
      !lifetime.current.mounted ||
      captured === undefined ||
      captureNow.current !== captured ||
      !sameDraftAssistanceSource(captured.draft, latest, captured.purpose)
    ) {
      return;
    }
    captureNow.current = undefined;
    setCaptured(undefined);
    const result = replaceSelection(
      textOf(latest.body),
      captured.selection,
      draftReplacement(captured.text, replacement),
    );
    change({ ...latest, body: withText(latest.body, result.document) });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    place(result.selection);
  };
  const closeCaptured = () => {
    if (
      !pausedNow.current &&
      captured !== undefined &&
      captureNow.current === captured
    ) {
      captureNow.current = undefined;
      setCaptured(undefined);
    }
  };
  // Keeps authored text captured for an explicitly requested translation, rewrite or reply
  // suggestion, or the caret and prompt for Generate a Draft.
  const capture = (text: CapturedDraftText, target?: TranslationLanguage) => {
    if (
      pausedNow.current ||
      !lifetime.current.mounted ||
      !assistanceEnabled()
    ) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...text,
      id: captureGeneration.current,
      profile,
      target,
    };
    captureNow.current = next;
    setCaptured(next);
    setDropped(undefined);
  };
  const rewrite = (tool: TextTool) => {
    const at = selectionNow.current;
    if (canRewrite(authored.current.body, at)) {
      capture(captureDraftText(tool, authored.current, at));
    }
  };
  const block = (kind: BlockKind) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const result = setBlockKind(textOf(latest.body), at, kind);
    change({ ...latest, body: withText(latest.body, result.document) });
    selectionNow.current = result.selection ?? at;
    place(result.selection);
  };
  const indent = (direction: IndentDirection) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const result = indentList(textOf(latest.body), at, direction);
    if (result.document === textOf(latest.body)) {
      return;
    }
    change({ ...latest, body: withText(latest.body, result.document) });
    selectionNow.current = result.selection ?? at;
    place(result.selection);
  };
  const editLink = (link: Link, text: string, href?: string) => {
    if (pausedNow.current) {
      return;
    }
    const latest = authored.current;
    const result = setLink(textOf(latest.body), link, { text, href });
    change({ ...latest, body: withText(latest.body, result.document) });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    place(result.selection);
  };
  const insertTemplate = (template: MailTemplate) => {
    if (pausedNow.current) {
      return;
    }
    const latest = authored.current;
    const applied = applyTemplate(
      { ...latest, body: textOf(latest.body) },
      selectionNow.current,
      template,
    );
    change({
      ...latest,
      subject: applied.subject,
      body: withText(latest.body, applied.edit.document),
    });
    placeTyping(undefined);
    selectionNow.current = applied.edit.selection ?? selectionNow.current;
    place(applied.edit.selection);
  };
  // Entries still being typed become recipients as one undoable correction; invalid text stays
  // in its field. Returns the finished Draft.
  const finishEntries = useCallback(() => {
    const latest = authored.current;
    const finished = finishedEntries(latest);
    if (finished !== latest) {
      commitHistory((current) => keepIdentity(record(current, finished)));
      update(finished);
    }
    return finished;
  }, [commitHistory, keepIdentity, update]);
  const [open, setOpen] = useState<'save'>();
  const leaving = useRef<((allowed: boolean) => void) | undefined>(undefined);
  // Whether the last Close opened its question rather than finishing.
  const asked = useRef(false);
  // Whether Close offers to return the Draft to an Inbox window: Quit leaves it in Drafts.
  const offersReturn = useRef(false);
  // Whether Try Again retries a Save Draft that was returning the Draft to an Inbox window, and
  // whether a return is under way, which allows no second one.
  const retryReturn = useRef(false);
  const returnUnderway = useRef(false);
  const answerLeave = useCallback((allowed: boolean) => {
    const answer = leaving.current;
    leaving.current = undefined;
    answer?.(allowed);
  }, []);
  useLayoutEffect(
    () => () => {
      leaving.current?.(false);
    },
    [],
  );
  // Runs one Save, removal of an empty Draft or Expand; `finish` resolves whether the editor may
  // close, which `done` then does in place of closing.
  const finishing = async (
    finish: () => Promise<boolean>,
    done?: () => void,
  ) => {
    setOpen(undefined);
    setClosing('saving');
    pausedNow.current = true;
    setPaused(true);
    let closed = false;
    lifetime.current.finishing += 1;
    try {
      closed = await finish();
    } catch {
      // An unexpected storage rejection keeps the composer open and retryable too.
    }
    if (closed) {
      await closeRecord(authored.current.id);
    }
    pausedNow.current = false;
    finishOperation();
    answerLeave(closed);
    if (!lifetime.current.mounted) {
      if (closed && done === undefined) {
        onClosedAfterRemoval(authored.current.id);
      }
      return closed;
    }
    setPaused(false);
    if (closed) {
      (done ?? onClose)();
    } else {
      setClosing((current) => (current === 'saving' ? 'blocked' : current));
    }
    return closed;
  };
  // Stores this editor's version, then saves it and closes, or runs `done` in place of closing.
  // Invalid recipient text keeps the Draft open.
  const saveDraft = async (done?: () => void) => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return false;
    }
    if (finishEntries().entries !== undefined) {
      setOpen(undefined);
      setClosing('recipients');
      answerLeave(false);
      return false;
    }
    return finishing(storeAndSave, done);
  };
  // A Draft that Send or Discard removed needs no reminder, whichever window set it. `target` reads
  // the Draft `id` for the store, which removes the one read last; a rebinding after that moves the
  // editor to a conflict copy keeping its own reminder. Discard keeps another window's newer
  // content under the same id, which keeps its reminder too. `forget` runs whatever the operation
  // resolved, as a removal stored before a later write failed still removed the Draft. One storage
  // could not remove stays harmless, as it names a Draft that no longer exists.
  const reminderCleanup = () => {
    let { id } = authored.current;
    return {
      target: () => {
        ({ id } = authored.current);
        return id;
      },
      forget: () => {
        const state = store.getSnapshot();
        if (state.kind === 'ready' && draftOf(state, id) === undefined) {
          void sendReminders.cancel(draftProfile, id);
        }
      },
    };
  };
  // Close asks to save changes, including ones a failed Save left unsaved; an empty Draft is
  // removed and an unchanged one closes.
  const close = async () => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return false;
    }
    asked.current = false;
    if (isEmptyDraft(authored.current) && isEmptyDraft(stored.current)) {
      return finishing(async () => {
        const cleanup = reminderCleanup();
        const removed = await store.discard(cleanup.target, {
          onlyIfEmpty: true,
          expected: () => stored.current,
        });
        cleanup.forget();
        return removed;
      });
    }
    // Another window's failed save leaves this editor's untouched Draft alone. A New Message
    // window asks even then, as its Save Draft returns the Draft to its Inbox window.
    if (
      authored.current === stored.current &&
      !unsaved.current &&
      !offersReturn.current
    ) {
      const removal = closeRecord(authored.current.id);
      onClose();
      await removal;
      return true;
    }
    setClosing(undefined);
    setOpen('save');
    asked.current = true;
    return false;
  };
  // Leaving for another destination asks the same question first.
  const navigation = useComposerNavigation();
  // Command-W, the window's close button and Quit ask the same question before closing.
  useCloseGuard(async (quitting) => {
    offersReturn.current = returnTo !== undefined && !quitting;
    const allowed = await navigation.leave();
    offersReturn.current = false;
    return allowed;
  });
  useLayoutEffect(() =>
    navigation.register(async () => {
      if (await close()) {
        return true;
      }
      // Only an open question can still answer; a refused Close leaves at once.
      if (
        !asked.current ||
        lifetime.current.finishing > 0 ||
        !lifetime.current.mounted
      ) {
        return false;
      }
      // oxlint-disable-next-line promise/avoid-new -- Navigation waits for Save, Don’t Save or dismissal.
      return new Promise<boolean>((resolve) => {
        leaving.current = resolve;
      });
    }),
  );
  useEffect(() => {
    if (open !== 'save' && lifetime.current.finishing === 0) {
      answerLeave(false);
    }
  }, [answerLeave, open]);
  // Expand hands the Draft over once this editor's version is saved; a failed save keeps it here.
  const expand = async () => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return;
    }
    await finishing(storeAndSave, () => {
      onExpand?.(authored.current.id);
    });
  };
  // Choosing a person for the @ replaces it with the greeting, or in written text the name, and
  // adds a person not yet on the Draft to To, as one edit.
  const chooseRecipient = (recipient: Recipient) => {
    const latest = authored.current;
    const query = recipientMenu.choosable(
      textOf(latest.body),
      selectionNow.current,
    );
    if (query === undefined) {
      return;
    }
    fromControl();
    const greeting = recipientMenu.greeting(recipient);
    const name = recipientMenu.name(recipient);
    const present = recipientRole(latest, recipient.address) !== undefined;
    const inserted = onlyQueryIn(textOf(latest.body), query) ? greeting : name;
    const result = addBodyRecipient(latest, {
      query,
      recipient,
      greeting,
      name,
    });
    recipientMenu.close();
    change(result.draft);
    placeTyping(undefined);
    caret.current = result.selection.start;
    selectionNow.current = result.selection;
    place(result.selection);
    AccessibilityInfo.announceForAccessibility(
      recipientMenu.added(recipient, present, inserted),
    );
  };
  // Choosing a block for the / sets the caret's block to it and removes the query, as one edit.
  const chooseBlock = (kind?: BlockKind) => {
    const latest = authored.current;
    const choice = slashMenu.choice(
      textOf(latest.body),
      selectionNow.current,
      kind,
    );
    if (choice === undefined) {
      return;
    }
    fromControl();
    slashMenu.close();
    const result = applySlashBlock(
      textOf(latest.body),
      choice.query,
      choice.kind,
    );
    change({ ...latest, body: withText(latest.body, result.document) });
    placeTyping(undefined);
    const at = result.selection ?? {
      start: choice.query.start,
      end: choice.query.start,
    };
    caret.current = at.start;
    selectionNow.current = at;
    place(at);
  };
  const tabsIndent = listTabsOn(
    recipientMenu.choosing,
    slashMenu.choosing,
    blockKindAt(textOf(draft.body), selection.start),
  );
  const keyDown = ({ nativeEvent }: KeyEvent) => {
    deletion.current = undefined;
    if (pausedNow.current) {
      return;
    }
    recipientMenu.keyDown(nativeEvent, chooseRecipient);
    slashMenu.keyDown(nativeEvent, () => {
      chooseBlock();
    });
    if (
      nativeEvent.key === 'Tab' &&
      tabsIndent &&
      !nativeEvent.altKey &&
      !nativeEvent.ctrlKey &&
      !nativeEvent.metaKey
    ) {
      indent(nativeEvent.shiftKey ? 'outdent' : 'indent');
      return;
    }
    if (nativeEvent.key === 'Delete') {
      deletion.current = 'forward';
    } else if (nativeEvent.key === 'Backspace') {
      deletion.current = 'backward';
    }
    if (!nativeEvent.metaKey) {
      return;
    }
    if (nativeEvent.key.toLowerCase() === 'z') {
      travel(nativeEvent.shiftKey ? redo : undo);
      return;
    }
    const mark = (
      { b: 'bold', i: 'italic', u: 'underline' } as const satisfies Record<
        string,
        Mark
      >
    )[nativeEvent.key];
    if (mark !== undefined) {
      format(mark);
    }
  };
  // Saves the Draft as Save does, keeping it open, then stores its reminder at `dueAt`.
  const remind = async (dueAt: number, timeZone: string) => {
    if (
      discarded.current ||
      lifetime.current.finishing > 0 ||
      removingReminder.current
    ) {
      return;
    }
    if (finishEntries().entries !== undefined) {
      setClosing('recipients');
      return;
    }
    setReminderFailed(undefined);
    lifetime.current.finishing += 1;
    let set: SendReminder | undefined = undefined;
    try {
      if (await storeAndSave()) {
        const next = { draft: authored.current.id, dueAt, timeZone };
        if (await sendReminders.remind(draftProfile, next)) {
          set = { ...next, profile: draftProfile };
        }
      }
    } catch {
      // An unexpected storage rejection leaves the reminder as it was, to set again.
    }
    finishOperation();
    if (lifetime.current.mounted) {
      if (set === undefined) {
        setReminderFailed('set');
      } else {
        setReadReminder(set);
      }
    }
  };
  // Waits for no pending Save, Send or reminder change, so the reminder stored is the one shown.
  const removeReminder = async () => {
    if (
      reminder === undefined ||
      lifetime.current.finishing > 0 ||
      removingReminder.current
    ) {
      return;
    }
    setReminderFailed(undefined);
    removingReminder.current = true;
    let removed = false;
    try {
      removed = await sendReminders.cancel(reminder.profile, reminder.draft);
    } catch {
      // An unexpected storage rejection keeps the reminder, to remove again.
    }
    removingReminder.current = false;
    if (lifetime.current.mounted) {
      if (removed) {
        setReadReminder(undefined);
      } else {
        setReminderFailed('remove');
      }
    }
  };
  // Deletes the Draft, as Discard and Don’t Save do; a failed deletion keeps this editor's version.
  const discard = async () => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return;
    }
    setOpen(undefined);
    setClosing('saving');
    discarded.current = true;
    lifetime.current.finishing += 1;
    let removed = false;
    const cleanup = reminderCleanup();
    try {
      removed = await store.discard(cleanup.target, {
        expected: () => stored.current,
      });
    } catch {
      // An unexpected storage rejection leaves the editor retryable too.
    }
    cleanup.forget();
    if (removed) {
      await closeRecord(authored.current.id);
    } else {
      discarded.current = false;
    }
    finishOperation();
    answerLeave(removed);
    if (lifetime.current.mounted) {
      if (removed) {
        onClose();
      } else {
        setClosing('discard-blocked');
      }
    } else if (removed) {
      onClosedAfterRemoval(authored.current.id);
    }
  };
  // Stores and admits the Draft as this editor shows it to the Outbox, then closes; a refusal
  // keeps it open. Send Now gives a `delay` of 0, with no Undo Send Window.
  const send = async (delay?: number) => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return;
    }
    if (finishEntries().entries !== undefined) {
      setClosing(undefined);
      setRefused('entries');
      return;
    }
    const shown = authored.current;
    setRefused(undefined);
    setClosing('saving');
    pausedNow.current = true;
    setPaused(true);
    captureNow.current = undefined;
    setCaptured(undefined);
    setDropped(undefined);
    // Later edits wait: the version shown at Send is the one sent.
    discarded.current = true;
    lifetime.current.finishing += 1;
    let refusal: SendRefusal | undefined = 'storage';
    const cleanup = reminderCleanup();
    try {
      const kept = storeShown();
      refusal = await outbox.send(
        () => ({
          ...shown,
          id: cleanup.target(),
          ...(authored.current.conflict ? { conflict: true as const } : {}),
        }),
        setCheck,
        delay,
      );
      // A refused Send still stored the version shown, unless the store declined it; Close asks
      // only if saving it failed.
      if (refusal !== undefined && (await store.save()) && kept) {
        unsaved.current = false;
        journalNow();
      }
    } catch {
      // An unexpected rejection keeps the Draft open to send again.
    }
    cleanup.forget();
    if (refusal === undefined) {
      await closeRecord(authored.current.id);
    } else {
      pausedNow.current = false;
      discarded.current = false;
    }
    setCheck(undefined);
    finishOperation();
    if (lifetime.current.mounted) {
      if (refusal === undefined) {
        onClose();
      } else {
        setClosing(undefined);
        setRefused(refusal);
        setPaused(false);
      }
    } else if (refusal === undefined) {
      onClosedAfterRemoval(authored.current.id);
    }
  };
  // Save Draft in a New Message window waits for its Inbox window to take the Draft, then saves it
  // and hands it over; a refusal keeps the window open on its question's Cancel.
  const returnDraft = async (prepare: ReturnTo) => {
    if (returnUnderway.current) {
      return;
    }
    returnUnderway.current = true;
    let take: ((id: string) => void) | undefined = undefined;
    try {
      take = await prepare();
    } catch {
      // The Draft stays here, as on Cancel.
    }
    if (take === undefined) {
      returnUnderway.current = false;
      setOpen(undefined);
      return;
    }
    const handOver = take;
    retryReturn.current = !(await saveDraft(() => {
      // A Draft another window removed meanwhile has nothing to hand over.
      const { id } = authored.current;
      const state = store.getSnapshot();
      if (state.kind === 'ready' && draftOf(state, id) !== undefined) {
        handOver(id);
      }
      onClose();
    }));
    returnUnderway.current = false;
  };
  // A returning Draft asks this one to save first.
  useLayoutEffect(() => {
    onOpenDraft?.({
      title: () => clip(authored.current.subject) || t('drafts.newMessage'),
      save: saveDraft,
    });
    return () => {
      onOpenDraft?.(undefined);
    };
  });
  // The question's choices act through this render's Save and Don’t Save.
  const answerSave = useRef<(choice: number) => void>(undefined);
  useLayoutEffect(() => {
    answerSave.current = (choice) => {
      if (choice === 0 && returnTo !== undefined && offersReturn.current) {
        void returnDraft(returnTo);
      } else if (choice === 0) {
        retryReturn.current = false;
        void saveDraft();
      } else if (choice === 1) {
        void discard();
      } else {
        setOpen(undefined);
      }
    };
  });
  // Close asks in a sheet on this editor's window, which closes once the editor stops asking.
  const root = useRef<View>(null);
  useEffect(() => {
    if (open !== 'save') {
      return undefined;
    }
    let current = true;
    const question = askInSheet(
      root.current,
      offersReturn.current
        ? {
            title: t('drafts.return.title'),
            detail: t('drafts.return.detail', {
              title: clip(authored.current.subject) || t('drafts.newMessage'),
            }),
            buttons: [
              t('drafts.saveDraft'),
              t('drafts.discardDraft'),
              t('common.cancel'),
            ],
            symbol: { name: 'square.and.pencil', color: colors.textSecondary },
          }
        : {
            title: t('drafts.saveQuestion'),
            detail: t('drafts.saveQuestionDetail'),
            buttons: [
              t('drafts.saveAction'),
              t('drafts.dontSave'),
              t('common.cancel'),
            ],
          },
    );
    const answer = async () => {
      const choice = await question.answer;
      if (current && lifetime.current.mounted && choice !== null) {
        answerSave.current?.(choice);
      }
    };
    void answer();
    return () => {
      current = false;
      question.retire();
    };
  }, [open, t, colors.textSecondary]);
  const title = clip(draft.subject) || t('drafts.newMessage');
  const titleLabel =
    title.length < draft.subject.length
      ? t('drafts.titleShortened', { title })
      : title;
  const active = typing ?? marksAt(textOf(draft.body), selection);
  const kind = blockKindAt(textOf(draft.body), selection.start);
  const indents = listIndentAt(textOf(draft.body), selection);
  useIndentMenu(bodyID, paused ? noIndents : indents, (direction) => {
    fromControl();
    indent(direction);
  });
  // Discard asks first, from the toolbar and the Command Palette alike.
  const askDiscard = () => {
    if (!pausedNow.current && lifetime.current.finishing === 0) {
      setClosing('discard');
    }
  };
  const actions = (
    <ComposerActions
      disabled={lockedUnless(closing !== 'saving')}
      onDiscard={askDiscard}
    />
  );
  const sender = (
    <SendingMailbox
      draft={draft}
      editable={!paused}
      onChange={(mailbox) => {
        change(withSender(authored.current, mailbox));
      }}
    />
  );
  // Send and Send Now first ask in a sheet, once at a time, to leave out the files that were not added, then
  // removes them as one edit and sends; files that changed meanwhile leave the Draft open to ask
  // again. Closing the editor closes the sheet.
  const leftOutAsked = useRef<ReturnType<typeof askInSheet>>(undefined);
  useLayoutEffect(
    () => () => {
      leftOutAsked.current?.retire();
    },
    [],
  );
  const sendAsking = async (delay?: number) => {
    if (leftOutAsked.current !== undefined) {
      return;
    }
    // The imports running now, since a press can arrive before Send's disabled state commits.
    const latest = authored.current;
    const running = store.getImports();
    if (addingAsset(latest, running) !== undefined) {
      return;
    }
    const question = leftOutQuestion(t, latest, running);
    if (question !== undefined) {
      const files = assetStates(latest);
      const sheet = askInSheet(root.current, {
        title: question.title,
        detail: question.detail,
        buttons: [question.send, question.keepEditing],
        cancel: 1,
      });
      leftOutAsked.current = sheet;
      const choice = await sheet.answer;
      leftOutAsked.current = undefined;
      if (
        choice !== 0 ||
        !lifetime.current.mounted ||
        assetStates(authored.current) !== files
      ) {
        return;
      }
      removeAssets(question.ids);
    }
    await send(delay);
  };
  const sendButton = (
    <SendMenu
      below={renderToolbar !== undefined}
      disabled={closing === 'saving'}
      sendable={blocked === undefined}
      waiting={addingName(draft, imports)}
      reminder={reminder}
      onSend={() => {
        void sendAsking();
      }}
      onSendNow={() => {
        void sendAsking(0);
      }}
      onRemind={(dueAt, timeZone) => {
        void remind(dueAt, timeZone);
      }}
    />
  );
  // Once Cc or Bcc is shown or holds a recipient, both stay shown for the Draft.
  const copiesShown = showsCopies(draft);
  // An edit in Cc or Bcc keeps both shown for the Draft, even once they are empty.
  const changeCopies = (next: Draft, word: boolean, field: string) => {
    change({ ...next, copies: true }, word, field);
  };

  return (
    <View
      ref={root}
      collapsable={false}
      // Files dropped anywhere on the composer are attached.
      draggedTypes={['fileUrl']}
      testID="composer"
      onDrop={({ nativeEvent }) => {
        addFiles(
          transferred(t('drafts.assets.pastedImage'), nativeEvent.dataTransfer),
          false,
        );
      }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      {/* The palette offers each Draft control while it is available, with the same handler. */}
      <RegisterCommands
        offer={() =>
          draftCommands(
            t,
            { id: draft.id, subject: draft.subject },
            {
              send:
                closing === 'saving' || blocked !== undefined
                  ? undefined
                  : () => {
                      void sendAsking();
                    },
              attach: paused
                ? undefined
                : () => {
                    void choose('files', false);
                  },
              copies:
                paused || copiesShown
                  ? undefined
                  : () => {
                      change({ ...authored.current, copies: true });
                    },
              discard: lockedUnless(closing !== 'saving')
                ? undefined
                : askDiscard,
            },
          )
        }
      />
      {renderToolbar === undefined ? (
        <View style={styles.header}>
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
            style={styles.grow}>
            <Text
              numberOfLines={1}
              style={[styles.title, { color: colors.textPrimary }]}>
              {title}
            </Text>
          </View>
          {onExpand === undefined ? null : (
            <ToolbarButton
              disabled={lockedUnless(closing !== 'saving')}
              icon="arrow.up.left.and.arrow.down.right"
              label={t('drafts.expand')}
              onPress={() => {
                void expand();
              }}
            />
          )}
          {actions}
        </View>
      ) : (
        renderToolbar(
          sender,
          <>
            {actions}
            {sendButton}
          </>,
        )
      )}
      <FormatBar
        active={active}
        kind={kind}
        indents={indents}
        disabled={paused}
        onBlock={(next) => {
          fromControl();
          block(next);
        }}
        onIndent={(direction) => {
          fromControl();
          indent(direction);
        }}
        onMark={(mark) => {
          fromControl();
          format(mark);
        }}>
        <LinkEditor
          disabled={paused}
          link={editableLinkAt(textOf(draft.body), selection)}
          onChange={(link, text, href) => {
            fromControl();
            editLink(link, text, href);
          }}
          onShown={(shown, returning) => {
            linking.current = shown;
            // The body's selection stays drawn, inactive, while the editor has focus.
            const { start, end } = selectionNow.current;
            windowHost()?.showComposerSelection(
              bodyID,
              { start, end: shown ? end : start },
              processColor(colors.accentSelectionSubtle),
            );
            if (returning === true) {
              bodyInput.current?.focus();
              setPlaced({ ...selectionNow.current });
            }
          }}
        />
        <View style={[styles.divider, { backgroundColor: colors.separator }]} />
        <ToolbarButton
          disabled={lockedUnless(history.past.length > 0)}
          icon="arrow.uturn.backward"
          label={t('drafts.undo')}
          onPress={() => {
            travel(undo);
          }}
        />
        <ToolbarButton
          disabled={lockedUnless(history.future.length > 0)}
          icon="arrow.uturn.forward"
          label={t('drafts.redo')}
          onPress={() => {
            travel(redo);
          }}
        />
        <View style={styles.grow} />
        <WritingTools
          key={profile}
          draft={draft}
          selection={selection}
          disabled={paused}
          onCapture={(purpose, target) => {
            const at = selectionNow.current;
            if (isTextTool(purpose)) {
              rewrite(purpose);
            } else if (
              purpose === 'reply' ||
              hasTranslatableText(
                selectedText(
                  textOf(authored.current.body),
                  at,
                  translationInputLimit + 1,
                ),
              )
            ) {
              capture(captureDraftText(purpose, authored.current, at), target);
            }
          }}
          onGenerate={(prompt) => {
            capture(
              capturePrompt(authored.current, selectionNow.current, prompt),
            );
          }}
        />
        <View style={[styles.divider, { backgroundColor: colors.separator }]} />
        <ToolbarButton
          disabled={paused}
          icon="paperclip"
          label={t('drafts.assets.attachFilesPanel')}
          onPress={() => {
            void choose('files', false);
          }}
        />
        <ToolbarButton
          disabled={paused}
          icon="photo.on.rectangle"
          label={t('drafts.assets.insertImagePanel')}
          onPress={() => {
            void choose('photos', true);
          }}
        />
        <DraftTemplates
          connection={draft.connection}
          disabled={paused}
          getDraft={getDraft}
          onInsert={(template) => {
            fromControl();
            insertTemplate(template);
          }}
        />
      </FormatBar>
      <ScrollView
        contentContainerStyle={styles.content}
        onLayout={({ nativeEvent }) => {
          slashMenu.placeViewport({ height: nativeEvent.layout.height });
        }}
        onScroll={({ nativeEvent }) => {
          slashMenu.placeViewport({ y: nativeEvent.contentOffset.y });
        }}
        scrollEventThrottle={16}>
        <ComposerNotices
          closing={closing}
          draft={draft}
          refused={refused}
          blocked={blocked}
          onClose={() => {
            if (retryReturn.current && returnTo !== undefined) {
              void returnDraft(returnTo);
            } else {
              void saveDraft();
            }
          }}
          onDiscard={() => {
            void discard();
          }}
          onKeepEditing={() => {
            setClosing(undefined);
          }}
        />
        <DraftReminder
          reminder={reminder}
          failed={reminderFailed}
          disabled={paused}
          onRemind={(dueAt, timeZone) => {
            void remind(dueAt, timeZone);
          }}
          onRemove={() => {
            void removeReminder();
          }}
        />
        {captured === undefined ? null : (
          <View style={styles.review}>
            <CapturedAssistance
              key={captured.id}
              captured={captured}
              assistance={assistance}
              translation={translation}
              onApply={(replacement) => {
                fromControl();
                applyCaptured(replacement);
              }}
              onClose={closeCaptured}
              onPending={(pending) => {
                pendingNow.current = pending ? captured.id : undefined;
              }}
            />
          </View>
        )}
        {dropped === undefined ? null : (
          <View style={styles.review}>
            <DroppedAssistance
              purpose={dropped}
              rewritable={canRewrite(draft.body, selection)}
              onRewrite={() => {
                rewrite(dropped);
              }}
              onClose={() => {
                setDropped(undefined);
              }}
            />
          </View>
        )}
        <TextInput
          accessibilityLabel={t('drafts.body')}
          // As in the frames, the body draws no focus ring, which would cross its menus.
          enableFocusRing={false}
          editable={!paused}
          accessibilityState={{ disabled: paused }}
          // Pasted images go inline at the caret; other pasted files are attached. Text pastes as
          // usual. React Native macOS supports these props but leaves them out of TextInputProps.
          {...({
            onPaste: ({ nativeEvent }) => {
              addFiles(
                transferred(
                  t('drafts.assets.pastedImage'),
                  nativeEvent.dataTransfer,
                ),
                true,
              );
            },
            pastedTypes: ['fileUrl', 'image', 'string'],
          } satisfies TextInputMacOSProps)}
          keyDownEvents={bodyKeys(
            [...recipientMenu.keys, ...slashMenu.keys],
            tabsIndent,
          )}
          multiline
          onBlur={() => {
            recipientMenu.close();
            slashMenu.close();
          }}
          onChangeText={edit}
          onKeyDown={keyDown}
          onLayout={({ nativeEvent }) => {
            recipientMenu.placeBody(nativeEvent.layout);
            slashMenu.placeBody(nativeEvent.layout);
          }}
          onSelectionChange={({ nativeEvent }) => {
            if (linking.current) {
              return;
            }
            const next = nativeEvent.selection;
            // Moving the caret anywhere but past typed text ends marks toggled for typing, and
            // closes Recipient Suggestions.
            if (next.start !== next.end || next.start !== caret.current) {
              placeTyping(undefined);
              commitHistory((current) => ({ ...current, typing: false }));
              recipientMenu.close();
              slashMenu.close();
            }
            caret.current = undefined;
            setPlaced(undefined);
            selectionNow.current = next;
            setSelection(next);
          }}
          placeholder={t('drafts.bodyPlaceholder')}
          placeholderTextColor={colors.textSecondary}
          ref={bodyInput}
          scrollEnabled={false}
          selection={placed}
          style={[styles.body, { color: colors.textPrimary }]}
          // ComposerFormatting.m shows formatting shortcuts and marked typing before this renders.
          testID={bodyID}
          textAlignVertical="top">
          {display.lines.map((line, index) => (
            <Text
              // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
              key={index}
              style={[
                kindStyles[line.kind],
                line.kind === 'quote' ? { color: colors.textSecondary } : null,
                line.align === undefined ? null : { textAlign: line.align },
              ]}>
              {line.marker}
              {line.spans.map((span, at) => (
                <Text
                  // oxlint-disable-next-line react/no-array-index-key -- Spans are positional.
                  key={at}
                  style={[
                    markStyle(span.marks, 'link' in span),
                    formatStyleOf(span, appearance),
                  ]}>
                  {span.text}
                </Text>
              ))}
              {index < display.lines.length - 1 ? '\n' : ''}
            </Text>
          ))}
        </TextInput>
        <BodyRecipientMenu
          shown={recipientMenu.shown}
          onAccept={chooseRecipient}
        />
        <BodySlashMenu
          shown={slashMenu.shown}
          titleOf={slashMenu.titleOf}
          labelOf={slashMenu.labelOf}
          onChoose={chooseBlock}
        />
        {draft.quoted === undefined ? null : (
          <QuotedText quoted={draft.quoted} />
        )}
        <DraftAssets
          check={check}
          draft={draft}
          editable={!paused}
          onCancel={(id) => {
            if (!pausedNow.current) {
              void store.cancelImport(id);
            }
          }}
          onRemove={removeAsset}
          onResize={resizeAsset}
        />
        <View style={styles.fields}>
          <View style={[styles.field, { borderTopColor: colors.separator }]}>
            <Text style={[styles.fieldLabel, { color: colors.textSecondary }]}>
              {`${t('drafts.subject')}:`}
            </Text>
            <TextInput
              accessibilityLabel={t('drafts.subject')}
              editable={!paused}
              accessibilityState={{ disabled: paused }}
              onChangeText={(subject) => {
                const previous = authored.current.subject;
                subjectCaret.current =
                  subjectSelection.current.end +
                  subject.length -
                  previous.length;
                // One character added at the caret continues a typing step until a word ends.
                const added =
                  subjectSelection.current.start ===
                    subjectSelection.current.end &&
                  subject.length === previous.length + 1;
                const typed = subject[subjectSelection.current.start] ?? ' ';
                change(
                  { ...authored.current, subject },
                  added && !/\s/u.test(typed),
                  'subject',
                );
              }}
              onSelectionChange={({ nativeEvent }) => {
                const next = nativeEvent.selection;
                if (
                  next.start !== next.end ||
                  next.start !== subjectCaret.current
                ) {
                  commitHistory((current) => ({ ...current, typing: false }));
                }
                subjectCaret.current = undefined;
                subjectSelection.current = next;
              }}
              placeholder={t('drafts.subject')}
              placeholderTextColor={colors.textSecondary}
              style={[styles.input, { color: colors.textPrimary }]}
              value={draft.subject}
            />
          </View>
          <Recipients
            draft={draft}
            getDraft={getDraft}
            editable={!paused}
            field="to"
            required={blocked === 'recipients'}
            onChange={change}
            onCaretMove={breakTyping}
            trailing={
              copiesShown ? undefined : (
                <Action
                  variant="composer"
                  disabled={paused}
                  accessibilityLabel={t('drafts.showCcBcc')}
                  label={t('drafts.ccBcc')}
                  onPress={() => {
                    change({ ...authored.current, copies: true });
                  }}
                />
              )
            }
          />
          {copiesShown ? (
            <>
              <Recipients
                draft={draft}
                getDraft={getDraft}
                editable={!paused}
                field="cc"
                onChange={changeCopies}
                onCaretMove={breakTyping}
              />
              <Recipients
                draft={draft}
                getDraft={getDraft}
                editable={!paused}
                field="bcc"
                onChange={changeCopies}
                onCaretMove={breakTyping}
              />
            </>
          ) : null}
        </View>
      </ScrollView>
      {renderToolbar === undefined ? (
        <View style={[styles.actions, { borderTopColor: colors.separator }]}>
          {sender}
          <View style={styles.grow} />
          {sendButton}
        </View>
      ) : null}
    </View>
  );
}

// Opens a Draft directly for editing; it has no read-only presentation.
export function Composer({
  id,
  recovered,
  onClose,
  onRebind,
  onExpand,
  renderToolbar,
  returnTo,
  onOpenDraft,
}: {
  readonly id: string;
  // The composer recovery record of Draft `id` to open on instead.
  readonly recovered?: Recovered | undefined;
  readonly onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  readonly onRebind: (id: string) => void;
  readonly onExpand?: ((id: string) => void) | undefined;
  readonly renderToolbar?: Toolbar | undefined;
  readonly returnTo?: ReturnTo | undefined;
  readonly onOpenDraft?: ((draft: OpenDraft | undefined) => void) | undefined;
}) {
  const state = useDrafts();
  const store = useDraftStore();
  const colors = usePalette();
  const { t } = useLocalization();
  const draft = draftOf(state, id);
  // The editor stays mounted when it moves to its own copy, and remounts for another Draft. Once
  // open, it keeps its unsaved version even if the Draft is removed elsewhere, so Save can still
  // keep it as a copy; a change of Product Account retires it.
  const [editor, setEditor] = useState({
    key: id,
    followed: id,
    opened: draft,
  });
  if (editor.followed !== id) {
    setEditor({ key: id, followed: id, opened: draft });
  } else if (state.kind !== 'ready' && editor.opened !== undefined) {
    setEditor({ ...editor, opened: undefined });
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
  // Deleting an empty Draft can retire its editor before Close or Discard settles.
  const shown = useRef<string | undefined>(id);
  useLayoutEffect(() => {
    shown.current = id;
    return () => {
      shown.current = undefined;
    };
  }, [id]);
  const closedAfterRemoval = useCallback(
    (closed: string) => {
      if (shown.current === closed) {
        onClose();
      }
    },
    [onClose],
  );
  const restoring =
    recovered?.version.id === editor.key ? recovered : undefined;
  if (opened !== undefined) {
    return (
      <Editor
        key={editor.key}
        initial={restoring?.base ?? opened}
        opening={restoring?.version ?? opened}
        onClose={onClose}
        onClosedAfterRemoval={closedAfterRemoval}
        onExpand={onExpand}
        onRebind={rebind}
        renderToolbar={renderToolbar}
        returnTo={returnTo}
        onOpenDraft={onOpenDraft}
      />
    );
  }
  const waiting = state.kind === 'loading';
  return (
    <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      {renderToolbar === undefined ? (
        <View style={styles.header}>
          <ToolbarButton
            icon="xmark"
            label={t('drafts.close')}
            onPress={onClose}
          />
        </View>
      ) : (
        renderToolbar(null, null)
      )}
      <View style={styles.alerts}>
        {waiting ? (
          <ActivityIndicator accessibilityLabel={t('drafts.loading')} />
        ) : (
          <Alert
            message={
              state.kind === 'locked'
                ? t('drafts.listLocked')
                : t('drafts.unavailable')
            }>
            {state.kind === 'locked' || state.kind === 'failed' ? (
              <Button
                label={t('common.retry')}
                onPress={() => {
                  void store.load();
                }}
              />
            ) : null}
          </Alert>
        )}
      </View>
    </View>
  );
}

// The evaluation editor composes the same layout around its own body.
export { styles as composerStyles };
