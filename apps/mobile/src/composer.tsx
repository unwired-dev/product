import type { Translate } from '@private-email/localization';
import type {
  CapturedDraftText,
  NativeAssistance,
  SlashTool,
  TextTool,
} from '@private-email/mail-core/assistance';
import type {
  AssetPreview,
  BodyRecipientQuery,
  Draft,
  DraftsState,
  PickedFile,
  PickSource,
  Recipient,
  RecipientField,
  RecipientNotice,
  Recovery,
  SlashCommand,
  SlashInsert,
} from '@private-email/mail-core/drafts';
import type {
  MailTemplate,
  StoredMailTemplate,
} from '@private-email/mail-core/mail-templates';
import type { SendRefusal } from '@private-email/mail-core/outbox';
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
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ComponentProps, ReactNode, Ref, RefObject } from 'react';
import type {
  StyleProp,
  ScrollViewInstance,
  TextInputInstance,
  TextLayoutEvent,
  TextStyle,
  ViewInstance,
  ViewStyle,
} from 'react-native';

import {
  canRewrite,
  canSuggestReply,
  captureDraftText,
  capturePrompt,
  draftReplacement,
  isTextTool,
  sameDraftAssistanceSource,
  slashToolGroups,
  slashTools,
} from '@private-email/mail-core/assistance';
import {
  acceptRecipient,
  addBodyRecipient,
  addingAsset,
  addRecipients,
  applySlashBlock,
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
  draftSummary,
  profileOf,
  recipientRole,
  recipientSuggestions,
  sameContent,
  sendingMailboxes,
  sendingStateOf,
  slashCommands,
  slashInserts,
  slashQuery,
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
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import {
  hasTranslatableText,
  translationInputLimit,
} from '@private-email/mail-core/translation';
import {
  createContext,
  Fragment,
  memo,
  use,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Alert as SystemAlert,
  AppState,
  Image,
  Keyboard,
  NativeEventEmitter,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { KeyboardAvoidingView } from 'react-native-keyboard-controller';
import { SafeAreaView } from 'react-native-screens/experimental';

import type {
  GeneratePromptState,
  IndentDirection,
} from './composer-controls.tsx';

import { Action } from './action.tsx';
import {
  CommandInput,
  InSheet,
  useCloseSheetPalette,
  usePaletteHeader,
} from './command-palette.tsx';
import {
  ComposerActions,
  FormatBar,
  FormatPanel,
  GeneratePrompt,
  kindStyles,
  LinkEditor,
  markStyle,
  OverflowMenu,
  PopUp,
  useGeneratePrompt,
  useLinkEditor,
} from './composer-controls.tsx';
import { useContactAddresses } from './contacts.ts';
import {
  ArrowKeys,
  Notice as Banner,
  Button,
  ContextMenu,
  Glass,
  GlassGroup,
  GlassPanel,
  MenuButton,
  Monogram,
  scaledToolbar,
  SFSymbol,
  SignInNotice,
  ToolbarButton,
} from './design.tsx';
import { DraftAssistance, DroppedAssistance } from './draft-assistance.tsx';
import { native } from './host.ts';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import {
  MailAssistanceProfileContext,
  useMailAssistanceLifetime,
} from './mail-assistance-lifetime.ts';
import { useAllMailboxes, useMailboxList } from './mailbox-state.ts';
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
import { ProgressBar } from './sync-status.tsx';
import {
  textStyles,
  useAppearance,
  useLargeText,
  usePalette,
} from './theme.ts';
import { DraftTranslation, TranslationContext } from './translation.tsx';

// The native split host owns compact presentation, including landscape iPhone and narrow windows.
// A window-filling composer avoids the keyboard below its `top` inset; the regular-width
// overlay is instead raised above the keyboard by its layout.
export const ComposerLayoutContext = createContext<{
  readonly size: 'compact' | 'regular';
  readonly avoidKeyboard: boolean;
  readonly top: number;
}>({ size: 'compact', avoidKeyboard: true, top: 0 });

// Whether the composer is open: a system sheet sliding away still shows the composer it closed,
// which no longer guards leaving.
export const ComposerPresentedContext = createContext(true);

// The docked iPad reply's title: the kind of response it is.
const responseTitles = {
  reply: 'message.reply',
  replyAll: 'message.replyAll',
  forward: 'message.forward',
} as const;

// The composer's file controls: the system pickers, and images on the pasteboard placed inline.
// Native code reads the chosen files.
export const assetPickers = [
  ['drafts.assets.attachFile', 'files', false, 'paperclip'],
  ['drafts.assets.attachPhoto', 'photos', false, 'photo'],
  ['drafts.assets.insertImage', 'photos', true, 'photo.on.rectangle'],
  ['drafts.assets.pasteImage', 'paste', true, 'doc.on.doc'],
] as const;

// iPhone's Add files and Writing tools menus end at the controls row's trailing edge and bottom,
// as the compose frames draw them.
const iphone = Platform.OS === 'ios' && !Platform.isPad;

// The space the floating pill takes at the bottom of the iPhone editor.
const pillReserve = 44 + 2 * spacing.xs + 2 * spacing.s;
// On iPhone the body and fields sit 20pt in, with an 80pt right-aligned label column.
const inset = 20;
const fieldInset = 16;
const fieldLabelWidth = 80;
const padInset = 32 * ipadListScale;
export const padFieldInset = spacing.xxl * ipadListScale;
const padBodyMenuWidth = 320 * ipadListScale;
const padLabelWidth = 64 * ipadListScale;
// Compact 44pt and regular 41.4pt field rows reach 44pt targets. Each includes its row's rule:
// iPhone's 1pt and iPad's 1.15pt, the Mac recipe's point at 1.15×.
const compactRule = 1;
const compactFieldHeight = 44 - compactRule;
const padRule = ipadListScale;
const padFieldHeight = 36 * ipadListScale - padRule;
const titledSendHeight = 28 * ipadListScale;
// iPhone's targets reach up over their own row's rule, so none reaches into the next row.
export const fieldSlop = {
  compact: { top: compactRule, bottom: 0 },
  regular: (44 - padFieldHeight) / 2,
} as const;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  grow: { flex: 1 },
  // The same 44-point target as the format bar's icon buttons.
  menuControl: { minWidth: 44, minHeight: 44, alignItems: 'center' },
  // iPhone's controls float at the trailing edge above the keyboard; the editor scrolls its last
  // field above their 44pt buttons and insets.
  pill: {
    position: 'absolute',
    right: spacing.l,
    bottom: 10,
    flexDirection: 'row',
    gap: 10,
  },
  pillGroup: { borderRadius: 26 },
  // The Format pill is 104pt wide in the frame: its two 44pt buttons sit 8pt from each end.
  formatPill: { paddingHorizontal: spacing.s },
  pillInset: { paddingBottom: pillReserve },
  // Up to the pill's space between the Draft and the fields, so the last attachment clears it.
  pillClear: { flexGrow: 1000, maxHeight: pillReserve },
  // The iPhone body, or the space after its quoted text, takes the rest of the visible area.
  filling: { flexGrow: 1 },
  fixed: { flexGrow: 0 },
  // Open menus stack header over From over the format bar, whose layout-only rows Fabric
  // flattens into this column, so each menu opens over the rows that follow it.
  header: {
    zIndex: 3,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingVertical: 6,
    paddingHorizontal: spacing.l,
  },
  title: { ...textStyles.headline, textAlign: 'center' },
  titleTarget: { minHeight: 44, justifyContent: 'center' },
  leadingTitle: { textAlign: 'left' },
  // iPad's New Message header is 63pt with its controls centred 33.8pt down; a docked reply's is
  // 46pt. Both title in the list's semibold type.
  cardHeader: { paddingTop: 33.8 - 22, paddingBottom: 63 - 33.8 - 22 },
  dockedHeader: { paddingVertical: 1 },
  // The iPhone sheet's frame keeps 11pt above its header for the grabber, and centres the title
  // across the sheet: it is offset by Actions and its gap, which Send's side holds beyond Close's.
  sheetHeader: { paddingTop: 6 + 11 },
  sheetTitle: { paddingLeft: 44 + spacing.s },
  // From's 34pt pill sits in a 44pt touch target; the frame's From row is the pill and 4pt below it.
  sheetFromRow: { marginVertical: -5 },
  regularTitle: { ...typography.ipadList.body, fontWeight: '600' },
  // The docked reply's From and Send beneath its fields, as in the iPad Compose Inline frame: their
  // 32.2pt visuals 10.35pt below the fields and 13.8pt above the bottom, in line with the fields.
  replyFooter: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: 9 * ipadListScale - (44 - titledSendHeight) / 2,
    paddingBottom: 12 * ipadListScale - (44 - titledSendHeight) / 2,
    paddingHorizontal: padFieldInset,
    borderTopWidth: padRule,
  },
  // The iPad frame's reason above the docked reply's From and Send: 7pt above and 5pt below at 1×.
  blockedReason: {
    ...typography.ipadList.subheadline,
    textAlign: 'right',
    paddingTop: 7 * ipadListScale,
    paddingBottom: 5 * ipadListScale,
    paddingHorizontal: padFieldInset,
  },
  sendDisabled: { opacity: 0.5 },
  // Under From, in line with it: 4pt above and 8pt below on iPhone, as its frame draws it.
  phoneSignIn: {
    marginHorizontal: inset,
    marginTop: spacing.xs,
    marginBottom: spacing.s,
  },
  cardSignIn: { marginHorizontal: padFieldInset, marginBottom: spacing.s },
  dockedSignIn: {
    marginHorizontal: padFieldInset,
    marginBottom: 12 * ipadListScale,
  },
  // iPad's Send is the Mac button at 1.15×: 65.6×32.2pt with 6.9pt corners, within its 44pt target.
  sendTitled: {
    minHeight: titledSendHeight,
    minWidth: 57 * ipadListScale,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.m * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  sendLabel: { ...typography.ipadList.body, fontWeight: '600' },
  circle: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 22,
  },
  closeQuestion: { ...StyleSheet.absoluteFill, zIndex: 4 },
  closeQuestionPlace: { position: 'absolute', width: 220 },
  closeQuestionPanel: { padding: spacing.m, gap: spacing.s },
  closeChoice: {
    minHeight: 48,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.l,
    borderRadius: 24,
  },
  closeChoiceText: { ...textStyles.body },
  fromRow: {
    zIndex: 2,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: inset,
    paddingBottom: spacing.xs,
  },
  alerts: {
    gap: spacing.s,
    paddingHorizontal: fieldInset,
    paddingBottom: spacing.s,
  },
  // The format bar's separators: 18.4pt tall, 4.6pt from the glyph boxes beside them.
  divider: {
    width: padRule,
    height: 16 * ipadListScale,
  },
  content: { paddingBottom: spacing.s },
  // A docked reply's text starts 13.8pt beneath its format bar and its fields meet its footer.
  dockedContent: { paddingBottom: 0 },
  dockedBody: { paddingTop: spacing.m * ipadListScale },
  dockedFormatBar: { height: 36 * ipadListScale },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  notice: { ...textStyles.subheadline },
  // Why Send waits for a file still importing, above the body.
  waiting: { ...textStyles.footnote },
  review: { paddingHorizontal: fieldInset, paddingTop: spacing.m },
  body: {
    ...textStyles.body,
    minHeight: 160,
    paddingHorizontal: inset,
    paddingTop: spacing.m,
    paddingBottom: spacing.m,
  },
  quoted: { marginHorizontal: inset, marginBottom: spacing.m, gap: spacing.xs },
  quotedText: {
    ...textStyles.subheadline,
    paddingLeft: spacing.m,
    borderLeftWidth: 2,
  },
  assets: { paddingHorizontal: inset, paddingBottom: 10, gap: spacing.s },
  assetChips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  assetChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    maxWidth: '100%',
    paddingLeft: spacing.m,
    paddingRight: 6,
    paddingVertical: 6,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  assetMeta: { flexShrink: 1 },
  assetName: { ...textStyles.subheadlineEmphasized },
  // R1 and R3 of #2092 draw the warning glyph inline at the status's size, a space before it.
  assetStatusRow: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  // R2 of #2092 spaces the name, status and bar 2pt apart.
  assetStatusImporting: { marginTop: 2 },
  assetStatus: { ...textStyles.footnote, flexShrink: 1 },
  thumbnail: { width: 32, height: 32, borderRadius: radius.control },
  fields: { paddingHorizontal: fieldInset },
  field: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
    gap: spacing.s,
    minHeight: 44,
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
  // Centred on the first 44pt line, so a wrapped recipient row keeps its label at the top.
  fieldLabel: {
    ...textStyles.body,
    width: fieldLabelWidth,
    paddingVertical: 11,
    textAlign: 'right',
  },
  fieldNotice: {
    paddingLeft: fieldLabelWidth + spacing.s,
    paddingBottom: spacing.xs,
  },
  // At the accessibility text sizes a label takes its own line above the value, which then has the
  // row's full width, with Cc/Bcc beneath it, as side-by-side text stacks elsewhere.
  stackedLabel: { width: '100%', textAlign: 'left' },
  stackedEntries: { flexBasis: '100%' },
  stackedNotice: { paddingLeft: 0 },
  stackedTrailing: { height: 'auto' },
  // The entry and its drawn placeholder; the minimum width wraps the entry below the recipients.
  // A row, so the input's flex fills the width and its height stays one line (#2736).
  entry: { flex: 1, flexDirection: 'row', minWidth: 140 },
  placeholder: {
    ...StyleSheet.absoluteFill,
    justifyContent: 'center',
  },
  input: {
    ...textStyles.body,
    flex: 1,
    minWidth: 140,
    minHeight: 44,
    paddingVertical: 0,
  },
  // Recipient Suggestions open upward over the message, as the fields sit above the keyboard.
  suggestions: {
    position: 'absolute',
    bottom: '100%',
    left: 0,
    right: 0,
    padding: 6,
  },
  suggestionSection: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  suggestion: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
    paddingHorizontal: spacing.s + 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  suggestionText: { flex: 1 },
  suggestionName: { ...textStyles.body },
  suggestionAddress: { ...textStyles.footnote },
  suggestionEmpty: {
    ...textStyles.body,
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  suggestionNote: {
    ...textStyles.footnote,
    paddingHorizontal: spacing.s + 2,
    paddingVertical: spacing.xs,
  },
  // The Body Recipient Shortcut's suggestions open under the query, over what follows. On iPhone
  // they span the sheet as a system menu, each row led by a monogram.
  bodySuggestions: {
    position: 'absolute',
    zIndex: 1,
    left: 0,
    right: 0,
    pointerEvents: 'box-none',
  },
  bodyCopy: {
    minHeight: 0,
    paddingBottom: 0,
    opacity: 0,
    pointerEvents: 'none',
  },
  // A copy measured for where the query's @ sits, kept out of the layout.
  bodyProbe: { position: 'absolute', left: 0, right: 0, top: 0 },
  // The body grows to fill the editor through the view taking its arrow keys.
  bodyKeys: { flexGrow: 1 },
  // The body's top padding goes once, before the lines over the query's.
  bodyCopyLine: { paddingTop: 0 },
  // Over a query too low in the editor for them to fit under it.
  bodySuggestionsAbove: {
    position: 'absolute',
    left: 0,
    right: 0,
    paddingBottom: spacing.xs,
  },
  monogramSection: {
    fontWeight: '400',
    paddingLeft: 17,
    paddingTop: 6,
    paddingBottom: spacing.xs,
  },
  monogramSuggestion: {
    gap: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
    borderRadius: radius.touchMenuItem,
  },
  monogramAddress: { ...textStyles.subheadline },
  // The Slash Command Menu, 320pt from the caret's line, its rows led by a 25pt icon slot.
  slashMenu: {
    marginLeft: inset - spacing.s,
    width: 320,
    maxWidth: '100%',
    marginTop: spacing.xs,
    padding: spacing.s,
  },
  slashRow: {
    gap: 10,
    paddingHorizontal: 17,
    borderRadius: radius.touchMenuItem,
  },
  slashIcon: { width: 25, alignItems: 'flex-start' },
  // The 1pt line between the menu's sections, 8pt in, centred in 11pt.
  slashSeparator: { height: 1, marginVertical: 5, marginHorizontal: 8 },
  slashGlyph: { ...textStyles.caption1, fontWeight: '700' },
  // The whole 44pt row height removes the recipient; its chip stays compact.
  token: { minHeight: 44, justifyContent: 'center' },
  tokenFill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.s,
    paddingVertical: 4,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  tokenText: { ...textStyles.subheadline },
  section: {
    ...textStyles.footnote,
    fontWeight: '600',
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
  badge: { ...textStyles.footnote, fontWeight: '600' },
  rowSubject: { ...textStyles.subheadline, flex: 1 },
  rowDetail: { ...textStyles.footnote },
  footer: { ...textStyles.footnote, paddingHorizontal: spacing.xl },
});

// Each layout's additions to the shared styles. On both, the body grows to push its attachments
// and fields to the bottom. iPad scales the Mac recipe by 1.15: the body 36.8pt in, in the Mac
// composer's 15/22 at that scale, rounded to 17/25; the fields 27.6pt in, 41.4pt rows of list type with a 73.6pt
// label column.
export const layoutStyles = {
  // iPhone's fields are 44pt rows of Body text beneath 1pt rules, 10pt from their labels, with
  // Body recipient tokens. An entry stays beside recipients while 60pt fit.
  compact: StyleSheet.create({
    content: { flexGrow: 1 },
    body: { flexGrow: 1 },
    quoted: {},
    assets: {},
    fields: {},
    field: {
      gap: 10,
      minHeight: 44,
      paddingVertical: 0,
      borderTopWidth: compactRule,
    },
    fieldLabel: {
      ...textStyles.body,
      paddingVertical: (compactFieldHeight - textStyles.body.lineHeight) / 2,
    },
    fieldNotice: { paddingLeft: fieldLabelWidth + 10 },
    suggestions: {},
    suggestionSection: {},
    suggestion: {},
    suggestionName: {},
    suggestionAddress: {},
    bodySuggestions: {
      marginHorizontal: inset - spacing.xs,
      marginTop: spacing.xs,
      padding: spacing.s,
    },
    entry: { minWidth: 60 },
    input: {
      ...textStyles.body,
      minHeight: compactFieldHeight,
      minWidth: 60,
    },
    placeholder: textStyles.body,
    token: { minHeight: compactFieldHeight },
    // A short name's token still makes a 44pt wide target.
    tokenFill: {
      minWidth: 44,
      justifyContent: 'center',
      paddingHorizontal: 10,
      paddingVertical: 3,
    },
    tokenText: textStyles.body,
    trailing: { height: compactFieldHeight, justifyContent: 'center' },
    assetChip: { gap: 10 },
    // R2 of #2092: the import's bar under its status, and the reason Send waits at the body's
    // inset, 8pt below From.
    assetProgress: { width: 144, marginTop: 2 },
    waiting: { marginHorizontal: inset - fieldInset, marginTop: 4 },
  }),
  // The New Message card's text starts 23pt down and its fields end 6.9pt above its edge.
  regular: StyleSheet.create({
    content: { flexGrow: 1, paddingBottom: 6 * ipadListScale },
    body: {
      flexGrow: 1,
      paddingTop: 20 * ipadListScale,
      paddingHorizontal: padInset,
      fontSize: 17,
      lineHeight: 25,
    },
    quoted: { marginHorizontal: padInset },
    assets: { paddingHorizontal: padFieldInset },
    fields: { paddingHorizontal: padFieldInset },
    field: {
      gap: spacing.s * ipadListScale,
      minHeight: 36 * ipadListScale,
      paddingVertical: 0,
      borderTopWidth: padRule,
    },
    fieldLabel: {
      ...typography.ipadList.body,
      width: padLabelWidth,
      paddingVertical:
        (padFieldHeight - typography.ipadList.body.lineHeight) / 2,
    },
    fieldNotice: { paddingLeft: padLabelWidth + spacing.s * ipadListScale },
    entry: {},
    input: { ...typography.ipadList.body, minHeight: padFieldHeight },
    placeholder: typography.ipadList.body,
    // The Mac's suggestions at 1.15, beside the label column, narrowing with a docked reply.
    suggestions: {
      left: padLabelWidth + spacing.s * ipadListScale,
      maxWidth: 340 * ipadListScale,
      padding: 6 * ipadListScale,
    },
    suggestionSection: {
      ...typography.ipadList.subheadline,
      fontWeight: '600',
      paddingHorizontal: 10 * ipadListScale,
      paddingVertical: spacing.xs * ipadListScale,
    },
    suggestion: {
      minHeight: 40 * ipadListScale,
      paddingHorizontal: 10 * ipadListScale,
    },
    suggestionName: { ...typography.ipadList.body },
    suggestionAddress: { ...typography.ipadList.subheadline },
    // The Mac's body suggestions at 1.15, their rows aligned with the text.
    bodySuggestions: {
      marginLeft: padFieldInset,
      width: padBodyMenuWidth,
      marginTop: 9 * ipadListScale,
      padding: 6 * ipadListScale,
    },
    token: { minHeight: padFieldHeight },
    tokenFill: {},
    tokenText: {},
    // Cc/Bcc's 44pt target overhangs the 41.4pt row rather than growing it.
    trailing: { height: padFieldHeight, justifyContent: 'center' },
    assetChip: {},
    // R2 of #2092: the bar and the reason Send waits, at the body's inset 14pt below the format bar,
    // in 16pt lines with the body's own inset below it.
    assetProgress: { width: 138, marginTop: -1 },
    waiting: {
      marginHorizontal: padInset - fieldInset,
      marginTop: 12,
      marginBottom: -spacing.s,
      lineHeight: 16,
    },
  }),
};

// What keeps the composer from closing, or asks before it does.
export type Closing =
  | 'saving'
  | 'blocked'
  | 'discard-blocked'
  | 'discard'
  | 'recipients';

// A quiet banner beside the content it explains, with its actions under the message. VoiceOver
// announces an action's outcome when it appears; iOS ignores live regions.
function Alert({
  message,
  actions,
  outcome = false,
  children,
}: {
  readonly message: string;
  readonly actions?: ComponentProps<typeof Banner>['messageActions'];
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
      messageRole="alert"
      messageActions={actions}>
      {children}
    </Banner>
  );
}

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
  const { t } = useLocalization();
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
      onPress={() => {
        void onOpen(draft.id);
      }}
      style={({ pressed }) => [
        styles.row,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.surfaceContent,
          borderColor: 'transparent',
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
      // Native Back can hide the secondary column without changing its selected Draft.
      // Selecting it again reveals that same editor and must not try to leave it.
      if (id === composing || (await leave(id))) {
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
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.textPrimary }]}>
            {state.kind === 'locked'
              ? t('drafts.listLocked')
              : t('drafts.listFailed')}
          </Text>
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
        // Shown wherever the person returns to the Inbox.
        <View style={[styles.bar, { paddingHorizontal: spacing.xl }]}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.textPrimary }]}>
            {t(`drafts.unsaved.${state.save}`)}
          </Text>
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
    <Text
      accessibilityRole="header"
      style={[styles.section, { color: colors.textSecondary }]}>
      {t('drafts.heading')}
    </Text>
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
    <PopUp
      quiet
      accessibilityLabel={label}
      disabled={!editable}
      label={from}
      prefix={t('drafts.fromLabel')}
      selected={state === 'available'}
      items={senders.map((mailbox) => {
        const address = clip(mailbox.address);
        return {
          key: mailbox.id,
          title: address,
          symbol: '',
          accessibilityLabel: t(
            address.length < mailbox.address.length
              ? 'drafts.sendFromShortened'
              : 'drafts.sendFrom',
            { address },
          ),
          checked: state === 'available' && mailbox.id === draft.connection,
          run: () => {
            onChange(mailbox);
          },
        };
      })}
    />
  );
}

// Why the sending mailbox cannot send now, if it cannot.
const sendingMessage = (
  t: Translate,
  draft: Draft,
  mailboxes: readonly MailboxConnection[],
) => {
  const state = sendingStateOf(draft, mailboxes);
  if (state === 'authorization') {
    const microsoft =
      mailboxes.find(({ id }) => id === draft.connection)?.provider ===
      'microsoft-graph';
    return t(
      microsoft ? 'drafts.sending.signIn_microsoft' : 'drafts.sending.signIn',
    );
  }
  return state === 'available' ? undefined : t(`drafts.sending.${state}`);
};

// Why the sending mailbox cannot send, among the notices; `signIn` includes the Authorization
// Needed banner, which the editor otherwise shows under From.
function SendingNotice({
  draft,
  signIn,
}: {
  readonly draft: Draft;
  readonly signIn: boolean;
}) {
  const account = use(AccountContext);
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const message = sendingMessage(t, draft, mailboxes);
  if (message === undefined) {
    return null;
  }
  if (sendingStateOf(draft, mailboxes) === 'authorization') {
    return signIn ? <SignInBanner draft={draft} /> : null;
  }
  return <Alert message={message} />;
}

// A mailbox that needs sign-in again offers Sign In… in the Authorization Needed banner, as the
// iPhone frame draws it. `style` places it.
function SignInBanner({
  draft,
  style,
}: {
  readonly draft: Draft;
  readonly style?: StyleProp<ViewStyle>;
}) {
  const account = use(AccountContext);
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const message = sendingMessage(t, draft, mailboxes);
  if (
    message === undefined ||
    sendingStateOf(draft, mailboxes) !== 'authorization'
  ) {
    return null;
  }
  return (
    <SignInNotice
      message={message}
      action={t('drafts.sending.signInAction')}
      onPress={() => {
        void account?.authorizeMailbox(draft.connection);
      }}
      style={style}
    />
  );
}

function FieldLabel({ children }: { readonly children: string }) {
  const colors = usePalette();
  const { size } = use(ComposerLayoutContext);
  const large = useLargeText();
  return (
    <Text
      style={[
        styles.fieldLabel,
        layoutStyles[size].fieldLabel,
        large && styles.stackedLabel,
        { color: colors.textSecondary },
      ]}>
      {children}
    </Text>
  );
}

// Recipient Suggestions in a glass menu, Recent then Contacts, with the active one highlighted;
// `empty` shows when none matches, and `note` beneath them. The iPhone body's menu leads each row
// with a monogram, as its frames draw it.
function SuggestionMenu({
  sections,
  active,
  onAccept,
  origin,
  style,
  empty,
  note,
  roleOf,
  monograms = false,
  scroll,
}: {
  readonly sections: Readonly<{
    recent: readonly Recipient[];
    contacts: readonly Recipient[];
  }>;
  readonly active: Recipient | undefined;
  readonly onAccept: (recipient: Recipient) => void;
  readonly origin: string;
  readonly style: StyleProp<ViewStyle>;
  readonly empty?: string | undefined;
  readonly note?: string | undefined;
  // The field a person already on the Draft is in, shown at the row's trailing edge.
  readonly roleOf?: ((recipient: Recipient) => string | undefined) | undefined;
  readonly monograms?: boolean;
  // Rows taller than `maxHeight` scroll inside the menu; `onContentHeight` hears their full height.
  // They start at the top for each `query`.
  readonly scroll?: Readonly<{
    query: string;
    maxHeight: number | undefined;
    onContentHeight: (height: number) => void;
  }>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { size } = use(ComposerLayoutContext);
  const sized = layoutStyles[size];
  const none = sections.recent.length + sections.contacts.length === 0;
  const Rows = scroll === undefined ? View : ScrollView;
  // Where each row of the scrolling menu ends, by query and address, so it scrolls as far as the
  // highlighted row needs to show, as the highlight moves or its row lays out.
  const list = useRef<ScrollViewInstance>(null);
  const rowEnds = useRef(new Map<string, number>());
  const maxHeight = scroll?.maxHeight;
  const rowOf = (address: string) => `${scroll?.query}\n${address}`;
  const reveal = useCallback(
    (end: number | undefined) => {
      if (end !== undefined && maxHeight !== undefined) {
        list.current?.scrollTo({
          y: Math.max(end - maxHeight, 0),
          animated: false,
        });
      }
    },
    [maxHeight],
  );
  const activeRow = active === undefined ? undefined : rowOf(active.address);
  useEffect(() => {
    if (activeRow !== undefined) {
      reveal(rowEnds.current.get(activeRow));
    }
  }, [activeRow, reveal]);
  return (
    <GlassPanel
      open
      origin={origin}
      {...(monograms ? { cornerRadius: radius.touchMenu } : {})}
      style={style}>
      <Rows
        // A new query starts the scrolling menu at the top.
        key={scroll?.query}
        accessibilityLabel={t('drafts.suggestions.title')}
        {...(scroll === undefined
          ? {}
          : {
              keyboardShouldPersistTaps: 'always',
              style: { maxHeight: scroll.maxHeight },
              ref: list,
              onContentSizeChange: (_width: number, height: number) => {
                scroll.onContentHeight(height);
              },
            })}>
        {none && empty !== undefined ? (
          <Text
            style={[
              styles.suggestionEmpty,
              sized.suggestionName,
              { color: colors.textSecondary },
            ]}>
            {empty}
          </Text>
        ) : null}
        {(['recent', 'contacts'] as const).map((section) =>
          sections[section].length === 0 ? null : (
            <Fragment key={section}>
              <Text
                style={[
                  styles.suggestionSection,
                  sized.suggestionSection,
                  monograms && styles.monogramSection,
                  { color: colors.textSecondary },
                ]}>
                {t(`drafts.suggestions.${section}`)}
              </Text>
              {sections[section].map((recipient) => {
                // Return chooses the active suggestion, so it shows highlighted.
                const chosen = recipient === active;
                const filled = chosen && !monograms;
                const primary = filled
                  ? colors.accentOnFill
                  : colors.textPrimary;
                const secondary = filled
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
                let highlight = null;
                if (chosen) {
                  highlight = {
                    backgroundColor: monograms
                      ? colors.fillQuiet
                      : colors.accentFill,
                  };
                }
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
                    {...(scroll === undefined
                      ? {}
                      : {
                          onLayout: ({ nativeEvent: { layout } }) => {
                            const end = layout.y + layout.height;
                            rowEnds.current.set(rowOf(recipient.address), end);
                            if (chosen) {
                              reveal(end);
                            }
                          },
                        })}
                    onPress={() => {
                      onAccept(recipient);
                    }}
                    style={({ pressed }) => [
                      styles.suggestion,
                      sized.suggestion,
                      monograms && styles.monogramSuggestion,
                      pressed
                        ? { backgroundColor: colors.accentSelectionSubtle }
                        : null,
                      highlight,
                    ]}>
                    {monograms ? (
                      <Monogram name={recipient.name ?? recipient.address} />
                    ) : (
                      <SFSymbol
                        name="person.fill"
                        color={secondary}
                        size={size === 'regular' ? 11 * ipadListScale : 13}
                      />
                    )}
                    <View style={styles.suggestionText}>
                      <Text
                        numberOfLines={1}
                        style={[
                          styles.suggestionName,
                          sized.suggestionName,
                          { color: primary },
                        ]}>
                        {recipient.name ?? recipient.address}
                      </Text>
                      {recipient.name === undefined ? null : (
                        <Text
                          numberOfLines={1}
                          style={[
                            styles.suggestionAddress,
                            sized.suggestionAddress,
                            monograms && styles.monogramAddress,
                            { color: secondary },
                          ]}>
                          {recipient.address}
                        </Text>
                      )}
                    </View>
                    {role === undefined ? null : (
                      <Text
                        style={[
                          monograms
                            ? styles.monogramAddress
                            : [styles.suggestionName, sized.suggestionName],
                          { color: secondary },
                        ]}>
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
          <Text
            style={[
              styles.suggestionNote,
              sized.suggestionAddress,
              { color: colors.textSecondary },
            ]}>
            {note}
          </Text>
        )}
      </Rows>
    </GlassPanel>
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

export function Recipients({
  draft,
  getDraft,
  field,
  onChange,
  onCaretMove,
  editable,
  trailing,
  required = false,
  revealed,
  ref,
  block,
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly field: RecipientField;
  // The field's entry, which Send focuses when it waits for this field.
  readonly ref?: Ref<TextInputInstance>;
  // The field with its reason, which a blocked Send scrolls into view.
  readonly block?: Ref<ViewInstance>;
  readonly editable: boolean;
  // Whether Send waits for a recipient, which this field then asks for.
  readonly required?: boolean;
  // The entry a blocked Send was pressed over, which says why while it is still being typed.
  readonly revealed?: string | undefined;
  // A typing step when only the unfinished entry changed.
  readonly onChange: (draft: Draft, typing: boolean, field: string) => void;
  readonly onCaretMove: () => void;
  // A control at the row's trailing edge, such as the one revealing Cc and Bcc.
  readonly trailing?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { size } = use(ComposerLayoutContext);
  const sized = layoutStyles[size];
  const large = useLargeText();
  const [notice, setNotice] = useState<RecipientNotice>();
  const selection = useRef<Selection>({ start: 0, end: 0 });
  const caret = useRef<number | undefined>(undefined);
  // Recipient Suggestions show while the field is being typed in.
  const [entering, setEntering] = useState(false);
  const account = use(AccountContext);
  const held = useAllMailboxes();
  const contacts = useContactAddresses(entering && editable).addresses;
  const name = t(`drafts.fields.${field}`);
  // Recent correspondents of the Draft's Mail Profile, then Apple Contacts not already suggested.
  const suggestions = useMemo(() => {
    if (!entering || !editable) {
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
    return {
      recent,
      contacts: recipientSuggestions(draft, field, {
        correspondents: contacts,
        excluded: [...excluded, ...recent.map(({ address }) => address)],
      }),
    };
  }, [entering, editable, draft, field, account, held, contacts]);
  const [first] = [...suggestions.recent, ...suggestions.contacts];
  // Text Send would leave in the field, once it is no longer typed in, is not an address it can use.
  const entry = addRecipients(draft, {
    field,
    text: entryOf(draft, field),
    all: true,
  }).text;
  const incomplete =
    (!entering || entryOf(draft, field) === revealed) && entry !== '';
  const requiredReason = required ? t('drafts.recipient.required') : undefined;
  const reason = incomplete
    ? t('drafts.recipient.incomplete', { address: entry })
    : requiredReason;
  const shownNotice =
    reason ??
    (notice === undefined ? undefined : t(`drafts.recipient.${notice}`));
  // Leaving the field says once why Send waits, as iOS ignores live regions.
  useEffect(() => {
    if (incomplete) {
      AccessibilityInfo.announceForAccessibility(
        t('drafts.recipient.incomplete', { address: entry }),
      );
    }
  }, [incomplete, entry, t]);
  const accept = (recipient: Recipient) => {
    onChange(acceptRecipient(getDraft(), field, recipient), false, field);
    setNotice(undefined);
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
  return (
    <View ref={block}>
      {first === undefined ? null : (
        <SuggestionMenu
          sections={suggestions}
          active={first}
          onAccept={accept}
          origin="bottom left"
          style={[styles.suggestions, sized.suggestions]}
        />
      )}
      <View
        style={[
          styles.field,
          sized.field,
          { borderTopColor: colors.separator },
        ]}>
        <FieldLabel>{`${name}:`}</FieldLabel>
        <View style={[styles.entries, large && styles.stackedEntries]}>
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
              focusable
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
              hitSlop={fieldSlop[size]}
              style={[styles.token, sized.token]}>
              {({ pressed }) => (
                <View
                  style={[
                    styles.tokenFill,
                    sized.tokenFill,
                    {
                      backgroundColor: pressed
                        ? colors.accentSelectionSubtle
                        : colors.fillQuiet,
                      opacity: editable ? 1 : 0.4,
                    },
                  ]}>
                  <Text
                    style={[
                      styles.tokenText,
                      sized.tokenText,
                      { color: colors.textPrimary },
                    ]}>
                    {recipient.name ?? recipient.address}
                  </Text>
                  {/* iPhone's tokens are their name alone, as its frames draw them. */}
                  {size === 'compact' ? null : (
                    <SFSymbol
                      name="xmark"
                      size={10}
                      color={colors.textSecondary}
                    />
                  )}
                </View>
              )}
            </Pressable>
          ))}
          <View style={[styles.entry, sized.entry]}>
            <TextInput
              ref={ref}
              accessibilityLabel={name}
              accessibilityHint={incomplete ? reason : undefined}
              editable={editable}
              accessibilityState={{ disabled: !editable }}
              autoCapitalize="none"
              autoComplete="email"
              autoCorrect={false}
              submitBehavior="submit"
              inputMode="email"
              onBlur={() => {
                setEntering(false);
                add(entryOf(getDraft(), field), true);
              }}
              onChangeText={(value) => {
                setEntering(true);
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
              onSubmitEditing={() => {
                if (first === undefined) {
                  add(entryOf(getDraft(), field), true);
                } else {
                  accept(first);
                }
              }}
              // VoiceOver reads the native placeholder; the one below draws it.
              placeholder={t('drafts.recipientPlaceholder')}
              placeholderTextColor="transparent"
              returnKeyType="next"
              hitSlop={fieldSlop[size]}
              style={[styles.input, sized.input, { color: colors.textPrimary }]}
              textContentType="emailAddress"
              value={entryOf(draft, field)}
            />
            {/* The native placeholder clips a longer translation; this one ends with an ellipsis. */}
            {entryOf(draft, field) === '' ? (
              <View
                accessibilityElementsHidden
                pointerEvents="none"
                style={styles.placeholder}>
                <Text
                  numberOfLines={1}
                  style={[sized.placeholder, { color: colors.textSecondary }]}>
                  {t('drafts.recipientPlaceholder')}
                </Text>
              </View>
            ) : null}
          </View>
        </View>
        {trailing === undefined ? null : (
          <View style={[sized.trailing, large && styles.stackedTrailing]}>
            {trailing}
          </View>
        )}
      </View>
      {shownNotice === undefined ? null : (
        <Text
          accessibilityLiveRegion="polite"
          style={[
            styles.notice,
            styles.fieldNotice,
            sized.fieldNotice,
            large && styles.stackedNotice,
            { color: colors.textSecondary },
          ]}>
          {shownNotice}
        </Text>
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
    progress,
    preview,
  }: Readonly<{
    asset: Asset;
    running: boolean;
    // The fraction of a running import read so far, once native code reports it.
    progress: number | undefined;
    preview: AssetPreview | undefined;
  }>,
) => {
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
    if (!running) {
      return t('drafts.assets.status.interrupted');
    }
    return progress === undefined
      ? t('drafts.assets.status.importing')
      : t('drafts.assets.status.importingProgress', {
          percent: Math.round(progress * 100),
        });
  }
  if (asset.state === 'cancelled') {
    return t('drafts.assets.status.cancelled');
  }
  if (asset.state === 'failed' && asset.reason === 'too-large') {
    return t('drafts.assets.status.tooLarge');
  }
  return t(
    asset.state === 'failed' && asset.notDownloaded === true
      ? 'drafts.assets.status.notDownloaded'
      : 'drafts.assets.status.notAdded',
  );
};

// Each running import's fraction read so far, by asset, as native code reports it; an import has
// none before its first report, such as pasted bytes, which report none. The composer listens
// before a file's row is shown, so a report sent as its read begins is kept; an import that stops
// forgets its reports, so a later Try Again starts without a percentage.
function useImportProgress(running: ReadonlySet<string>) {
  const [progress, setProgress] = useState<ReadonlyMap<string, number>>(
    () => new Map(),
  );
  if ([...progress.keys()].some((id) => !running.has(id))) {
    setProgress(new Map([...progress].filter(([id]) => running.has(id))));
  }
  useEffect(() => {
    const subscription = new NativeEventEmitter(native()).addListener(
      'draftImportProgress',
      (event: object) => {
        if (
          'id' in event &&
          typeof event.id === 'string' &&
          'fraction' in event &&
          typeof event.fraction === 'number'
        ) {
          const { id, fraction } = event;
          setProgress((current) => new Map(current).set(id, fraction));
        }
      },
    );
    return () => {
      subscription.remove();
    };
  }, []);
  return progress;
}

// A complete asset's bytes checked against its digest, read again when it completes or changes;
// an inline image's are also returned to show. A check refused while storage was locked runs
// again when the app becomes active, or when asked.
function usePreview(asset: Asset, inline: boolean) {
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
    const read = async () => {
      const next = await store.readAsset(
        { id, digest, type },
        { preview: inline },
      );
      if (showing) {
        setPreview({ id, digest, attempt, preview: next });
      }
    };
    void read();
    return () => {
      showing = false;
    };
  }, [store, id, digest, type, inline, attempt]);
  return { preview: shown, retry };
}

// The display sizes an inline image offers, as in the approved #1735 frames; Original names the
// image's own size.
const imageSizes = [
  ['small', 320],
  ['medium', 640],
  ['large', 1024],
  ['original', undefined],
] as const;

// An asset row's context menu and VoiceOver actions: an image in the body offers its display
// sizes and Remove Image; an editor that converts offers that, with Remove.
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
      : imageSizes.map(([size, sizeWidth]) => {
          const subtitle =
            sizeWidth === undefined
              ? dimensions && t('drafts.assets.size.dimensions', dimensions)
              : t('drafts.assets.size.width', { width: sizeWidth });
          return {
            key: `size:${size}:${asset.id}`,
            title: t(`drafts.assets.size.${size}`),
            symbol: '',
            ...(subtitle === undefined ? {} : { subtitle }),
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
          };
        });
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
    sections: [{ items: sizes }, { items: [...convert, remove] }],
    actions: [
      ...convert.map(({ run }) => ({
        name: 'convert',
        label: t(`drafts.assets.${toAttachment}Label`, { name: asset.name }),
        run,
      })),
      ...sizes.map(({ key, accessibilityLabel, run }) => ({
        name: key,
        label: accessibilityLabel,
        run,
      })),
    ],
  };
};

// A file's status line: a file that wasn't added shows its reason as a warning, and a running
// import its fraction as a bar under it.
function AssetStatus({
  failed,
  status,
  progress,
}: Readonly<{
  failed: boolean;
  status: string;
  progress: number | undefined;
}>) {
  const colors = usePalette();
  const sized = layoutStyles[use(ComposerLayoutContext).size];
  return (
    <>
      <View
        style={[
          styles.assetStatusRow,
          progress === undefined ? null : styles.assetStatusImporting,
        ]}>
        {failed ? (
          <SFSymbol
            name="exclamationmark.triangle.fill"
            size={13}
            color={colors.statusWarning}
          />
        ) : null}
        <Text
          numberOfLines={1}
          style={[
            styles.assetStatus,
            { color: failed ? colors.statusWarning : colors.textSecondary },
          ]}>
          {status}
        </Text>
      </View>
      {progress === undefined ? null : (
        <ProgressBar
          percent={progress * 100}
          style={sized.assetProgress}
        />
      )}
    </>
  );
}

function AssetRow({
  asset,
  editable,
  inline,
  running,
  progress,
  width,
  onRemove,
  onCancel,
  onTryAgain,
  onConvert,
  onPreview,
  onResize,
}: {
  readonly asset: Asset;
  readonly inline: boolean;
  readonly running: boolean;
  // The fraction of a running import read so far, once native code reports one.
  readonly progress: number | undefined;
  // Given for a file that wasn't added and whose source can be read again.
  readonly onTryAgain: (() => void) | undefined;
  readonly editable: boolean;
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
  const { preview, retry } = usePreview(asset, inline);
  const uri = inline && preview?.kind === 'ready' ? preview.uri : undefined;
  useEffect(() => {
    if (inline) {
      onPreview?.(asset.id, uri ?? null);
    }
  }, [asset.id, inline, onPreview, uri]);
  const status = assetStatus(t, (bytes) => fileSize(t, sizeFormat, bytes), {
    asset,
    running,
    progress,
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
    <View
      style={[
        styles.assetChip,
        layoutStyles[use(ComposerLayoutContext).size].assetChip,
        { backgroundColor: colors.fillQuiet },
      ]}>
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
              accessibilityActions: menu.actions.map(({ name, label }) => ({
                name,
                label,
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
          failed={asset.state === 'failed'}
          status={status}
          progress={progress}
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
      {/* R1 and R2 of #2092 draw the chip's actions at the reader's 15pt, its capsule reaching
          past the label. */}
      {onTryAgain === undefined || running ? null : (
        <Action
          variant="reader"
          disabled={!editable}
          accessibilityLabel={t('drafts.assets.retryImportLabel', {
            name: asset.name,
          })}
          label={t('common.retry')}
          onPress={onTryAgain}
        />
      )}
      {running ? (
        <Action
          variant="reader"
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
  return menu.sections.length > 0 && editable ? (
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
  onRemove,
  onCancel,
  onConvert,
  onPreview,
  onResize,
}: {
  readonly draft: Draft;
  readonly editable: boolean;
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
  const sized = layoutStyles[use(ComposerLayoutContext).size];
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  const retries = useSyncExternalStore(store.subscribe, store.getRetries);
  const progress = useImportProgress(running);
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
        progress={progress.get(asset.id)}
        onTryAgain={
          asset.state === 'failed' && retries.has(asset.id)
            ? () => {
                void store.retryImport(asset.id);
              }
            : undefined
        }
      />
    ));
  return (
    <View style={[styles.assets, sized.assets]}>
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
  const sized = layoutStyles[use(ComposerLayoutContext).size];
  return (
    <View style={[styles.quoted, sized.quoted]}>
      <Action
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

export const textToolLabel = (tool: TextTool, at: Selection) =>
  at.start === at.end
    ? (`assistance.${tool}DraftLabel` as const)
    : (`assistance.${tool}SelectionLabel` as const);

export const textToolSymbols: Readonly<Record<TextTool, string>> = {
  rewrite: 'pencil',
  proofread: 'text.badge.checkmark',
  paragraphs: 'text.alignleft',
  expand: 'arrow.up.and.down.text.horizontal',
  shorten: 'arrow.down.and.line.horizontal.and.arrow.up',
  friendly: 'face.smiling',
  neutral: 'face.dashed',
};

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

// Why Send is unavailable now, or else why the last Send left the Draft in the composer, if it
// did; only the last Send's outcome is announced. A message sent through an IMAP connection's mail
// server or Microsoft is not limited by Gmail.
const tooLarge = {
  gmail: 'drafts.sendRefused.too-large',
  imap: 'drafts.sendRefused.too-large_imap',
  'microsoft-graph': 'drafts.sendRefused.too-large_microsoft',
} as const satisfies Readonly<Record<MailProvider, string>>;
function SendRefusalNotice({
  blocked,
  refused,
  waiting,
  connection,
}: {
  readonly blocked: SendRefusal | undefined;
  readonly refused: SendRefusal | undefined;
  readonly waiting: string | undefined;
  readonly connection: string;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const { size } = use(ComposerLayoutContext);
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === connection,
  )?.provider;
  const shown = blocked ?? refused;
  // A file still importing is named above the body, as R2 of #2092 draws it, alongside any other
  // reason Send is unavailable.
  return (
    <>
      {shown === undefined ||
      (shown === 'assets' && waiting !== undefined) ? null : (
        <Alert
          outcome={shown === refused}
          message={t(
            shown === 'too-large'
              ? tooLarge[provider ?? 'gmail']
              : `drafts.sendRefused.${shown}`,
          )}
        />
      )}
      {waiting === undefined ? null : (
        <Text
          style={[
            styles.waiting,
            layoutStyles[size].waiting,
            { color: colors.textSecondary },
          ]}>
          {t('drafts.assets.stillImporting', { name: waiting })}
        </Text>
      )}
    </>
  );
}

// Why Send is unavailable, for VoiceOver on Send; `sender`
// says why the sending mailbox cannot send, if it says.
const blockedMessage = (
  t: Translate,
  blocked: SendRefusal,
  sender: string | undefined,
) => {
  if (blocked === 'recipients') {
    return t('drafts.recipient.required');
  }
  if (blocked === 'sender') {
    return sender ?? t('drafts.sendRefused.sender');
  }
  return t(`drafts.sendRefused.${blocked}`);
};

// Why Send is unavailable for the Draft shown, followed as its mailboxes change, and where the
// composer says it. To, Cc and Bcc say why Send waits for them, and From's notice why the sender
// cannot send, and the notices the rest; a docked reply asks for a recipient on one line above
// Send instead of under To.
// Send Now as Send's menu offers it: unavailable while Send is, naming a file still being added.
const sendNowOf = (
  blocked: SendRefusal | undefined,
  saving: boolean,
  adding: Asset | undefined,
) => ({
  disabled: saving || blocked !== undefined,
  waiting: adding?.name,
});

// Asks Send's question about files that were not added; resolves whether the person chose Send
// Without Them.
const askLeftOut = (
  question: NonNullable<ReturnType<typeof leftOutQuestion>>,
) =>
  // oxlint-disable-next-line promise/avoid-new -- The alert answers through its button callbacks.
  new Promise<boolean>((resolve) => {
    SystemAlert.alert(
      question.title,
      question.detail,
      [
        {
          text: question.send,
          isPreferred: true,
          onPress: () => {
            resolve(true);
          },
        },
        {
          text: question.keepEditing,
          style: 'cancel',
          onPress: () => {
            resolve(false);
          },
        },
      ],
      {
        onDismiss: () => {
          resolve(false);
        },
      },
    );
  });

function useBlockedSend({
  shown,
  draft,
  docked,
}: {
  // The Draft as Send would take it, with its typed entries.
  readonly shown: Draft;
  readonly draft: Draft;
  readonly docked: boolean;
}) {
  const { t } = useLocalization();
  const outbox = useOutbox();
  const mailboxList = useMailboxList();
  const mailboxes = use(AccountContext)?.mailboxes ?? [];
  const store = useDraftStore();
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  const finished = finishedEntries(shown);
  const refusal = useSyncExternalStore(mailboxList.subscribe, () =>
    outbox.refusal(finished),
  );
  // Files that were not added leave Send available, which asks to send without them; one still
  // being added keeps it unavailable.
  const adding = addingAsset(finished, running);
  const blocked =
    refusal === 'assets' && adding === undefined ? undefined : refusal;
  if (blocked === undefined) {
    return { blocked, reason: undefined, notice: undefined, line: undefined };
  }
  // Text left in To, Cc or Bcc says why Send waits, as its field does.
  const incomplete = (['to', 'cc', 'bcc'] as const)
    .map((field) => entryOf(finished, field))
    .find((entry) => entry !== '');
  let reason = blockedMessage(t, blocked, sendingMessage(t, draft, mailboxes));
  if (
    incomplete !== undefined &&
    (blocked === 'recipients' || blocked === 'entries')
  ) {
    reason = t('drafts.recipient.incomplete', { address: incomplete });
  }
  if (adding !== undefined) {
    // VoiceOver reads the file Send waits for with Send, after any recipient it waits for.
    const importing = t('drafts.assets.stillImporting', { name: adding.name });
    reason = blocked === 'assets' ? importing : `${reason} ${importing}`;
  }
  const ownPlace =
    blocked === 'recipients' || blocked === 'entries' || blocked === 'sender';
  return {
    blocked,
    reason,
    notice: ownPlace ? undefined : blocked,
    line:
      docked && blocked === 'recipients'
        ? t('drafts.recipient.required')
        : undefined,
  };
}

// Once Cc or Bcc is shown or holds a recipient or text, both stay shown for the Draft, so they can
// say why Send waits.
const copiesShownOf = (draft: Draft) =>
  draft.copies === true ||
  draft.cc.length + draft.bcc.length > 0 ||
  entryOf(draft, 'cc') !== '' ||
  entryOf(draft, 'bcc') !== '';

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
  readonly captured: CapturedDraftText;
  readonly assistance: NativeAssistance | undefined;
  readonly translation: NativeTranslation | undefined;
  readonly onApply: (text: string) => void;
  readonly onClose: () => void;
  readonly onPending?: ((pending: boolean) => void) | undefined;
}) {
  if (captured.purpose === 'translate') {
    return translation === undefined ? null : (
      <DraftTranslation
        translator={translation}
        text={captured.text}
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

// The header's Close: a glass circle with the native glass press; disabled dims its symbol.
export function CloseButton({
  disabled = false,
  expanded,
  anchor,
  onPress,
}: {
  readonly disabled?: boolean;
  // Close reports whether its save question is open.
  readonly expanded?: boolean;
  // Where CloseQuestion opens.
  readonly anchor?: RefObject<ViewInstance | null>;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Glass
      cornerRadius={22}
      interactive
      style={[styles.circle, { boxShadow: colors.smallGlassShadow }]}>
      <Pressable
        accessibilityLabel={t('drafts.close')}
        accessibilityRole="button"
        accessibilityState={{
          disabled,
          ...(expanded === undefined ? {} : { expanded }),
        }}
        ref={anchor}
        disabled={disabled}
        onPress={onPress}
        style={[styles.circle, { opacity: disabled ? 0.4 : 1 }]}>
        <SFSymbol
          name="xmark"
          color={colors.textPrimary}
        />
      </Pressable>
    </Glass>
  );
}

// Delete Draft and Save Draft open over the header's Close (`anchor`) and grow out of it, as a
// system menu does; a tap outside them (Keep Editing) keeps editing.
export function CloseQuestion({
  open,
  anchor,
  onDelete,
  onSave,
  onCancel,
}: {
  readonly open: boolean;
  readonly anchor: RefObject<ViewInstance | null>;
  readonly onDelete: () => void;
  readonly onSave: () => void;
  readonly onCancel: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const layer = useRef<ViewInstance>(null);
  const [at, setAt] = useState<Readonly<{ left: number; top: number }>>();
  // Measured as it opens, so the panel covers Close wherever its header placed it.
  useLayoutEffect(() => {
    if (open) {
      anchor.current?.measureInWindow((x, y) => {
        layer.current?.measureInWindow((left, top) => {
          setAt({ left: x - left, top: y - top });
        });
      });
    }
  }, [anchor, open]);
  const choice = (label: string, destructive: boolean, onPress: () => void) => (
    <Pressable
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.closeChoice,
        {
          // The selection tint lowers destructive text below AA contrast.
          backgroundColor:
            pressed && !destructive
              ? colors.accentSelectionSubtle
              : colors.fillQuiet,
        },
      ]}>
      <Text
        style={[
          styles.closeChoiceText,
          {
            color: destructive ? colors.statusDestructive : colors.textPrimary,
          },
        ]}>
        {label}
      </Text>
    </Pressable>
  );
  return (
    <View
      ref={layer}
      accessibilityViewIsModal={open}
      onAccessibilityEscape={onCancel}
      pointerEvents={open ? 'auto' : 'none'}
      style={styles.closeQuestion}>
      {open ? (
        // Outside the question, as UIKit's menus offer VoiceOver a way out too.
        <Pressable
          accessibilityLabel={t('drafts.keepEditing')}
          accessibilityRole="button"
          onPress={onCancel}
          style={StyleSheet.absoluteFill}
        />
      ) : null}
      <View
        accessibilityRole="menu"
        accessibilityElementsHidden={!open}
        pointerEvents="box-none"
        style={[styles.closeQuestionPlace, at]}>
        <GlassPanel
          cornerRadius={radius.closeQuestion}
          open={open}
          // Grows out of Close's centre, 22pt into the panel's corner.
          origin="22px 22px"
          from={0.2}
          style={styles.closeQuestionPanel}>
          {choice(t('drafts.deleteDraft'), true, onDelete)}
          {choice(t('drafts.saveDraft'), false, onSave)}
        </GlassPanel>
      </View>
    </View>
  );
}

// The header's Send: the accent fill shows at 80% (CC) while pressed; disabled, the quiet fill holds
// the arrow or name in the secondary text color at 50%, as the blocked Send frames draw it.
export function SendButton({
  disabled,
  hint,
  titled = false,
  onPress,
  onBlockedPress,
}: {
  readonly disabled: boolean;
  // Why Send is unavailable, read after its name.
  readonly hint?: string | undefined;
  // iPad names Send in a rounded button; iPhone keeps the arrow circle.
  readonly titled?: boolean;
  readonly onPress: () => void;
  // A press while Send is unavailable, which shows the person what it waits for.
  readonly onBlockedPress?: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Pressable
      accessibilityLabel={t('drafts.send')}
      accessibilityHint={hint}
      accessibilityRole="button"
      // Pressable treats a disabled state as unpressable, so one that shows its reason is not.
      accessibilityState={{
        disabled: disabled && onBlockedPress === undefined,
      }}
      disabled={disabled && onBlockedPress === undefined}
      hitSlop={titled ? (44 - titledSendHeight) / 2 : undefined}
      onPress={disabled ? onBlockedPress : onPress}
      style={({ pressed }) => [
        titled ? styles.sendTitled : styles.circle,
        disabled
          ? { backgroundColor: colors.fillQuiet }
          : {
              backgroundColor: pressed
                ? `${colors.accentFill}CC`
                : colors.accentFill,
            },
      ]}>
      <View style={disabled && styles.sendDisabled}>
        {titled ? (
          <Text
            style={[
              styles.sendLabel,
              { color: disabled ? colors.textSecondary : colors.accentOnFill },
            ]}>
            {t('drafts.send')}
          </Text>
        ) : (
          <SFSymbol
            name="arrow.up"
            color={disabled ? colors.textSecondary : colors.accentOnFill}
          />
        )}
      </View>
    </Pressable>
  );
}

// Why the composer stays open, or what it asks before discarding, above the format bar.
export function ComposerNotices({
  closing,
  draft,
  blocked,
  refused,
  signIn = true,
  onClose,
  onDiscard,
  onKeepEditing,
}: {
  readonly closing: Closing | undefined;
  readonly draft: Draft;
  // Why Send is unavailable now, when no field or line beside Send says it.
  readonly blocked?: SendRefusal | undefined;
  // Whether the Authorization Needed banner shows here; the editor shows it under From.
  readonly signIn?: boolean;
  readonly refused: SendRefusal | undefined;
  readonly onClose: () => void;
  readonly onDiscard: () => void;
  readonly onKeepEditing: () => void;
}) {
  const { t } = useLocalization();
  const { size } = use(ComposerLayoutContext);
  const mailboxes = use(AccountContext)?.mailboxes ?? [];
  const store = useDraftStore();
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  // The file still importing that Send waits for.
  const waiting = addingAsset(draft, running)?.name;
  // On iPad nothing holds the body down while there is nothing to say; iPhone's body inset counts
  // the notices' 8pt.
  if (
    size === 'regular' &&
    (closing === undefined || closing === 'saving') &&
    blocked === undefined &&
    waiting === undefined &&
    refused === undefined &&
    (sendingStateOf(draft, mailboxes) === 'available' ||
      (!signIn && sendingStateOf(draft, mailboxes) === 'authorization'))
  ) {
    return null;
  }
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
            size="compact"
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
        blocked={blocked}
        connection={draft.connection}
        refused={refused}
        waiting={waiting}
      />
      <SendingNotice
        draft={draft}
        signIn={signIn}
      />
      {closing === 'discard' ? (
        <Alert
          outcome
          message={t('drafts.discardConfirm')}>
          <Button
            size="compact"
            destructive
            label={t('drafts.discardDraft')}
            onPress={onDiscard}
          />
          <Button
            size="compact"
            label={t('drafts.keepEditing')}
            onPress={onKeepEditing}
          />
        </Alert>
      ) : null}
    </View>
  );
}

// The format bar's Writing tools: one system menu of Generate a Draft, the text tools and Translate
// where they are available, plus Suggest Reply on replies. Hidden when neither is available.
// Generate a Draft first asks for a prompt, which is never kept.
function WritingTools({
  assistance,
  translation,
  reply,
  body,
  selection,
  sending,
  popover,
  prompt,
  onGenerate,
  onTextTool,
  onTranslate,
  onReply,
}: {
  readonly assistance: boolean;
  readonly translation: boolean;
  readonly reply: boolean;
  readonly body: Draft['body'];
  readonly selection: Selection;
  readonly sending: boolean;
  readonly popover: boolean;
  readonly prompt: GeneratePromptState;
  readonly onGenerate: (prompt: string) => void;
  readonly onTextTool: (tool: TextTool) => void;
  readonly onTranslate: () => void;
  readonly onReply: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (!assistance && !translation) {
    return null;
  }
  const rewritable = canRewrite(body, selection);
  const tools = (...names: TextTool[]) =>
    assistance
      ? names.map((tool) => ({
          key: tool,
          title: t(`assistance.${tool}`),
          accessibilityLabel: t(textToolLabel(tool, selection)),
          symbol: textToolSymbols[tool],
          disabled: !rewritable,
          run: () => {
            onTextTool(tool);
          },
        }))
      : [];
  const translate = {
    key: 'translate',
    title: t('translation.translate'),
    accessibilityLabel: t('translation.translateSelectionLabel'),
    symbol: 'translate',
    disabled: !hasTranslatableText(
      selectedText(textOf(body), selection, translationInputLimit + 1),
    ),
    run: onTranslate,
  };
  const generate = {
    key: 'generate',
    title: t('assistance.generate'),
    accessibilityLabel: t('assistance.generateLabel'),
    symbol: 'square.and.pencil',
    run: prompt.open,
  };
  const suggestReply = {
    key: 'reply',
    title: t('assistance.suggestReply'),
    accessibilityLabel: t('assistance.suggestReplyLabel'),
    symbol: '',
    run: onReply,
  };
  const menu = (
    <MenuButton
      accessibilityLabel={t('drafts.writingTools')}
      alignMenuToRowEnd={iphone && !popover}
      disabled={sending}
      sections={[
        [
          ...(assistance ? [generate] : []),
          ...tools('rewrite'),
          ...(assistance && reply ? [suggestReply] : []),
        ],
        tools('proofread', 'paragraphs'),
        translation ? [translate] : [],
        tools('expand', 'shorten'),
        tools('friendly', 'neutral'),
      ].flatMap((items) => (items.length === 0 ? [] : [{ items }]))}
      style={styles.menuControl}>
      <SFSymbol
        name="sparkles"
        size={popover ? scaledToolbar.symbol : 20}
        color={colors.textPrimary}
      />
    </MenuButton>
  );
  return (
    <GeneratePrompt
      state={prompt}
      popover={popover}
      disabled={sending}
      // On iPhone the menu floats in its own glass beside the pill.
      trigger={
        popover ? (
          menu
        ) : (
          <GlassGroup style={styles.pillGroup}>{menu}</GlassGroup>
        )
      }
      onGenerate={onGenerate}
    />
  );
}

// A new Mail Template's identifier: random lowercase letters and digits.
const templateId = () => {
  let id = '';
  while (id.length < 24) {
    id += Math.random().toString(36).slice(2);
  }
  return id.slice(0, 24);
};

// The Templates menu's items: the Mail Profile's templates for the Draft from `connection`, read
// when the composer opens and after it saves one, and saving the Draft as `getDraft` gives it, when
// chosen, as a new template under the name asked for. The Draft itself does not change.
function useTemplateItems({
  connection,
  getDraft,
  onInsert,
}: {
  readonly connection: string;
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
  const mounted = useRef(true);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      reads.current += 1;
      mounted.current = false;
    };
  }, []);
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
    SystemAlert.alert(t('drafts.templates.notSaved'), detail, [
      { text: t('common.ok') },
    ]);
  };
  const save = () => {
    const { subject, body: shown } = getDraft();
    const body = textOf(shown);
    const owner = profile;
    if (imagesOf(body).length > 0) {
      notSaved(t('drafts.templates.hasImages'));
      return;
    }
    if (shown.some((part) => part.kind === 'table')) {
      notSaved(t('drafts.templates.hasTables'));
      return;
    }
    const saveNamed = async (entered = '') => {
      const name = entered.trim();
      if (name === '') {
        notSaved(t('drafts.templates.needsName'));
        return;
      }
      const saved = await store
        .save(owner, { id: templateId(), name, subject, body })
        .catch(() => false);
      if (!mounted.current) {
        return;
      }
      if (saved) {
        void read(profileNow.current);
      } else {
        notSaved(t('drafts.templates.notSavedDetail'));
      }
    };
    SystemAlert.prompt(
      t('drafts.templates.nameTitle'),
      t('drafts.templates.nameDetail'),
      [
        { text: t('common.cancel'), style: 'cancel' },
        {
          text: t('drafts.templates.save'),
          isPreferred: true,
          onPress: (entered?: string) => {
            void saveNamed(entered);
          },
        },
      ],
      'plain-text',
    );
  };
  return {
    templates: (templates?.profile === profile ? templates.list : []).map(
      (template) => ({
        key: `template-${template.id}`,
        title: template.name,
        symbol: 'doc.on.doc',
        subtitle:
          template.subject.trim() === ''
            ? t('drafts.templates.bodyOnly')
            : t('drafts.templates.subject', { subject: template.subject }),
        run: () => {
          onInsert(template);
        },
      }),
    ),
    save: {
      key: 'new-template',
      title: t('drafts.templates.newFromMessage'),
      symbol: 'plus',
      run: save,
    },
  };
}

// The Link Editor and Generate a Draft's prompt, kept above the composer's layouts so an open one
// outlives a resize between them. On iPhone the Link Editor's sheet opens from the Format panel,
// and Generate a Draft's from the pill the panel replaces.
function useOpenPresenters({
  regular,
  assisted,
  profile,
  formatting,
  setFormatting,
}: {
  readonly regular: boolean;
  readonly assisted: boolean;
  readonly profile: string;
  readonly formatting: boolean;
  readonly setFormatting: (formatting: boolean) => void;
}) {
  const linkEditor = useLinkEditor();
  const generatePrompt = useGeneratePrompt(assisted ? profile : undefined);
  if (
    !regular &&
    (linkEditor.shown || generatePrompt.shown) &&
    formatting !== linkEditor.shown
  ) {
    setFormatting(linkEditor.shown);
  }
  return { linkEditor, generatePrompt };
}

// iPhone's window-filling composer, the iPad New Message card, or an iPad reply docked beneath
// the message it answers.
type Presentation = 'compact' | 'card' | 'docked';

// Each presentation's header and title additions.
const headerStyles = {
  compact: null,
  card: styles.cardHeader,
  docked: styles.dockedHeader,
} as const;
const titleStyles = {
  compact: null,
  card: styles.regularTitle,
  docked: [styles.regularTitle, styles.leadingTitle],
} as const;
// A docked reply's tighter body, fields and format bar.
const sharedParts = { content: null, body: null, formatBar: null } as const;
const partStyles = {
  compact: sharedParts,
  card: sharedParts,
  docked: {
    content: styles.dockedContent,
    body: styles.dockedBody,
    formatBar: styles.dockedFormatBar,
  },
} as const;

// The iPhone sheet's header and title additions.
const sheetStyles = (sheet: boolean) =>
  sheet
    ? {
        header: styles.sheetHeader,
        title: styles.sheetTitle,
        fromRow: styles.sheetFromRow,
      }
    : { header: null, title: null, fromRow: null };

const presentationOf = (regular: boolean, draft: Draft): Presentation => {
  if (!regular) {
    return 'compact';
  }
  return draft.response === undefined ? 'card' : 'docked';
};

// From sits in the iPad header and on its own row beneath the iPhone header, where a compact iPad
// window's sheet ends the row with its command input. At the accessibility
// text sizes the iPad card's From takes its own row too, so Expand and Send stay in view. The
// Authorization Needed banner stays in view under From; at those sizes it would crowd out the
// Draft, so it scrolls with it among the notices (`signInNotice`). A docked reply's
// ReplyFooter places From and the banner.
const placeSender = ({
  sender,
  draft,
  presentation,
  large,
  rowStyle,
}: {
  readonly sender: ReactNode;
  readonly draft: Draft;
  readonly presentation: Presentation;
  readonly large: boolean;
  readonly rowStyle: StyleProp<ViewStyle>;
}) => {
  if (presentation === 'docked') {
    return { header: sender, row: null, signInNotice: false };
  }
  const compact = presentation === 'compact';
  const signIn = large ? null : (
    <SignInBanner
      draft={draft}
      style={compact ? styles.phoneSignIn : styles.cardSignIn}
    />
  );
  return compact || large
    ? {
        signInNotice: large,
        header: null,
        row: (
          <>
            <View style={[styles.fromRow, rowStyle]}>
              <View style={[styles.bar, styles.grow]}>{sender}</View>
              <CommandInput sheet />
            </View>
            {signIn}
          </>
        ),
      }
    : { header: sender, row: signIn, signInNotice: false };
};

// A docked or iPhone response is titled by its kind; otherwise the subject names the Draft. Only a
// clipped subject is announced as shortened.
const composerTitle = (
  t: ReturnType<typeof useLocalization>['t'],
  draft: Draft,
  byKind: boolean,
) => {
  if (byKind && draft.response !== undefined) {
    const title = t(responseTitles[draft.response.kind]);
    return { title, titleLabel: title };
  }
  const title = clip(draft.subject) || t('drafts.newMessage');
  return {
    title,
    titleLabel:
      title.length < draft.subject.length
        ? t('drafts.titleShortened', { title })
        : title,
  };
};

// The header's trailing controls. iPhone: the Command input, Actions and Send. The iPad card: From,
// Expand and Send, as Close asks whether to keep the Draft. The docked reply: Expand and Discard, with
// From and Send beneath its fields.
function HeaderControls({
  presentation,
  sender,
  expanded,
  onExpand,
  discardDisabled,
  onDiscard,
  send,
}: {
  readonly presentation: Presentation;
  readonly sender: ReactNode;
  readonly expanded: boolean | undefined;
  readonly onExpand: (() => void) | undefined;
  readonly discardDisabled: boolean;
  readonly onDiscard: () => void;
  // Send, with or without its title.
  readonly send: (titled: boolean) => ReactNode;
}) {
  const { t } = useLocalization();
  const expand =
    onExpand === undefined ? null : (
      <ToolbarButton
        icon={
          expanded
            ? 'arrow.down.right.and.arrow.up.left'
            : 'arrow.up.left.and.arrow.down.right'
        }
        label={t(expanded ? 'drafts.collapse' : 'drafts.expand')}
        onPress={onExpand}
      />
    );
  if (presentation === 'card') {
    // The frame's card has no Expand; on iPad it still takes the whole window (docs/drafts.md).
    return (
      <>
        {sender}
        {expand}
        {send(true)}
      </>
    );
  }
  if (presentation === 'docked') {
    return (
      <>
        {expand}
        <ToolbarButton
          disabled={discardDisabled}
          icon="trash"
          label={t('drafts.discard')}
          onPress={onDiscard}
        />
      </>
    );
  }
  return (
    <>
      <CommandInput />
      {expand}
      <ComposerActions
        disabled={discardDisabled}
        onDiscard={onDiscard}
      />
      {send(false)}
    </>
  );
}

// The docked reply's From and Send beneath its fields, as in the iPad Compose Inline frame.
function ReplyFooter({
  draft,
  sender,
  send,
  reason,
}: {
  readonly draft: Draft;
  readonly sender: ReactNode;
  readonly send: ReactNode;
  // Why Send waits for a recipient, on one line above it as the iPad frame draws it.
  readonly reason: string | undefined;
}) {
  const colors = usePalette();
  return (
    <>
      {reason === undefined ? null : (
        <Text style={[styles.blockedReason, { color: colors.textSecondary }]}>
          {reason}
        </Text>
      )}
      <View style={[styles.replyFooter, { borderTopColor: colors.separator }]}>
        {sender}
        <View style={styles.grow} />
        {send}
      </View>
      <SignInBanner
        draft={draft}
        style={styles.dockedSignIn}
      />
    </>
  );
}

// Whether the Drafts store holds every edit it was given.
export const savedOf = (state: DraftsState) =>
  state.kind === 'ready' && state.save === 'saved';

// Keeps the editor's unsaved version, which `unsaved` returns, in a composer recovery record
// through the shared journal (ADR 0077): a few seconds after each `edited` change and when the app
// returns to the foreground. The first returned function closes the journal on Draft `id` the
// editor closes on and resolves once its records are gone. The
// second journals at once, as after a save that keeps the editor open; the third too, unless
// unsaved edits have a write scheduled.
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
  return [journal.close, journal.write, journal.settle] as const;
}

// A Product Account's offer of the composer recovery records the previous run left: those already
// offered, and the latest alert asking about one.
interface RecoveryOffer {
  readonly offered: Set<string>;
  asking?: Promise<boolean>;
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

// Asks about one record in the system alert; resolves whether the person chose Restore.
const askRecovery = (t: Translate) =>
  // oxlint-disable-next-line promise/avoid-new -- The alert answers through its button callbacks.
  new Promise<boolean>((resolve) => {
    SystemAlert.alert(t('drafts.recover.title'), t('drafts.recover.detail'), [
      {
        text: t('drafts.recover.restore'),
        isPreferred: true,
        onPress: () => {
          resolve(true);
        },
      },
      {
        text: t('drafts.recover.discard'),
        style: 'destructive',
        onPress: () => {
          resolve(false);
        },
      },
    ]);
  });

// Offers each composer recovery record the previous run left (ADR 0077) whose Draft and recovered
// sender belong to the shown Profile, in its own alert, once the Drafts open and while no composer
// is open or being created. Restore opens the record's Draft through `onRestore` and returns the
// record as `recovered` for the composer to open on, until that composer closes or another Draft
// opens; `follow` keeps it while that composer moves to a conflicting copy. Discard removes the
// record unless an editor has its Draft open. A record changed or removed since it was read, a
// failed removal and a Draft no longer listed leave the record for the next launch; an answer
// given after the shell moved on, as to a composer a notification opened, is asked again.
export function useRecoveryOffer(
  composing: string | undefined,
  onRestore: (id: string) => void,
) {
  const store = useDraftStore();
  const navigation = useComposerNavigation();
  const ready = useDrafts().kind === 'ready';
  const profile = useProfile();
  const accountContext = use(AccountContext);
  const mailboxes = accountContext?.mailboxes;
  const account = accountContext?.account;
  const { t } = useLocalization();
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
  // The record restored, under the Draft ids its composer showed, and whether it opened: the route
  // reaches the composer after the render that restores it.
  const [restored, setRestored] = useState<{
    readonly record: Recovered;
    readonly ids: readonly string[];
    readonly shown: boolean;
  }>();
  if (restored !== undefined) {
    if (composing !== undefined && restored.ids.includes(composing)) {
      if (!restored.shown) {
        setRestored({ ...restored, shown: true });
      }
    } else if (restored.shown || composing !== undefined) {
      setRestored(undefined);
    }
  }
  const follow = useCallback((copy: string) => {
    setRestored(
      (current) => current && { ...current, ids: [...current.ids, copy] },
    );
  }, []);
  const latest = useRef({ onRestore, mailboxes });
  useLayoutEffect(() => {
    latest.current = { onRestore, mailboxes };
  });
  useEffect(() => {
    if (!ready || composing !== undefined) {
      return;
    }
    const offers =
      recoveryOffers.get(store) ?? new Map<string | undefined, RecoveryOffer>();
    recoveryOffers.set(store, offers);
    let offer = offers.get(account);
    if (offer === undefined) {
      offer = { offered: new Set() };
      offers.set(account, offer);
    }
    const own = offer;
    let current = true;
    const askNext = () => {
      if (current) {
        setRound((count) => count + 1);
      }
    };
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
    // Whether record `draft` and its Draft as listed now belong to the shown Profile.
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
      const creations = navigation.creations();
      // An alert an earlier attempt left open is answered first.
      await own.asking;
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
        askNext();
      }
      refused.current =
        records === undefined && activations.current === activated;
      if (pending === undefined) {
        return;
      }
      const draft = pending.version;
      // A record changed or removed since it was read is not offered; it stays for the next launch.
      // One whose Draft moved meanwhile stays for its Profile.
      const intact = await unchanged(draft);
      if (!current) {
        return;
      }
      if (!intact || !owned(draft)) {
        if (!intact) {
          own.offered.add(draft.id);
        }
        askNext();
        return;
      }
      const base = pending.base ?? draftOf(store.getSnapshot(), draft.id);
      // A New Message pending or finished meanwhile owns the next composer: the record is offered
      // once that composer closes.
      if (creations === undefined || navigation.creations() !== creations) {
        return;
      }
      own.asking = askRecovery(t);
      const restore = await own.asking;
      const kept = await unchanged(draft);
      if (!current || base === undefined) {
        return;
      }
      // A kept record whose Draft moved to another Profile meanwhile stays for that Profile.
      if (kept && !owned(draft)) {
        askNext();
        return;
      }
      own.offered.add(draft.id);
      if (kept) {
        store.take(draft.id);
        if (restore) {
          setRestored({
            record: { version: draft, base },
            ids: [draft.id],
            shown: false,
          });
          latest.current.onRestore(draft.id);
          return;
        }
        await store.forget(draft.id, discarding);
      }
      askNext();
    };
    const offerNext = async () => {
      try {
        await ask();
      } catch {
        // Store calls log their own failures; the records stay for the next launch.
      }
    };
    void offerNext();
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react/exhaustive-effect-dependencies -- Each answer asks again.
  }, [account, composing, navigation, profile, ready, round, store, t]);
  return { recovered: restored?.record, follow };
}

// The Mail Profile owning Draft `draft` on `connection`, and so its Send Reminder, and that
// reminder once read: one read before the editor moved to a conflict copy or another Profile
// belongs to that Draft.
function useDraftReminder(draft: string, connection: Draft['connection']) {
  const sendReminders = useSendReminders();
  const profile = profileOf(connection, use(AccountContext)?.mailboxes ?? []);
  const [read, setRead] = useState<SendReminder>();
  // Read again after each stored change, such as one another device synchronized; only the
  // latest read applies.
  useEffect(() => {
    let latest = 0;
    const load = async () => {
      latest += 1;
      const mine = latest;
      const listed = await sendReminders.reminders(profile);
      if (mine === latest && listed !== undefined) {
        setRead(listed.find((each) => each.draft === draft));
      }
    };
    void load();
    const unsubscribe = sendReminders.subscribe(() => void load());
    return () => {
      unsubscribe();
      latest += 1;
    };
  }, [sendReminders, profile, draft]);
  const reminder =
    read?.draft === draft && read.profile === profile ? read : undefined;
  return { sendReminders, profile, reminder, setRead };
}

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

// The Body Recipient Shortcut in an editor's body. Typing @ at a paragraph start or after
// whitespace opens Recipient Suggestions under it; a space, a caret move, leaving the body or a choice closes
// them, keeping the typed text.
function useBodyRecipients(
  draft: Draft,
  selection: Selection,
  {
    paused,
    pausedNow,
  }: Readonly<{
    paused: boolean;
    // Ahead of rendering, as native events can arrive before a pause commits.
    pausedNow: Readonly<{ current: boolean }>;
  }>,
) {
  const { t } = useLocalization();
  // The @ whose suggestions show.
  const [armed, setArmed] = useState<number>();
  const armedNow = useRef(armed);
  // The suggestion a hardware keyboard highlighted, by address, ahead of rendering as native
  // events can arrive before it commits; the first one shows highlighted without it.
  const [chosen, setChosen] = useState<string>();
  const chosenNow = useRef(chosen);
  const choose = useCallback((address: string | undefined) => {
    chosenNow.current = address;
    setChosen(address);
  }, []);
  // The statuses VoiceOver last heard for the shown suggestions.
  const heard = useRef<
    Readonly<{ empty?: string | undefined; note?: string | undefined }>
  >({});
  const arm = useCallback((at: number | undefined) => {
    armedNow.current = at;
    heard.current = {};
    setArmed(at);
    chosenNow.current = undefined;
    setChosen(undefined);
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
  const active =
    suggestions.find(({ address }) => address === chosen) ?? suggestions[0];
  // A bare @ with no recent correspondent shows nothing; typed text shows No Matches.
  const shown =
    sections !== undefined &&
    (active !== undefined || sections.query.text !== '')
      ? {
          sections,
          active,
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
  // iOS ignores live regions. A bare @ that hides the menu clears them.
  const emptyNow =
    shown !== undefined && active === undefined ? shown.empty : undefined;
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
  // The suggestions for the latest Draft and caret, ahead of rendering, while they show.
  const candidates = (latest: Draft, at: Selection) => {
    const current = bodyRecipientQuery(textOf(latest.body), at);
    if (
      pausedNow.current ||
      current === undefined ||
      current.start !== armedNow.current
    ) {
      return undefined;
    }
    const listed = bodySuggestions(latest, current, {
      connections: connections ?? [],
      held,
      contacts: contacts.addresses,
    });
    return [...listed.recent, ...listed.contacts];
  };
  return {
    shown,
    close,
    // After a body edit inserting `inserted`: typing @ opens suggestions, and leaving its query
    // closes them.
    typed: (next: SemanticDocument, caret: Selection, inserted: string) => {
      const typed = bodyRecipientQuery(next, caret);
      if (inserted === '@' && typed?.text === '') {
        arm(typed.start);
      } else if (typed?.start === armedNow.current) {
        // The list changed, so the highlight starts over.
        choose(undefined);
      } else if (armedNow.current !== undefined) {
        arm(undefined);
      }
    },
    // A hardware keyboard's Up and Down Arrow move the highlight while two or more show.
    moving: suggestions.length > 1,
    // Typed Return and Tab choose the highlighted suggestion while any shows.
    choosing: suggestions.length > 0,
    // Up and Down move from the highlighted suggestion for the latest Draft and caret.
    move: (key: string, latest: Draft, at: Selection) => {
      const listed = candidates(latest, at) ?? [];
      const index = Math.max(
        listed.findIndex(({ address }) => address === chosenNow.current),
        0,
      );
      const step = { ArrowDown: 1, ArrowUp: -1 }[key] ?? 0;
      const next =
        listed[Math.min(Math.max(index + step, 0), listed.length - 1)];
      choose(next?.address);
    },
    // The highlighted suggestion for the latest Draft and caret, which Return or Tab chooses:
    // the keyboard's choice while it still matches, else the first.
    highlighted: (latest: Draft, at: Selection) => {
      const listed = candidates(latest, at) ?? [];
      return (
        listed.find(({ address }) => address === chosenNow.current) ?? listed[0]
      );
    },
    // The query a choice of `address` replaces in the latest body, while the latest suggestions
    // still list that person.
    choosable: (latest: Draft, at: Selection, address: string) =>
      candidates(latest, at)?.some((listed) => listed.address === address)
        ? bodyRecipientQuery(textOf(latest.body), at)
        : undefined,
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
  };
}

type LaidText = Partial<
  Record<'query' | 'line' | 'at', TextLayoutEvent['nativeEvent']['lines']>
>;

const endOf = (each: LaidText['line'] = []) => {
  const line = each.at(-1);
  return line === undefined ? 0 : line.x + line.width;
};

// How far the @ at `offset` in its line sits from the line's start: the line copied through the @
// ends that far plus the @'s own width, unless typing the query moved the @ onto a later line,
// which it then starts.
function atIndent(laid: LaidText, offset: number) {
  const query = laid.query ?? [];
  const atLine = query.findIndex(
    (_, index) =>
      query
        .slice(0, index + 1)
        .reduce((length, { text }) => length + text.length, 0) > offset,
  );
  return atLine >= (laid.line?.length ?? 0)
    ? (query.at(atLine)?.x ?? 0)
    : Math.max(endOf(laid.line) - endOf(laid.at), 0);
}

// A menu under the line of the body's query at `start`: a transparent copy of the body up to that
// line, in the body's place and style, holds it there. It ends `reserve` above the bottom of the
// editor's `viewport`, scrolling inside when taller, and opens over the line when it sits too low
// for it and more room is above. The editor calls `placeRef` as it scrolls or resizes. `children`
// draws the menu from where it grows, the height it may take and a report of its rows' height.
function BodyMenuAnchor({
  start,
  end,
  display,
  top,
  bodyStyle,
  viewport,
  reserve,
  placeRef,
  children,
}: {
  readonly start: number;
  // The caret, where the query and the copied line end.
  readonly end: number;
  readonly display: ReturnType<typeof displayOf>;
  // Where the body starts.
  readonly top: number;
  readonly bodyStyle: StyleProp<TextStyle>;
  readonly viewport: Readonly<{ current: ViewInstance | null }>;
  readonly reserve: number;
  readonly placeRef: { current: (() => void) | undefined };
  readonly children: (
    place: Readonly<{
      origin: string;
      maxHeight: number | undefined;
      onContentHeight: (height: number) => void;
      // The @'s distance from its line's start, and the line's width once measured.
      indent: number;
      width: number | undefined;
    }>,
  ) => ReactNode;
}) {
  const appearance = useAppearance();
  const queryLine = useRef<ViewInstance>(null);
  const [room, setRoom] =
    useState<
      Readonly<{ below: number; above: number; lift: number; width: number }>
    >();
  const [rows, setRows] = useState(0);
  const measure = () => {
    const view = viewport.current?.getBoundingClientRect();
    const line = queryLine.current?.getBoundingClientRect();
    if (view === undefined || line === undefined) {
      return;
    }
    // The lowest the menu may end, and how far over the line's bottom it ends when it opens over
    // the line, staying clear of the pill. Room is less the menu's padding and margin, at most 24pt.
    const floor = view.bottom - reserve;
    const lift = Math.max(line.height, line.bottom - floor);
    setRoom({
      below: floor - line.bottom - 24,
      above: line.bottom - lift - view.top - spacing.s - 24,
      lift,
      width: line.width,
    });
  };
  useEffect(() => {
    placeRef.current = measure;
    return () => {
      placeRef.current = undefined;
    };
  });
  // Fabric reports no layout for views inside text, so text measures the @.
  const [laid, setLaid] = useState<LaidText>({});
  const layoutOf =
    (key: keyof LaidText) =>
    ({ nativeEvent: { lines: each } }: TextLayoutEvent) => {
      setLaid((current) => ({ ...current, [key]: each }));
    };
  // The lines up to the caret: text after it may wrap below the line the menu hangs from.
  const lineStart = display.text.lastIndexOf('\n', start - 1) + 1;
  const indent = atIndent(laid, start - lineStart);
  const lines = display.lines.slice(
    0,
    display.text.slice(0, start).split('\n').length,
  );
  type Line = (typeof lines)[number];
  const cut = (spans: Line['spans'], from: number, to: number) => {
    let offset = 0;
    return spans.flatMap((span) => {
      const text = span.text.slice(
        Math.max(from - offset, 0),
        Math.max(to - offset, 0),
      );
      offset += span.text.length;
      return text === '' ? [] : [{ ...span, text }];
    });
  };
  // Formatted as the body shows them, since formatting can change a line's height.
  const spanCopy = (spans: Line['spans']) =>
    spans.map((span, at) => (
      <Text
        // oxlint-disable-next-line react/no-array-index-key -- Spans are positional.
        key={at}
        style={[
          markStyle(span.marks, 'link' in span),
          formatStyleOf(span, appearance),
        ]}>
        {span.text}
      </Text>
    ));
  const copy = (each: readonly Line[]) =>
    each.map((line, index) => (
      <Text
        // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
        key={index}
        style={kindStyles[line.kind]}>
        {line.marker}
        {spanCopy(line.spans)}
        {index < each.length - 1 ? '\n' : ''}
      </Text>
    ));
  const last = lines.at(-1);
  const queryAt = start - lineStart - (last?.marker.length ?? 0);
  const queryCopy =
    last === undefined ? null : (
      <Text style={kindStyles[last.kind]}>
        {last.marker}
        {spanCopy(cut(last.spans, 0, queryAt + end - start))}
      </Text>
    );
  const above =
    room !== undefined && rows > room.below && room.above > room.below;
  const hidden = {
    accessibilityElementsHidden: true,
    importantForAccessibility: 'no-hide-descendants',
    style: [bodyStyle, styles.bodyCopy],
  } as const;
  return (
    <View style={[styles.bodySuggestions, { top }]}>
      {lines.length > 1 ? (
        <Text {...hidden}>{copy(lines.slice(0, -1))}</Text>
      ) : null}
      <Text
        ref={queryLine}
        onLayout={measure}
        onTextLayout={layoutOf('query')}
        {...hidden}
        style={[hidden.style, lines.length > 1 && styles.bodyCopyLine]}>
        {queryCopy}
      </Text>
      {last === undefined ? null : (
        <>
          <Text
            {...hidden}
            style={[hidden.style, styles.bodyProbe]}
            onTextLayout={layoutOf('line')}>
            <Text style={kindStyles[last.kind]}>
              {last.marker}
              {spanCopy(cut(last.spans, 0, queryAt + 1))}
            </Text>
          </Text>
          <Text
            {...hidden}
            style={[hidden.style, styles.bodyProbe]}
            onTextLayout={layoutOf('at')}>
            <Text style={kindStyles[last.kind]}>
              {spanCopy(cut(last.spans, queryAt, queryAt + 1))}
            </Text>
          </Text>
        </>
      )}
      <View
        style={
          above && room !== undefined
            ? [styles.bodySuggestionsAbove, { bottom: room.lift }]
            : null
        }>
        {children({
          origin: above ? 'bottom left' : 'top left',
          maxHeight:
            room === undefined
              ? undefined
              : Math.max(above ? room.above : room.below, 0),
          onContentHeight: setRows,
          indent,
          width: room?.width,
        })}
      </View>
    </View>
  );
}

// The body's Recipient Suggestions while they show, under the query's line.
function BodyRecipientMenu({
  shown,
  onAccept,
  ...anchor
}: Omit<ComponentProps<typeof BodyMenuAnchor>, 'start' | 'end' | 'children'> & {
  readonly shown: ReturnType<typeof useBodyRecipients>['shown'];
  readonly onAccept: (recipient: Recipient) => void;
}) {
  const { size } = use(ComposerLayoutContext);
  if (shown === undefined) {
    return null;
  }
  return (
    <BodyMenuAnchor
      start={shown.sections.query.start}
      end={shown.sections.query.end}
      {...anchor}>
      {({ origin, maxHeight, onContentHeight, indent, width }) => (
        <SuggestionMenu
          {...shown}
          onAccept={onAccept}
          origin={origin}
          monograms={size === 'compact'}
          style={[
            layoutStyles[size].bodySuggestions,
            // On iPad under the @, kept inside the editor near its trailing edge.
            size === 'regular' && {
              marginLeft:
                padFieldInset +
                Math.max(
                  0,
                  Math.min(
                    indent,
                    (width ?? 0) - 2 * padFieldInset - padBodyMenuWidth,
                  ),
                ),
            },
          ]}
          scroll={{
            query: shown.sections.query.text,
            maxHeight,
            onContentHeight,
          }}
        />
      )}
    </BodyMenuAnchor>
  );
}

export const isSlashInsert = (kind: SlashCommand): kind is SlashInsert =>
  slashInserts.some((each) => each === kind);

// The picker each Insert command opens, as the format bar's Attach File and Insert Image do.
export const slashPickers: Readonly<
  Record<SlashInsert, readonly [PickSource, boolean]>
> = {
  attachFile: ['files', false],
  insertImage: ['photos', true],
};

export const isSlashTool = (kind: SlashCommand): kind is SlashTool =>
  slashToolGroups.some((group) => group.some((each) => each === kind));

// The Slash Command Menu in an editor's body. Typing / as the first non-whitespace character of a
// body block opens its Basic Blocks, Insert commands and the writing `tools` that apply at the
// caret; typing filters them. An empty result, a caret move, leaving the body, Escape or a choice
// closes it, keeping the typed text.
export function useSlashMenu(
  draft: Draft,
  selection: Selection,
  {
    paused,
    pausedNow,
    tools,
  }: Readonly<{
    paused: boolean;
    // Ahead of rendering, as native events can arrive before a pause commits.
    pausedNow: Readonly<{ current: boolean }>;
    tools: (
      body: SemanticDocument,
      query: BodyRecipientQuery,
    ) => readonly SlashTool[];
  }>,
) {
  const { t } = useLocalization();
  const titleOf = useCallback(
    (kind: SlashCommand) => {
      if (kind === 'paragraph') {
        return t('drafts.slashMenu.text');
      }
      if (kind === 'reply') {
        return t('assistance.suggestReply');
      }
      if (isSlashTool(kind)) {
        return t(`assistance.${kind}`);
      }
      return isSlashInsert(kind)
        ? t(`drafts.slashMenu.${kind}`)
        : t(`drafts.blocks.${kind}`);
    },
    [t],
  );
  // Where the / that opened the menu is.
  const [armed, setArmed] = useState<number>();
  const armedNow = useRef(armed);
  // The row a hardware keyboard highlighted, ahead of rendering as native events can arrive
  // before it commits; Return takes the first one without it.
  const [chosen, setChosen] = useState<SlashCommand>();
  const chosenNow = useRef(chosen);
  const choose = useCallback((kind: SlashCommand | undefined) => {
    chosenNow.current = kind;
    setChosen(kind);
  }, []);
  const arm = useCallback(
    (at: number | undefined) => {
      armedNow.current = at;
      setArmed(at);
      choose(undefined);
    },
    [choose],
  );
  const close = useCallback(() => {
    arm(undefined);
  }, [arm]);
  // The query and the blocks it lists for a body and caret, while the menu is open for it.
  const listed = (
    body: SemanticDocument,
    at: Selection,
    start: number | undefined,
  ) => {
    const query = slashQuery(body, at);
    return query === undefined || query.start !== start
      ? undefined
      : {
          query,
          kinds: slashCommands(query.text, titleOf, tools(body, query)),
        };
  };
  const current = paused
    ? undefined
    : listed(textOf(draft.body), selection, armed);
  const kinds = current?.kinds ?? [];
  const active = kinds.find((kind) => kind === chosen) ?? kinds[0];
  const latest = (body: SemanticDocument, at: Selection) =>
    pausedNow.current ? undefined : listed(body, at, armedNow.current);
  return {
    shown:
      current === undefined || active === undefined
        ? undefined
        : {
            query: current.query,
            kinds,
            active,
            // The frames highlight the row Return takes once the person filters or moves.
            highlighted: chosen !== undefined || current.query.text !== '',
          },
    close,
    titleOf,
    // After a body edit inserting `inserted`: typing / first in a block opens the menu, and leaving
    // its query or filtering out every block closes it.
    typed: (next: SemanticDocument, caret: Selection, inserted: string) => {
      const typed = slashQuery(next, caret);
      if (inserted === '/' && typed?.text === '') {
        arm(typed.start);
        AccessibilityInfo.announceForAccessibility(t('drafts.slashMenu.title'));
      } else if (
        typed !== undefined &&
        typed.start === armedNow.current &&
        slashCommands(typed.text, titleOf, tools(next, typed)).length > 0
      ) {
        // The list changed, so the highlight starts over.
        choose(undefined);
      } else if (armedNow.current !== undefined) {
        arm(undefined);
      }
    },
    // A hardware keyboard's Up and Down Arrow move the highlight while two or more show.
    moving: kinds.length > 1,
    // Typed Return and Tab choose the highlighted row while any shows.
    choosing: kinds.length > 0,
    move: (key: string, body: SemanticDocument, at: Selection) => {
      const each = latest(body, at)?.kinds ?? [];
      const chosenKind = chosenNow.current;
      const index =
        chosenKind === undefined ? 0 : Math.max(each.indexOf(chosenKind), 0);
      const step = { ArrowDown: 1, ArrowUp: -1 }[key] ?? 0;
      const next = each[Math.min(Math.max(index + step, 0), each.length - 1)];
      choose(next);
      // Focus stays in the body, so VoiceOver hears the highlighted block.
      if (next !== undefined && next !== chosenKind) {
        AccessibilityInfo.announceForAccessibility(titleOf(next));
      }
    },
    // The query and the row a choice of `kind`, or Return without one, applies for the latest
    // body and caret, while the menu lists it.
    choice: (body: SemanticDocument, at: Selection, kind?: SlashCommand) => {
      const open = latest(body, at);
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
  };
}

// The leading icon of each row: the format bar's heading glyphs, else its SF Symbol; Suggest Reply
// has none there either.
const slashIcons: Readonly<Record<SlashCommand, string>> = {
  paragraph: 'textformat',
  heading1: 'H1',
  heading2: 'H2',
  heading3: 'H3',
  bulleted: 'list.bullet',
  numbered: 'list.number',
  quote: 'text.quote',
  code: 'curlybraces',
  attachFile: 'paperclip',
  insertImage: 'photo.on.rectangle',
  generate: 'square.and.pencil',
  reply: '',
  ...textToolSymbols,
};

// The body's Slash Command Menu while it shows, under the query's line.
function BodySlashMenu({
  shown,
  titleOf,
  onChoose,
  ...anchor
}: Omit<ComponentProps<typeof BodyMenuAnchor>, 'start' | 'end' | 'children'> & {
  readonly shown: ReturnType<typeof useSlashMenu>['shown'];
  readonly titleOf: (kind: SlashCommand) => string;
  readonly onChoose: (kind: SlashCommand) => void;
}) {
  if (shown === undefined) {
    return null;
  }
  return (
    <BodyMenuAnchor
      start={shown.query.start}
      end={shown.query.end}
      {...anchor}>
      {(place) => (
        <SlashMenuPanel
          shown={shown}
          titleOf={titleOf}
          onChoose={onChoose}
          {...place}
        />
      )}
    </BodyMenuAnchor>
  );
}

// The Slash Command Menu as it shows from `origin`: a glass menu of Basic Blocks, then Insert
// commands, then the writing tools in untitled groups, the highlighted row filled.
export function SlashMenuPanel({
  shown,
  titleOf,
  onChoose,
  origin,
  maxHeight,
  onContentHeight,
}: Readonly<{
  shown: NonNullable<ReturnType<typeof useSlashMenu>['shown']>;
  titleOf: (kind: SlashCommand) => string;
  onChoose: (kind: SlashCommand) => void;
  origin: string;
  maxHeight: number | undefined;
  onContentHeight: (height: number) => void;
}>) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { size } = use(ComposerLayoutContext);
  const sized = layoutStyles[size];
  const list = useRef<ScrollViewInstance>(null);
  const rowEnds = useRef(new Map<SlashCommand, number>());
  // Scrolls as far as the highlighted row needs to show, as the highlight moves or its row lays out.
  const reveal = useCallback(
    (end: number | undefined) => {
      if (end !== undefined && maxHeight !== undefined) {
        list.current?.scrollTo({
          y: Math.max(end - maxHeight, 0),
          animated: false,
        });
      }
    },
    [maxHeight],
  );
  const { active } = shown;
  useEffect(() => {
    reveal(rowEnds.current.get(active));
  }, [active, reveal]);
  const compact = size === 'compact';
  return (
    <GlassPanel
      open
      origin={origin}
      cornerRadius={radius.touchMenu}
      style={compact ? styles.slashMenu : sized.bodySuggestions}>
      <ScrollView
        accessibilityLabel={t('drafts.slashMenu.title')}
        keyboardShouldPersistTaps="always"
        ref={list}
        style={{ maxHeight }}
        // A new height, as the keyboard moves, keeps the highlighted row in view.
        onLayout={() => {
          reveal(rowEnds.current.get(shown.active));
        }}
        onContentSizeChange={(_width, height) => {
          onContentHeight(height);
          reveal(rowEnds.current.get(shown.active));
        }}>
        {[
          {
            key: 'blocks',
            title: t('drafts.slashMenu.basicBlocks'),
            kinds: shown.kinds.filter(
              (kind) => !isSlashInsert(kind) && !isSlashTool(kind),
            ),
          },
          {
            key: 'insert',
            title: t('drafts.slashMenu.insert'),
            kinds: shown.kinds.filter(isSlashInsert),
          },
          ...slashToolGroups.map((group) => ({
            key: group[0],
            title: undefined,
            kinds: shown.kinds.filter((kind) =>
              group.some((each) => each === kind),
            ),
          })),
        ]
          .filter((section) => section.kinds.length > 0)
          .map((section, index) => (
            // Rows stay the list's own children, so their layout places the highlight.
            <Fragment key={section.key}>
              {index === 0 ? null : (
                <View
                  style={[
                    styles.slashSeparator,
                    { backgroundColor: colors.separator },
                  ]}
                />
              )}
              {section.title === undefined ? null : (
                <Text
                  style={[
                    styles.suggestionSection,
                    sized.suggestionSection,
                    styles.monogramSection,
                    { color: colors.textSecondary },
                  ]}>
                  {section.title}
                </Text>
              )}
              {section.kinds.map((kind) => {
                const chosen = shown.highlighted && kind === shown.active;
                const filled = chosen && !compact;
                const ink = filled ? colors.accentOnFill : colors.textPrimary;
                const icon = slashIcons[kind];
                const glyph = /^H\d$/u.test(icon);
                let highlight = null;
                if (chosen) {
                  highlight = {
                    backgroundColor: compact
                      ? colors.fillQuiet
                      : colors.accentFill,
                  };
                }
                return (
                  <Pressable
                    key={kind}
                    accessibilityLabel={titleOf(kind)}
                    accessibilityRole="button"
                    accessibilityState={{ selected: chosen }}
                    onLayout={({ nativeEvent: { layout } }) => {
                      const end = layout.y + layout.height;
                      rowEnds.current.set(kind, end);
                      if (kind === shown.active) {
                        reveal(end);
                      }
                    }}
                    onPress={() => {
                      onChoose(kind);
                    }}
                    style={({ pressed }) => [
                      styles.suggestion,
                      styles.slashRow,
                      pressed
                        ? {
                            backgroundColor: colors.accentSelectionSubtle,
                          }
                        : null,
                      highlight,
                    ]}>
                    <View style={styles.slashIcon}>
                      {glyph ? (
                        <Text style={[styles.slashGlyph, { color: ink }]}>
                          {icon}
                        </Text>
                      ) : null}
                      {glyph || icon === '' ? null : (
                        <SFSymbol
                          name={icon}
                          color={ink}
                          size={15}
                        />
                      )}
                    </View>
                    <Text
                      numberOfLines={1}
                      style={[
                        styles.suggestionName,
                        sized.suggestionName,
                        { flex: 1, color: ink },
                      ]}>
                      {titleOf(kind)}
                    </Text>
                  </Pressable>
                );
              })}
            </Fragment>
          ))}
      </ScrollView>
    </GlassPanel>
  );
}

// The body's hardware keys for whichever menu shows, Recipient Suggestions or the Slash Command
// Menu: Up and Down Arrow while either moves, Return and Tab while either chooses, and Escape for the
// Slash Command Menu.
const bodyMenuKeys = (
  recipients: Pick<ReturnType<typeof useBodyRecipients>, 'moving' | 'choosing'>,
  slash: Pick<
    ReturnType<typeof useSlashMenu>,
    'moving' | 'choosing' | 'shown' | 'close'
  >,
) => ({
  moving: recipients.moving || slash.moving,
  choosing: recipients.choosing || slash.choosing,
  handleEscape: slash.shown === undefined ? undefined : slash.close,
});

// In a list, a hardware keyboard's Tab and Shift-Tab indent and outdent its items, unless Tab
// chooses a Recipient Suggestion.
const listTabs = (kind: BlockKind, choosing: boolean) =>
  !choosing && isListKind(kind);

// On iPhone the Draft fills the editor's visible area and Subject, To and Cc follow below it: the
// body, or the space after quoted text, grows until the fields start below the fold, and up to the
// floating pill's space keeps the last attachment clear of the pill. Pressing Send while it waits
// for a recipient scrolls to the fields and focuses the one it waits for.
function useFieldsBelowBody({
  regular,
  pillShown,
  shown,
  blocked,
  saving,
}: {
  readonly regular: boolean;
  readonly pillShown: boolean;
  // The Draft as Send would take it, with its typed entries.
  readonly shown: Draft;
  readonly blocked: SendRefusal | undefined;
  readonly saving: boolean;
}) {
  const [visibleHeight, setVisibleHeight] = useState(0);
  const [fieldsHeight, setFieldsHeight] = useState(0);
  // How tall the scrolled content is.
  const contentHeight = useRef(0);
  const scrollRef = useRef<ScrollViewInstance>(null);
  const toRef = useRef<TextInputInstance>(null);
  const ccRef = useRef<TextInputInstance>(null);
  const bccRef = useRef<TextInputInstance>(null);
  const [revealed, setRevealed] = useState<{
    readonly field: RecipientField;
    readonly entry: string;
  }>();
  const visible = useRef(0);
  const toBlock = useRef<ViewInstance>(null);
  const ccBlock = useRef<ViewInstance>(null);
  const bccBlock = useRef<ViewInstance>(null);
  // The field a blocked Send revealed, scrolled to again as its reason and the keyboard resize the
  // editor, while the Draft is unchanged, the field keeps focus and the person has not scrolled.
  const pending = useRef<{
    readonly field: RecipientField;
    readonly draft: Draft;
  }>(undefined);
  const inputs = { to: toRef, cc: ccRef, bcc: bccRef };
  const blocks = { to: toBlock, cc: ccBlock, bcc: bccBlock };
  // Focus alone leaves a field that already has it where it is: scroll its entry to the top with
  // one 44pt row above it, or further while its reason would end under the floating pill, as far
  // as the content goes.
  const reveal = (field: RecipientField) => {
    const input = inputs[field].current;
    const block = blocks[field].current;
    const content = scrollRef.current?.getInnerViewRef();
    if (
      input === null ||
      block === null ||
      content === null ||
      content === undefined
    ) {
      return;
    }
    input.measureLayout(content, (_x, entryTop) => {
      block.measureLayout(content, (...[, blockTop, , height]) => {
        const shownEnd = visible.current - (pillShown ? pillReserve : 0);
        const y = Math.min(
          entryTop,
          Math.max(entryTop - 44, blockTop + height - shownEnd),
        );
        scrollRef.current?.scrollTo({
          y: Math.max(0, Math.min(y, contentHeight.current - visible.current)),
        });
      });
    });
  };
  const phone = !regular && !ipad;
  const filled = phone && visibleHeight > 0;
  const quoted = shown.quoted !== undefined;
  // The field whose text Send refuses, as useBlockedSend finds it, or To.
  const finished = finishedEntries(shown);
  const waiting =
    phone && !saving && (blocked === 'recipients' || blocked === 'entries')
      ? ((['to', 'cc', 'bcc'] as const).find(
          (field) => entryOf(finished, field) !== '',
        ) ?? 'to')
      : undefined;
  const revealAgain = () => {
    // An edit ends it for good, so Undo back to the Draft does not bring it back.
    if (pending.current?.draft !== shown) {
      pending.current = undefined;
    } else if (inputs[pending.current.field].current?.isFocused() === true) {
      reveal(pending.current.field);
    }
  };
  return {
    scrollRef,
    toRef,
    ccRef,
    bccRef,
    blocks,
    onBlockedPress:
      waiting === undefined
        ? undefined
        : () => {
            pending.current = { field: waiting, draft: shown };
            reveal(waiting);
            inputs[waiting].current?.focus();
            setRevealed({ field: waiting, entry: entryOf(shown, waiting) });
          },
    revealed: (field: RecipientField) =>
      revealed?.field === field ? revealed.entry : undefined,
    measureVisible: (height: number) => {
      visible.current = height;
      setVisibleHeight(height);
      revealAgain();
    },
    measureFields: setFieldsHeight,
    measureContent: (height: number) => {
      contentHeight.current = height;
      revealAgain();
    },
    stopRevealing: () => {
      pending.current = undefined;
    },
    content: filled && {
      minHeight:
        visibleHeight + fieldsHeight + (pillShown ? pillReserve : spacing.s),
    },
    body: filled && !quoted && styles.filling,
    // In a reply the space after the quoted text grows, not the space around the body.
    bodyKeys: filled && quoted && styles.fixed,
    afterQuoted: filled && quoted && styles.filling,
    pillClear: filled && pillShown && styles.pillClear,
  };
}

function Editor({
  initial,
  opening,
  onClose,
  onClosedAfterRemoval,
  onRebind,
  expanded = false,
  onExpand,
}: {
  readonly initial: Draft;
  // The version the editor opens on: `initial`, or the unsaved version a composer recovery record
  // kept.
  readonly opening: Draft;
  readonly onClose: () => void;
  // Closing an empty Draft, discarding one or sending one removes it, which can unmount this editor
  // before it can call `onClose`; the composer closes in its place while it still shows Draft `id`.
  readonly onClosedAfterRemoval: (id: string) => void;
  // Another editor changed this Draft first, so this editor's version is now the copy `id`.
  readonly onRebind: (id: string) => void;
  // Whether the composer takes over the window, and the control that toggles it when offered.
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const store = useDraftStore();
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  // Whether Send's question about files that were not added is open.
  const askingLeftOut = useRef(false);
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  const [history, setHistory] = useState(() => historyOf(opening));
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
  // The version the store holds: the Draft as opened, until Save Draft or Send stores this one.
  const stored = useRef(initial);
  // Another Draft's failed save does not make this editor's unchanged version unsaved.
  const unsaved = useRef(false);
  useLayoutEffect(() => {
    if (savedOf(state)) {
      unsaved.current = false;
    }
  }, [state]);
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
  // A navigation waiting for the answer to Close's question.
  const leaving = useRef<((allowed: boolean) => void) | undefined>(undefined);
  const answerLeave = useCallback((allowed: boolean) => {
    const answer = leaving.current;
    leaving.current = undefined;
    answer?.(allowed);
  }, []);
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
      leaving.current?.(false);
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
  // The field opens with its caret after the body and reports no selection until the caret moves,
  // so a tap there sends none (#1801).
  const [selection, setSelection] = useState<Selection>(() => {
    const end = displayOf(textOf(opening.body)).text.length;
    return { start: end, end };
  });
  // Body text captured for an explicitly requested translation, rewrite or reply suggestion, until
  // its result is applied or the original kept.
  const profile = use(MailAssistanceProfileContext);
  const [captured, setCaptured] = useState<
    CapturedDraftText & { readonly id: number; readonly profile: string }
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
  // The wrapper calls onChange before onChangeText for the same native edit.
  const changedSelection = useRef<Selection | undefined>(undefined);
  // The body text the field reported last, until the editor changes the Draft itself. The field
  // keeps showing it when a render reaches it after further typing.
  const shownBody = useRef<string | undefined>(undefined);
  // Where the editor must place the caret after a change it did not type itself.
  const [placed, setPlaced] = useState<Selection>();
  // Marks toggled at a caret apply to the text typed there next.
  const [typing, setTyping] = useState<readonly Mark[]>();
  const typingNow = useRef(typing);
  const placeTyping = (next: readonly Mark[] | undefined) => {
    typingNow.current = next;
    setTyping(next);
  };
  const [closing, setClosing] = useState<Closing>();
  // Whether Delete Draft and Save Draft show under Close, and whether the last Close showed them.
  const [asking, setAsking] = useState(false);
  const asked = useRef(false);
  // Why the last Send left this Draft here.
  const [refused, setRefused] = useState<SendRefusal>();
  // iPad keeps the format bar at the top; iPhone floats its controls above the keyboard, and its
  // Format panel takes the keyboard's place.
  const layout = use(ComposerLayoutContext);
  const regular = layout.size === 'regular';
  const sized = layoutStyles[layout.size];
  const large = useLargeText();
  const [formatting, setFormatting] = useState(false);
  const hideFormat = () => {
    setFormatting(false);
  };
  // The Format panel takes the pill's place too.
  const pillShown = !regular && !formatting;
  // On iPhone the body's menus end 8pt above the floating pill's 44pt buttons, 10pt off the bottom.
  const menuReserve = pillShown ? 10 + 44 + spacing.s : spacing.s;
  const bodyInput = useRef<TextInputInstance>(null);
  // While Send is pending the editor accepts no edits, so nothing typed then is lost.
  const [sending, setSending] = useState(false);
  // Native callbacks can arrive before the disabled props commit.
  const sendingNow = useRef(false);
  // A control that also waits while Send is pending.
  const lockedUnless = (available: boolean) => sending || !available;
  const outbox = useOutbox();
  const {
    sendReminders,
    profile: draftProfile,
    reminder,
    setRead: setReadReminder,
  } = useDraftReminder(history.present.id, history.present.connection);
  // Which reminder change last failed.
  const [reminderFailed, setReminderFailed] = useState<'set' | 'remove'>();
  // A pending Remove Reminder, which a reminder change waits for.
  const removingReminder = useRef(false);
  const caret = useRef<number | undefined>(undefined);
  const typingField = useRef<string | undefined>(undefined);
  const subjectSelection = useRef<Selection>({ start: 0, end: 0 });
  const subjectCaret = useRef<number | undefined>(undefined);
  const draft = history.present;
  const [closeRecord, journalNow, settleJournal] = useRecoveryJournal(
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
  // Save Drafts in the Inbox can store this editor's version while it stays open.
  const saved = savedOf(state);
  useEffect(() => {
    if (saved) {
      settleJournal();
    }
  }, [saved, settleJournal]);
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  const { linkEditor, generatePrompt } = useOpenPresenters({
    regular,
    assisted: assistance !== undefined,
    profile,
    formatting,
    setFormatting,
  });
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
    paused: sending,
    pausedNow: sendingNow,
  });
  const slashMenu = useSlashMenu(draft, selection, {
    paused: sending,
    pausedNow: sendingNow,
    // The format bar's Writing tools, while it offers them.
    tools: (body, query) =>
      assistance === undefined
        ? []
        : slashTools(body, query, canSuggestReply(draft)),
  });
  const menuKeys = bodyMenuKeys(recipientMenu, slashMenu);
  // Where the body starts, for the Recipient Suggestions under its query.
  const [bodyTop, setBodyTop] = useState(0);
  // The editor's visible area, which those suggestions stay inside, and their placing in it.
  const viewport = useRef<ViewInstance>(null);
  const placeSuggestions = useRef<() => void>(undefined);
  // The key the body's last typed change came from; pasted text reports none.
  const pressed = useRef<string>(undefined);
  // The selection the body's field still reports for a Return or Tab a choice replaced.
  const replaced = useRef<Selection>(undefined);
  const appearance = useAppearance();

  // Set while Discard or Send finishes, which take the Draft as it was then.
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
    shownBody.current = undefined;
    if (!discarded.current) {
      setRefused(undefined);
    }
  }, []);
  const change = (next: Draft, word = false, field?: string) => {
    if (sendingNow.current) {
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
    if (files.length === 0 || discarded.current) {
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
      setPlaced(prepared.selection);
    }
    for (const { asset, file } of prepared.imports) {
      void store.importAsset(asset, file.source, { keep: true });
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
    if (sendingNow.current) {
      return;
    }
    for (const id of ids) {
      void store.cancelImport(id, { removed: true });
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
    if (sendingNow.current) {
      return;
    }
    commitHistory((current) => keepIdentity(step(current)));
    placeTyping(undefined);
    update(historyNow.current.present);
  };
  // Choosing a person for the @ replaces it with the greeting, or in written text the name, and
  // adds a person not yet on the Draft to To, as one edit.
  const chooseRecipient = (recipient: Recipient) => {
    const latest = authored.current;
    const query = recipientMenu.choosable(
      latest,
      selectionNow.current,
      recipient.address,
    );
    if (query === undefined) {
      return;
    }
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
    setPlaced(result.selection);
    AccessibilityInfo.announceForAccessibility(
      recipientMenu.added(recipient, present, inserted),
    );
  };
  // Captures authored text for an explicitly requested translation, text tool, reply suggestion or
  // generated draft.
  const capture = (text: (draft: Draft) => CapturedDraftText) => {
    if (
      sendingNow.current ||
      !lifetime.current.mounted ||
      !assistanceEnabled()
    ) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...text(authored.current),
      id: captureGeneration.current,
      profile,
    };
    captureNow.current = next;
    setCaptured(next);
    setDropped(undefined);
    // On iPad a text tool's review takes the whole window, as Expand does.
    if (isTextTool(next.purpose) && !expanded) {
      onExpand?.();
    }
  };
  const suggestReply = () => {
    if (lifetime.current.mounted) {
      capture((latest) =>
        captureDraftText('reply', latest, selectionNow.current),
      );
    }
  };
  const rewrite = (tool: TextTool) => {
    const at = selectionNow.current;
    if (lifetime.current.mounted && canRewrite(authored.current.body, at)) {
      capture((latest) => captureDraftText(tool, latest, at));
    }
  };
  // Choosing a block in the Slash Command Menu removes its query and sets the caret's block, as one
  // edit, so one Undo restores the text as typed. Choosing an Insert command removes the query and
  // opens its picker, which places an inline image where the query was. Choosing a writing tool
  // removes the query and runs it as the format bar's Writing tools do.
  const chooseBlock = (kind?: SlashCommand) => {
    const latest = authored.current;
    const choice = slashMenu.choice(
      textOf(latest.body),
      selectionNow.current,
      kind,
    );
    if (sendingNow.current || choice === undefined) {
      return;
    }
    const picker = isSlashInsert(choice.kind)
      ? slashPickers[choice.kind]
      : undefined;
    const result =
      isSlashInsert(choice.kind) || isSlashTool(choice.kind)
        ? replaceSelection(textOf(latest.body), choice.query, '')
        : applySlashBlock(textOf(latest.body), choice.query, choice.kind);
    const at = result.selection ?? {
      start: choice.query.start,
      end: choice.query.start,
    };
    slashMenu.close();
    change({ ...latest, body: withText(latest.body, result.document) });
    placeTyping(undefined);
    caret.current = at.start;
    selectionNow.current = at;
    setPlaced(at);
    if (picker !== undefined) {
      void choose(...picker);
    }
    if (choice.kind === 'generate') {
      generatePrompt.open();
    } else if (choice.kind === 'reply') {
      suggestReply();
    } else if (isTextTool(choice.kind)) {
      rewrite(choice.kind);
    }
  };
  // Takes the Recipient Suggestion or command a menu highlights, if one does.
  const chooseHighlighted = (latest: Draft, at: Selection) => {
    const highlighted = recipientMenu.highlighted(latest, at);
    if (highlighted !== undefined) {
      chooseRecipient(highlighted);
      return true;
    }
    if (slashMenu.choice(textOf(latest.body), at) === undefined) {
      return false;
    }
    chooseBlock();
    return true;
  };
  const edit = (text: string) => {
    if (sendingNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const textBefore = displayOf(textOf(latest.body)).text;
    const after = changedSelection.current;
    changedSelection.current = undefined;
    // Including what it replaced, so typing over a selection still counts.
    const inserted = text.slice(
      at.start,
      at.end + text.length - textBefore.length,
    );
    const key = pressed.current;
    pressed.current = undefined;
    // Typed Return and Tab choose the highlighted Recipient Suggestion or block instead of their
    // character.
    const choosing =
      (inserted === '\n' && key === 'Enter') ||
      (inserted === '\t' && key === 'Tab');
    if (choosing && chooseHighlighted(latest, at)) {
      replaced.current = after ?? {
        start: at.start + 1,
        end: at.start + 1,
      };
      return;
    }
    // Forward deletion leaves the caret in place. Backspace moves it, even without a key event.
    const forward =
      at.start === at.end &&
      text.length < textBefore.length &&
      after?.start === at.start &&
      after.end === at.start;
    const result = applyText(textOf(latest.body), text, {
      marks: typingNow.current,
      selection: at,
      shown: shownBody.current,
      ...(forward ? { deletion: 'forward' } : {}),
    });
    // Native selection still uses the field's reported text if it dropped our display.
    const typedTo =
      after?.start ??
      result.selection?.start ??
      at.end + text.length - textBefore.length;
    caret.current = typedTo;
    if (result.literal === undefined) {
      change(
        { ...latest, body: withText(latest.body, result.document) },
        result.typing,
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
    shownBody.current = text;
    if (result.selection !== undefined) {
      selectionNow.current = result.selection;
      setPlaced(result.selection);
    }
    recipientMenu.typed(
      result.document,
      { start: typedTo, end: typedTo },
      inserted,
    );
    slashMenu.typed(
      result.document,
      { start: typedTo, end: typedTo },
      inserted,
    );
  };
  const format = (mark: Mark) => {
    if (sendingNow.current) {
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
  // Replaces exactly the captured text with its reviewed result as one undoable edit. Recipients,
  // the subject, quoted text, attachments and delivery state are left as they are.
  const applyCaptured = (replacement: string) => {
    const latest = authored.current;
    if (
      sendingNow.current ||
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
    setPlaced(result.selection);
  };
  // Applies a template at the caret as one undoable edit; its subject fills only an empty one.
  const insertTemplate = (template: MailTemplate) => {
    if (sendingNow.current) {
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
    setPlaced(applied.edit.selection);
  };
  const closeCaptured = () => {
    if (
      !sendingNow.current &&
      captured !== undefined &&
      captureNow.current === captured
    ) {
      captureNow.current = undefined;
      setCaptured(undefined);
    }
  };
  const block = (kind: BlockKind) => {
    if (sendingNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const result = setBlockKind(textOf(latest.body), at, kind);
    change({ ...latest, body: withText(latest.body, result.document) });
    selectionNow.current = result.selection ?? at;
    setPlaced(result.selection);
  };
  const indent = (direction: IndentDirection) => {
    if (sendingNow.current) {
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
    setPlaced(result.selection);
  };
  const editLink = (link: Link, text: string, href?: string) => {
    if (sendingNow.current) {
      return;
    }
    const latest = authored.current;
    const result = setLink(textOf(latest.body), link, { text, href });
    change({ ...latest, body: withText(latest.body, result.document) });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    setPlaced(result.selection);
  };
  // Entries still being typed become recipients; invalid text keeps the Draft open.
  const finishEntries = () => {
    const latest = authored.current;
    const finished = finishedEntries(latest);
    if (finished !== latest) {
      commitHistory((current) => keepIdentity(record(current, finished)));
      update(finished);
    }
    return finished.entries === undefined;
  };
  // Runs one Close, Save Draft, Delete Draft or Send; `operation` resolves whether the editor may
  // close. One that fails without explaining why offers to try saving again.
  const finish = async (operation: () => Promise<boolean>) => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return false;
    }
    setAsking(false);
    setClosing('saving');
    lifetime.current.finishing += 1;
    let closed = false;
    try {
      closed = await operation();
    } catch {
      // An unexpected storage rejection keeps the composer open and retryable too.
    }
    if (closed) {
      void closeRecord(authored.current.id);
    }
    finishOperation();
    answerLeave(closed);
    if (!lifetime.current.mounted) {
      if (closed) {
        onClosedAfterRemoval(authored.current.id);
      }
    } else if (closed) {
      onClose();
    } else {
      setClosing((current) => (current === 'saving' ? 'blocked' : current));
    }
    return closed;
  };
  // Stores this editor's version; a Draft that changed elsewhere since it was opened becomes a
  // conflicting copy. False when the store declines it, as one moving into another Mail Profile:
  // it stays unstored, so Save Draft tries it again and Close keeps its recovery record.
  const storeShown = () => {
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
  };
  // Stores this editor's version, then saves it.
  const storeAndSave = async () => {
    // Edits accepted while storage saves are stored too before the editor closes.
    do {
      if (!finishEntries()) {
        setClosing('recipients');
        return false;
      }
      const kept = storeShown();
      if (!(await store.save()) || !kept) {
        return false;
      }
      unsaved.current = false;
    } while (authored.current !== stored.current);
    return true;
  };
  const saveDraft = () => finish(storeAndSave);
  // A Draft that Send, Discard or an empty Close removed needs no reminder. `target` reads the
  // Draft id for the store, which removes the one read last; a rebinding after that moves the
  // editor to a conflict copy keeping its own reminder. `forget` runs whatever the operation
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
        const drafts = store.getSnapshot();
        if (drafts.kind === 'ready' && draftOf(drafts, id) === undefined) {
          void sendReminders.cancel(draftProfile, id);
        }
      },
    };
  };
  // Saves the Draft as Save Draft does, keeping it open, then stores its reminder at `dueAt`.
  const remind = async (dueAt: number, timeZone: string) => {
    if (
      discarded.current ||
      lifetime.current.finishing > 0 ||
      removingReminder.current
    ) {
      return;
    }
    if (!finishEntries()) {
      setClosing('recipients');
      return;
    }
    setReminderFailed(undefined);
    lifetime.current.finishing += 1;
    let set: SendReminder | undefined = undefined;
    try {
      if (await storeAndSave()) {
        journalNow();
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
  // Waits for no pending Save Draft, Send or reminder change, so the reminder stored is the one
  // shown.
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
  const discard = () =>
    finish(async () => {
      // Later edits wait: Discard removes the Draft as it was.
      discarded.current = true;
      const cleanup = reminderCleanup();
      const removed = await store
        .discard(cleanup.target, { expected: () => stored.current })
        .catch(() => false);
      cleanup.forget();
      discarded.current = removed;
      if (!removed) {
        setClosing('discard-blocked');
      }
      return removed;
    });
  // Close asks to save or delete changes, including ones a failed Save Draft left unsaved; an
  // empty Draft is removed and an unchanged one closes.
  const closeSheetPalette = useCloseSheetPalette();
  const close = () =>
    finish(async () => {
      if (isEmptyDraft(authored.current) && isEmptyDraft(stored.current)) {
        const cleanup = reminderCleanup();
        const removed = await store
          .discard(cleanup.target, {
            onlyIfEmpty: true,
            expected: () => stored.current,
          })
          .finally(cleanup.forget);
        // Typing while the empty Draft was removed asks rather than closing over it.
        if (!removed || isEmptyDraft(authored.current)) {
          return removed;
        }
      } else if (authored.current === stored.current && !unsaved.current) {
        return true;
      }
      setClosing(undefined);
      // The question takes the place of a palette the sheet showed over it.
      closeSheetPalette();
      setAsking(true);
      asked.current = true;
      return false;
    });
  // Leaving for another destination asks the same question first.
  const navigation = useComposerNavigation();
  const presented = use(ComposerPresentedContext);
  useLayoutEffect(() => {
    if (!presented) {
      return undefined;
    }
    return navigation.register(async () => {
      asked.current = false;
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
      // oxlint-disable-next-line promise/avoid-new -- Navigation waits for Save, Delete or dismissal.
      return new Promise<boolean>((resolve) => {
        leaving.current = resolve;
      });
    });
  });
  useEffect(() => {
    if (!asking && lifetime.current.finishing === 0) {
      answerLeave(false);
    }
  }, [answerLeave, asking]);
  const paletteHeader = usePaletteHeader();
  const sheetParts = sheetStyles(use(InSheet));
  const closeAnchor = useRef<ViewInstance>(null);
  // Stores and admits the Draft as this editor shows it to the Outbox, then closes; a refusal
  // keeps it open. Send Now gives a `delay` of 0, with no Undo Send Window.
  const send = (delay?: number) =>
    finish(async () => {
      if (!finishEntries()) {
        setClosing(undefined);
        setRefused('entries');
        return false;
      }
      const previous = authored.current;
      setRefused(undefined);
      sendingNow.current = true;
      setSending(true);
      captureNow.current = undefined;
      setCaptured(undefined);
      setDropped(undefined);
      // As for Discard, later edits wait: the version shown at Send is the one sent.
      discarded.current = true;
      const kept = storeShown();
      const cleanup = reminderCleanup();
      const baseline = () => {
        const id = cleanup.target();
        return previous.id === id
          ? previous
          : { ...previous, id, conflict: true as const };
      };
      let refusal: SendRefusal | undefined = 'storage';
      try {
        refusal = await outbox.send(baseline, undefined, delay);
        // A refused Send still stored the version shown, unless the store declined it, so its
        // record goes once that is saved.
        if (refusal !== undefined && (await store.save()) && kept) {
          unsaved.current = false;
          journalNow();
        }
      } catch {
        // An unexpected rejection keeps the Draft open to send again.
      }
      cleanup.forget();
      if (refusal === undefined) {
        return true;
      }
      sendingNow.current = false;
      discarded.current = false;
      setClosing(undefined);
      setRefused(refusal);
      setSending(false);
      return false;
    });
  // Send and Send Now first ask, once at a time, to leave out the files that were not added, then
  // remove them as one edit and send; files that changed meanwhile leave the Draft open to ask
  // again.
  const sendAsking = async (delay?: number) => {
    if (askingLeftOut.current) {
      return;
    }
    const latest = authored.current;
    const question = leftOutQuestion(t, latest, running);
    if (question !== undefined) {
      const files = assetStates(latest);
      askingLeftOut.current = true;
      const agreed = await askLeftOut(question);
      askingLeftOut.current = false;
      if (
        !agreed ||
        !lifetime.current.mounted ||
        assetStates(authored.current) !== files
      ) {
        return;
      }
      removeAssets(question.ids);
    }
    await send(delay);
  };
  // On iPad a reply docks beneath its message, titled by its kind; a new message is a card.
  const presentation = presentationOf(regular, draft);
  const docked = presentation === 'docked';
  const parts = partStyles[presentation];
  const { title, titleLabel } = composerTitle(t, draft, docked || !regular);
  const active = typing ?? marksAt(textOf(draft.body), selection);
  const kind = blockKindAt(textOf(draft.body), selection.start);
  const indents = listIndentAt(textOf(draft.body), selection);
  const copiesShown = copiesShownOf(draft);
  // An edit in Cc or Bcc keeps both shown for the Draft, even once they are empty.
  const changeCopies = (next: Draft, word: boolean, field: string) => {
    change({ ...next, copies: true }, word, field);
  };
  const blocked = useBlockedSend({ shown: history.present, draft, docked });
  const {
    scrollRef,
    toRef,
    ccRef,
    bccRef,
    blocks,
    onBlockedPress,
    revealed,
    ...below
  } = useFieldsBelowBody({
    regular,
    pillShown,
    shown: history.present,
    blocked: blocked.blocked,
    saving: closing === 'saving',
  });

  const sender = (
    <SendingMailbox
      draft={draft}
      editable={!sending}
      onChange={(mailbox) => {
        change(withSender(authored.current, mailbox));
      }}
    />
  );
  const senderPlace = placeSender({
    sender,
    draft,
    presentation,
    large,
    rowStyle: sheetParts.fromRow,
  });
  // Send: a tap sends, and a long press opens its menu of Send Now and Remind Me to Send….
  const sendControl = (titled: boolean) => (
    <SendMenu
      popover={regular}
      stored={reminder?.dueAt}
      disabled={closing === 'saving'}
      sendNow={sendNowOf(
        blocked.blocked,
        closing === 'saving',
        addingAsset(draft, running),
      )}
      onSendNow={() => {
        void sendAsking(0);
      }}
      onRemind={(dueAt, timeZone) => {
        void remind(dueAt, timeZone);
      }}>
      <SendButton
        titled={titled}
        disabled={closing === 'saving' || blocked.blocked !== undefined}
        hint={blocked.reason}
        onPress={() => {
          void sendAsking();
        }}
        onBlockedPress={onBlockedPress}
      />
    </SendMenu>
  );
  const discardAsked = () => {
    if (!sendingNow.current && lifetime.current.finishing === 0) {
      setClosing('discard');
    }
  };
  const writingTools = (
    <WritingTools
      assistance={assistance !== undefined}
      translation={translation !== undefined}
      reply={canSuggestReply(draft)}
      body={draft.body}
      selection={selection}
      sending={sending}
      popover={regular}
      prompt={generatePrompt}
      onGenerate={(prompt) => {
        if (lifetime.current.mounted) {
          capture((latest) =>
            capturePrompt(latest, selectionNow.current, prompt),
          );
        }
      }}
      onTextTool={rewrite}
      onTranslate={() => {
        const at = selectionNow.current;
        const body = textOf(authored.current.body);
        const text = selectedText(body, at, translationInputLimit + 1);
        if (
          sendingNow.current ||
          !lifetime.current.mounted ||
          !hasTranslatableText(text)
        ) {
          return;
        }
        capture((latest) => captureDraftText('translate', latest, at));
      }}
      onReply={suggestReply}
    />
  );
  const templates = useTemplateItems({
    connection: draft.connection,
    getDraft,
    onInsert: insertTemplate,
  });
  const travels = [
    {
      key: 'undo',
      title: t('drafts.undo'),
      symbol: 'arrow.uturn.backward',
      disabled: lockedUnless(history.past.length > 0),
      run: () => {
        travel(undo);
      },
    },
    {
      key: 'redo',
      title: t('drafts.redo'),
      symbol: 'arrow.uturn.forward',
      disabled: lockedUnless(history.future.length > 0),
      run: () => {
        travel(redo);
      },
    },
  ];
  const assets = assetPickers.map(([label, from, inline, icon]) => ({
    key: label,
    title: t(label),
    symbol: icon,
    disabled: sending,
    run: () => {
      void choose(from, inline);
    },
  }));
  const templateSections = [
    {
      items: [
        {
          key: 'heading',
          title: t('drafts.templates.insert'),
          symbol: '',
          disabled: true,
          run: () => undefined,
        },
        ...templates.templates,
      ],
    },
    { items: [templates.save] },
  ];
  const formatBar = (
    <FormatBar
      active={active}
      kind={kind}
      indents={indents}
      disabled={sending}
      onBlock={block}
      onIndent={indent}
      onMark={format}
      style={parts.formatBar}>
      {(lists) => (
        <>
          <LinkEditor
            state={linkEditor}
            disabled={sending}
            link={editableLinkAt(textOf(draft.body), selection)}
            popover
            {...(lists === undefined
              ? {}
              : {
                  renderMenu: (link) => (
                    <OverflowMenu
                      accessibilityLabel={t('drafts.moreLists')}
                      disabled={sending}
                      sections={[
                        { items: [...lists, link] },
                        { items: travels },
                      ]}
                    />
                  ),
                })}
            onChange={editLink}
          />
          {lists === undefined ? (
            <>
              <View
                style={[styles.divider, { backgroundColor: colors.separator }]}
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
          <View style={styles.grow} />
          {writingTools}
          <View
            style={[styles.divider, { backgroundColor: colors.separator }]}
          />
          {assets.slice(0, lists === undefined ? undefined : 1).map((item) => (
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
          {lists === undefined ? (
            <MenuButton
              accessibilityLabel={t('drafts.templates.menu')}
              disabled={sending}
              sections={templateSections}
              style={styles.menuControl}>
              <SFSymbol
                name="doc.on.doc"
                size={scaledToolbar.symbol}
                color={colors.textPrimary}
              />
            </MenuButton>
          ) : (
            <OverflowMenu
              accessibilityLabel={t('drafts.moreFiles')}
              disabled={sending}
              sections={[
                { items: assets.slice(1) },
                {
                  items: [
                    {
                      title: t('drafts.templates.menu'),
                      symbol: 'doc.on.doc',
                      sections: templateSections,
                    },
                  ],
                },
              ]}
            />
          )}
        </>
      )}
    </FormatBar>
  );
  // iPhone's Format and Attach controls in one glass pill, with Writing tools beside it.
  const pill = (
    <View
      collapsable={!iphone}
      pointerEvents="box-none"
      style={styles.pill}>
      <GlassGroup style={[styles.pillGroup, styles.formatPill]}>
        <ToolbarButton
          disabled={sending}
          icon="textformat"
          label={t('drafts.format')}
          onPress={() => {
            Keyboard.dismiss();
            setFormatting(true);
          }}
        />
        <MenuButton
          accessibilityLabel={t('drafts.assets.toolbar')}
          alignMenuToRowEnd={iphone}
          disabled={sending}
          sections={[
            {
              items: assetPickers.map(([label, from, inline, icon]) => ({
                key: label,
                title: t(label),
                // The paperclip opens this menu, so its Attach File row shows a document.
                symbol: from === 'files' ? 'doc' : icon,
                run: () => {
                  void choose(from, inline);
                },
              })),
            },
            {
              items: [
                {
                  title: t('drafts.assets.insertTemplate'),
                  symbol: 'doc.on.doc',
                  sections: [
                    { items: templates.templates },
                    { items: [templates.save] },
                  ],
                },
              ],
            },
          ]}
          style={styles.menuControl}>
          <SFSymbol
            name="paperclip"
            size={20}
            color={colors.textPrimary}
          />
        </MenuButton>
      </GlassGroup>
      {writingTools}
    </View>
  );

  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <KeyboardAvoidingView
        behavior="padding"
        enabled={layout.avoidKeyboard}
        keyboardVerticalOffset={layout.top}
        style={styles.fill}>
        {/* The header opens the Command Palette by a downward swipe, as other screens' do. */}
        <View
          style={[styles.header, headerStyles[presentation], sheetParts.header]}
          {...paletteHeader.swipe}>
          <CloseButton
            disabled={closing === 'saving'}
            expanded={asking}
            anchor={closeAnchor}
            onPress={() => {
              if (asking) {
                setAsking(false);
              } else {
                void close();
              }
            }}
          />
          {/* The title's Open Command Palette action makes it a control, so its accessible
              element takes the header row's 44pt height rather than the text's. */}
          <View
            accessible
            accessibilityLabel={titleLabel}
            accessibilityRole="header"
            style={[styles.grow, styles.titleTarget]}
            {...paletteHeader.action}>
            <Text
              numberOfLines={1}
              style={[
                styles.title,
                titleStyles[presentation],
                sheetParts.title,
                { color: colors.textPrimary },
              ]}>
              {title}
            </Text>
          </View>
          <HeaderControls
            presentation={presentation}
            sender={senderPlace.header}
            expanded={expanded}
            onExpand={onExpand}
            discardDisabled={lockedUnless(closing !== 'saving')}
            onDiscard={discardAsked}
            send={sendControl}
          />
        </View>
        <CloseQuestion
          open={asking}
          anchor={closeAnchor}
          onDelete={() => {
            void discard();
          }}
          onSave={() => {
            void saveDraft();
          }}
          onCancel={() => {
            setAsking(false);
          }}
        />
        {senderPlace.row}
        {regular ? formatBar : null}
        <View
          ref={viewport}
          onLayout={({ nativeEvent }) => {
            below.measureVisible(nativeEvent.layout.height);
            placeSuggestions.current?.();
          }}
          style={styles.fill}>
          <ScrollView
            ref={scrollRef}
            onContentSizeChange={(_width, height) => {
              below.measureContent(height);
            }}
            onScrollBeginDrag={() => {
              below.stopRevealing();
            }}
            onScroll={() => placeSuggestions.current?.()}
            scrollEventThrottle={16}
            contentContainerStyle={[
              styles.content,
              sized.content,
              parts.content,
              pillShown && styles.pillInset,
              below.content,
            ]}
            keyboardDismissMode="interactive"
            keyboardShouldPersistTaps="handled">
            <ComposerNotices
              closing={closing}
              draft={draft}
              blocked={blocked.notice}
              refused={refused}
              signIn={senderPlace.signInNotice}
              onClose={() => {
                void saveDraft();
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
              popover={regular}
              disabled={lockedUnless(closing !== 'saving')}
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
                  onApply={applyCaptured}
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
            <ArrowKeys
              style={[styles.bodyKeys, below.bodyKeys]}
              enabled={menuKeys.moving}
              onArrow={(key) => {
                if (slashMenu.moving) {
                  slashMenu.move(
                    key,
                    textOf(authored.current.body),
                    selectionNow.current,
                  );
                } else {
                  recipientMenu.move(
                    key,
                    authored.current,
                    selectionNow.current,
                  );
                }
              }}
              tabs={listTabs(kind, menuKeys.choosing)}
              onEscape={menuKeys.handleEscape}
              onTab={(shift) => {
                indent(shift ? 'outdent' : 'indent');
              }}
              onLayout={({ nativeEvent }) => {
                setBodyTop(nativeEvent.layout.y);
              }}>
              <TextInput
                ref={bodyInput}
                accessibilityLabel={t('drafts.body')}
                editable={!sending}
                accessibilityState={{ disabled: sending }}
                multiline
                onBlur={() => {
                  recipientMenu.close();
                  slashMenu.close();
                }}
                onChange={({ nativeEvent }) => {
                  changedSelection.current = nativeEvent.selection;
                }}
                onChangeText={edit}
                onKeyPress={({ nativeEvent }) => {
                  pressed.current = nativeEvent.key;
                }}
                onSelectionChange={({ nativeEvent }) => {
                  const next = nativeEvent.selection;
                  // The field reports where its Return or Tab left the caret after a choice placed it
                  // in the greeting; the greeting's place stands.
                  const stale = replaced.current;
                  replaced.current = undefined;
                  if (stale?.start === next.start && stale.end === next.end) {
                    return;
                  }
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
                scrollEnabled={false}
                selection={placed}
                style={[
                  styles.body,
                  sized.body,
                  parts.body,
                  below.body,
                  { color: colors.textPrimary },
                ]}
                textAlignVertical="top">
                {display.lines.map((line, index) => (
                  <Text
                    // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
                    key={index}
                    style={[
                      kindStyles[line.kind],
                      line.kind === 'quote'
                        ? { color: colors.textSecondary }
                        : null,
                      line.align === undefined
                        ? null
                        : { textAlign: line.align },
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
            </ArrowKeys>
            <BodyRecipientMenu
              shown={recipientMenu.shown}
              display={display}
              top={bodyTop}
              bodyStyle={[styles.body, sized.body, parts.body]}
              viewport={viewport}
              placeRef={placeSuggestions}
              reserve={menuReserve}
              onAccept={chooseRecipient}
            />
            <BodySlashMenu
              shown={slashMenu.shown}
              titleOf={slashMenu.titleOf}
              display={display}
              top={bodyTop}
              bodyStyle={[styles.body, sized.body, parts.body]}
              viewport={viewport}
              placeRef={placeSuggestions}
              reserve={menuReserve}
              onChoose={chooseBlock}
            />
            {draft.quoted === undefined ? null : (
              <QuotedText quoted={draft.quoted} />
            )}
            <View style={below.afterQuoted} />
            <DraftAssets
              draft={draft}
              editable={!sending}
              onCancel={(id) => {
                if (!sendingNow.current) {
                  void store.cancelImport(id);
                }
              }}
              onRemove={removeAsset}
              onResize={resizeAsset}
            />
            <View style={below.pillClear} />
            <View
              onLayout={({ nativeEvent }) => {
                below.measureFields(nativeEvent.layout.height);
              }}
              style={[styles.fields, sized.fields]}>
              <View
                style={[
                  styles.field,
                  sized.field,
                  { borderTopColor: colors.separator },
                ]}>
                <FieldLabel>{`${t('drafts.subject')}:`}</FieldLabel>
                <TextInput
                  accessibilityLabel={t('drafts.subject')}
                  editable={!sending}
                  accessibilityState={{ disabled: sending }}
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
                    const typed =
                      subject[subjectSelection.current.start] ?? ' ';
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
                      commitHistory((current) => ({
                        ...current,
                        typing: false,
                      }));
                    }
                    subjectCaret.current = undefined;
                    subjectSelection.current = next;
                  }}
                  hitSlop={fieldSlop[layout.size]}
                  // iPad's Subject label already names the empty field.
                  placeholder={regular ? undefined : t('drafts.subject')}
                  placeholderTextColor={colors.textSecondary}
                  style={[
                    styles.input,
                    sized.input,
                    { color: colors.textPrimary },
                  ]}
                  value={draft.subject}
                />
              </View>
              <Recipients
                draft={draft}
                getDraft={getDraft}
                editable={!sending}
                ref={toRef}
                block={blocks.to}
                revealed={revealed('to')}
                field="to"
                required={blocked.blocked === 'recipients' && !docked}
                onChange={change}
                onCaretMove={breakTyping}
                trailing={
                  copiesShown ? undefined : (
                    <Action
                      variant="composer"
                      disabled={sending}
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
                    editable={!sending}
                    ref={ccRef}
                    block={blocks.cc}
                    revealed={revealed('cc')}
                    field="cc"
                    onChange={changeCopies}
                    onCaretMove={breakTyping}
                  />
                  <Recipients
                    draft={draft}
                    getDraft={getDraft}
                    editable={!sending}
                    ref={bccRef}
                    block={blocks.bcc}
                    revealed={revealed('bcc')}
                    field="bcc"
                    onChange={changeCopies}
                    onCaretMove={breakTyping}
                  />
                </>
              ) : null}
            </View>
          </ScrollView>
          {pillShown ? pill : null}
        </View>
        {docked ? (
          <ReplyFooter
            draft={draft}
            sender={sender}
            send={sendControl(true)}
            reason={blocked.line}
          />
        ) : null}
        {regular ? null : (
          <FormatPanel
            open={formatting}
            active={active}
            kind={kind}
            link={editableLinkAt(textOf(draft.body), selection)}
            linkEditor={linkEditor}
            undo={history.past.length > 0}
            redo={history.future.length > 0}
            disabled={sending}
            onUndo={() => {
              travel(undo);
            }}
            onRedo={() => {
              travel(redo);
            }}
            onBlock={block}
            indents={indents}
            onIndent={indent}
            onMark={format}
            onLink={editLink}
            onClose={() => {
              setFormatting(false);
              bodyInput.current?.focus();
            }}
            onHide={hideFormat}
          />
        )}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

// A composer whose Draft is loading or cannot open. It keeps the palette entry the editor's
// header has, and leaving closes it as its Close does, which the iPhone sheet's swipe asks.
function ComposerFallback({
  kind,
  onClose,
}: {
  readonly kind: DraftsState['kind'];
  readonly onClose: () => void;
}) {
  const store = useDraftStore();
  const colors = usePalette();
  const { t } = useLocalization();
  const paletteHeader = usePaletteHeader();
  const navigation = useComposerNavigation();
  useLayoutEffect(() =>
    navigation.register(() => {
      onClose();
      return Promise.resolve(true);
    }),
  );
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <View
        style={styles.header}
        {...paletteHeader.swipe}>
        <CloseButton onPress={onClose} />
        <View style={styles.grow} />
        <CommandInput />
      </View>
      <View style={styles.alerts}>
        {kind === 'loading' ? (
          <ActivityIndicator
            accessible
            accessibilityLabel={t('drafts.loading')}
            {...paletteHeader.action}
          />
        ) : (
          <Alert
            message={
              kind === 'locked'
                ? t('drafts.listLocked')
                : t('drafts.unavailable')
            }
            actions={paletteHeader.action}>
            {kind === 'locked' || kind === 'failed' ? (
              <Button
                size="compact"
                label={t('common.retry')}
                onPress={() => {
                  void store.load();
                }}
              />
            ) : null}
          </Alert>
        )}
      </View>
    </SafeAreaView>
  );
}

// Opens a Draft directly for editing; it has no read-only presentation.
export function Composer({
  id,
  recovered,
  onClose,
  onRebind,
  expanded,
  onExpand,
}: {
  readonly id: string;
  // The composer recovery record of Draft `id` to open on instead.
  readonly recovered?: Recovered | undefined;
  readonly onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  readonly onRebind: (id: string) => void;
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const state = useDrafts();
  const draft = draftOf(state, id);
  // The editor stays mounted when it moves to its own copy, and remounts for another Draft. It
  // also outlives removal of its stored Draft, keeping its edits for Save Draft, but not a change
  // of Product Account, which leaves the Drafts no longer ready.
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
  // The Draft this composer shows while it is mounted. An editor that finishes closing after its
  // Draft was removed closes the composer only if it still shows that Draft, so leaving it or
  // opening another Draft meanwhile stays as it is.
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
  const opened =
    editor.followed === id && state.kind === 'ready' ? editor.opened : draft;
  const restoring =
    recovered?.version.id === editor.key ? recovered : undefined;
  if (opened !== undefined) {
    return (
      <Editor
        key={editor.key}
        initial={restoring?.base ?? opened}
        opening={restoring?.version ?? opened}
        expanded={expanded}
        onClose={onClose}
        onClosedAfterRemoval={closedAfterRemoval}
        onExpand={onExpand}
        onRebind={rebind}
      />
    );
  }
  return (
    <ComposerFallback
      kind={state.kind}
      onClose={onClose}
    />
  );
}

// The evaluation editor composes the same layout around its own body.
export { styles as composerStyles };
