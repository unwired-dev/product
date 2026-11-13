import type { Translate } from '@private-email/localization';
import type {
  CapturedDraftText,
  DraftTextPurpose,
  NativeAssistance,
  TextTool,
} from '@private-email/mail-core/assistance';
import type {
  AssetPreview,
  Draft,
  PickedFile,
  PickSource,
  Recipient,
  RecipientField,
  RecipientNotice,
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
  addRecipients,
  draftOf,
  entryOf,
  isEmptyDraft,
  recipientLabel,
  draftSummary,
  profileOf,
  sendingMailboxes,
  pickLimit,
  recipientSuggestions,
  sendingStateOf,
  unsendableAssets,
  prepareFiles,
  withAsset,
  withSender,
} from '@private-email/mail-core/drafts';
import { applyTemplate } from '@private-email/mail-core/mail-templates';
import { inboxMessages } from '@private-email/mail-core/mailboxes';
import {
  applyText,
  blockKindAt,
  displayOf,
  formatStyleOf,
  historyOf,
  imageCharacter,
  imagesOf,
  editableLinkAt,
  marksAt,
  clip,
  previewOf,
  record,
  redo,
  replaceSelection,
  selectedText,
  setBlockKind,
  setLink,
  toggled,
  toggleMark,
  undo,
  withoutImage,
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
  processColor,
  useColorScheme,
} from 'react-native';

import type { PopUpItem } from './composer-controls.tsx';

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
import { useAllMailboxes } from './mailbox-list.ts';
import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useLeaveComposer,
  useMailTemplates,
  useOutbox,
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
const fieldInset = 24;
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
  const preview = previewOf(draft.body);
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

export function Recipients({
  draft,
  getDraft,
  field,
  onChange,
  onCaretMove,
  editable,
  trailing,
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly field: RecipientField;
  readonly editable: boolean;
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
  const contacts = useContactAddresses(entering && editable);
  const name = t(`drafts.fields.${field}`);
  // Senders of the mail held on this device for the Draft's Mail Profile, never another Profile's,
  // then Apple Contacts not already suggested; its own addresses are not suggested.
  const sections = useMemo(() => {
    if (!entering || !editable || dismissed) {
      return { recent: [], contacts: [] };
    }
    const connections = account?.mailboxes ?? [];
    const profile = profileOf(draft.connection, connections);
    // Including connections awaiting authorization, which hold no mail here.
    const excluded = connections.flatMap((mailbox) =>
      mailbox.profile === profile ? [mailbox.address] : [],
    );
    const recent = recipientSuggestions(draft, field, {
      correspondents: inboxMessages(
        held.filter((mailbox) => mailbox.profile === profile),
        { profile },
      ).map(({ message }) => message),
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
  return (
    <View>
      {suggestions.length === 0 ? null : (
        <View
          accessibilityLabel={t('drafts.suggestions.title')}
          style={[
            styles.suggestions,
            { boxShadow: colors.macMenuGlassShadow },
          ]}>
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
                  const chosen = recipient === suggestions[active];
                  const primary = chosen
                    ? colors.accentOnFill
                    : colors.textPrimary;
                  const secondary = chosen
                    ? colors.accentOnFill
                    : colors.textSecondary;
                  return (
                    <Pressable
                      key={recipient.address}
                      accessibilityLabel={
                        recipient.name === undefined
                          ? recipient.address
                          : t('drafts.suggestions.named', {
                              name: recipient.name,
                              address: recipient.address,
                            })
                      }
                      accessibilityRole="button"
                      accessibilityState={{ selected: chosen }}
                      // The field keeps focus, so typing continues after a click.
                      focusable={false}
                      onPress={() => {
                        accept(recipient);
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
                    </Pressable>
                  );
                })}
              </Fragment>
            ),
          )}
        </View>
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
      {notice === undefined ? null : (
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

function AssetRow({
  asset,
  editable,
  inline,
  running,
  check,
  onRemove,
  onCancel,
  onConvert,
  onPreview,
}: {
  readonly asset: Asset;
  readonly inline: boolean;
  readonly running: boolean;
  readonly editable: boolean;
  readonly check: SendCheck | undefined;
  readonly onRemove: (id: string) => void;
  readonly onCancel: (id: string) => void;
  readonly onConvert?: ((id: string) => void) | undefined;
  // An editor that shows Inline Images itself receives each verified thumbnail.
  readonly onPreview?: ((id: string, uri: string | null) => void) | undefined;
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
  const toAttachment = inline ? 'toAttachment' : 'toInline';
  // An editor that converts offers it, with Remove, from the chip's context menu.
  const convertible =
    onConvert !== undefined && (inline || asset.type.startsWith('image/'));
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
        {...(convertible && editable
          ? {
              accessibilityActions: [
                {
                  name: 'convert',
                  label: t(`drafts.assets.${toAttachment}Label`, {
                    name: asset.name,
                  }),
                },
              ],
              onAccessibilityAction: () => {
                onConvert?.(asset.id);
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
  return convertible && editable ? (
    <ContextMenu
      sections={[
        {
          items: [
            {
              key: `convert:${asset.id}`,
              title: t(`drafts.assets.${toAttachment}`),
              symbol: inline ? 'paperclip' : 'photo',
              run: () => {
                onConvert?.(asset.id);
              },
            },
            {
              key: `remove:${asset.id}`,
              title: t('drafts.assets.remove'),
              symbol: 'trash',
              destructive: true,
              run: () => {
                onRemove(asset.id);
              },
            },
          ],
        },
      ]}>
      {chip}
    </ContextMenu>
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
}) {
  const store = useDraftStore();
  const { t } = useLocalization();
  const running = useSyncExternalStore(store.subscribe, store.getImports);
  const attachments = draft.attachments ?? [];
  const images = [
    ...new Map(
      [
        ...imagesOf(draft.body),
        ...(draft.quoted === undefined ? [] : imagesOf(draft.quoted)),
      ].map((asset) => [asset.id, asset]),
    ).values(),
  ];
  if (attachments.length + images.length === 0) {
    return null;
  }
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
                      draft.body,
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

// Why the last Send left the Draft in the composer, if it did. A message sent through an IMAP
// connection's mail server or Microsoft is not limited by Gmail.
const tooLarge = {
  gmail: 'drafts.sendRefused.too-large',
  imap: 'drafts.sendRefused.too-large_imap',
  'microsoft-graph': 'drafts.sendRefused.too-large_microsoft',
} as const satisfies Readonly<Record<MailProvider, string>>;
function SendRefusalNotice({
  refused,
  connection,
}: {
  readonly refused: SendRefusal | undefined;
  readonly connection: string;
}) {
  const { t } = useLocalization();
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === connection,
  )?.provider;
  return refused === undefined ? null : (
    <Alert
      outcome
      message={t(
        refused === 'too-large'
          ? tooLarge[provider ?? 'gmail']
          : `drafts.sendRefused.${refused}`,
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
  onClose,
  onDiscard,
  onKeepEditing,
}: {
  readonly closing: Closing | undefined;
  readonly draft: Draft;
  readonly refused: SendRefusal | undefined;
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
    const { subject, body } = getDraft();
    const owner = profile;
    question.current?.retire();
    if (imagesOf(body).length > 0) {
      notSaved(t('drafts.templates.hasImages'));
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

// How long after an edit its composer recovery record is written: the most typing that ending the
// app can lose (ADR 0077).
const journalDelay = 2000;

// Keeps the editor's unsaved version, which `unsavedVersion` returns, in a composer recovery record
// a few seconds after each `edited` change and when the app returns to the foreground, retrying a
// record locked storage refused. The records it wrote go once the version is unchanged again. The
// first returned function closes the journal, removing those records and that of Draft `id` the
// editor closes on, which another editor's journal may have written; it resolves once they are
// gone, so Quit waits for them. The second journals at once, as after a save that keeps the editor
// open.
function useRecoveryJournal(
  edited: unknown,
  unsavedVersion: () => Draft | undefined,
  editor: (id: string) => void,
) {
  const store = useDraftStore();
  const journaled = useRef(new Set<string>());
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const closed = useRef(false);
  const forget = useCallback(() => {
    const removals = [...journaled.current].map((id) =>
      store.forget(id, editor),
    );
    journaled.current.clear();
    return Promise.allSettled(removals);
  }, [editor, store]);
  const write = useCallback(() => {
    clearTimeout(timer.current);
    timer.current = undefined;
    const version = closed.current ? undefined : unsavedVersion();
    if (version === undefined) {
      void forget();
      return;
    }
    journaled.current.add(version.id);
    void store.journal(version);
  }, [forget, store, unsavedVersion]);
  const seen = useRef(edited);
  useEffect(() => {
    if (seen.current === edited) {
      return;
    }
    seen.current = edited;
    if (timer.current === undefined && !closed.current) {
      timer.current = setTimeout(write, journalDelay);
    }
  });
  useEffect(() => {
    const subscription = AppState.addEventListener('change', (next) => {
      if (next === 'active' && !closed.current) {
        write();
      }
    });
    return () => {
      subscription.remove();
      clearTimeout(timer.current);
      timer.current = undefined;
    };
  }, [write]);
  const close = useCallback(
    (id: string) => {
      closed.current = true;
      clearTimeout(timer.current);
      timer.current = undefined;
      journaled.current.add(id);
      return forget();
    },
    [forget],
  );
  return [close, write] as const;
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

function Editor({
  initial,
  onClose,
  onClosedAfterRemoval,
  onRebind,
  onExpand,
  renderToolbar,
}: {
  readonly initial: Draft;
  readonly onClose: () => void;
  readonly onClosedAfterRemoval: (id: string) => void;
  // Another editor changed this Draft first, so this editor's version is now the copy `id`.
  readonly onRebind: (id: string) => void;
  // Moves the saved Draft into its own window, when offered.
  readonly onExpand?: ((id: string) => void) | undefined;
  readonly renderToolbar?: Toolbar | undefined;
}) {
  const store = useDraftStore();
  const colors = usePalette();
  const { t } = useLocalization();
  const [history, setHistory] = useState(() => historyOf(initial));
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
  const authored = useRef(initial);
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
  // The text tool whose result a body edit dropped, until Rewrite again or Close.
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
  const sendReminders = useSendReminders();
  // The Mail Profile owning this Draft, and so its Send Reminder.
  const draftProfile = profileOf(
    history.present.connection,
    use(AccountContext)?.mailboxes ?? [],
  );
  // The Draft's stored Send Reminder, once read, and which reminder change last failed.
  const [readReminder, setReadReminder] = useState<SendReminder>();
  const [reminderFailed, setReminderFailed] = useState<'set' | 'remove'>();
  const draftID = history.present.id;
  const reminder = reminderOf(readReminder, draftID, draftProfile);
  useEffect(() => {
    let current = true;
    const read = async () => {
      const listed = await sendReminders.reminders(draftProfile);
      if (current && listed !== undefined) {
        setReadReminder(listed.find((each) => each.draft === draftID));
      }
    };
    void read();
    return () => {
      current = false;
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
    useCallback(
      () =>
        authored.current !== stored.current || unsaved.current
          ? authored.current
          : undefined,
      [],
    ),
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
  const display = displayOf(draft.body);
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
  // conflicting copy.
  const storeShown = useCallback(() => {
    if (authored.current !== stored.current) {
      void store.update(authored.current, stored.current, rebind);
      stored.current = authored.current;
      unsaved.current = true;
    }
  }, [rebind, store]);
  const storeAndSave = useCallback(async () => {
    storeShown();
    const saved = await store.save();
    if (saved) {
      unsaved.current = false;
    }
    return saved;
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
      setPlaced(prepared.selection);
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
  const removeAsset = (id: string) => {
    if (pausedNow.current) {
      return;
    }
    void store.cancelImport(id);
    const latest = authored.current;
    change({
      ...latest,
      body: withoutImage(latest.body, id),
      ...(latest.quoted === undefined
        ? {}
        : { quoted: withoutImage(latest.quoted, id) }),
      ...(latest.attachments === undefined
        ? {}
        : {
            attachments: latest.attachments.filter((asset) => asset.id !== id),
          }),
    });
  };
  // Undo and Redo step from the latest history, so repeated presses each move one step.
  const travel = (step: (current: typeof history) => typeof history) => {
    fromControl();
    if (pausedNow.current) {
      return;
    }
    commitHistory((current) => keepIdentity(step(current)));
    placeTyping(undefined);
    update(historyNow.current.present);
  };
  const edit = (text: string) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const textBefore = displayOf(latest.body).text;
    // Native selection formatting reports its unchanged text to advance RN's event count.
    if (text === textBefore) {
      return;
    }
    const result = applyText(latest.body, text, {
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
      change({ ...latest, body: result.document }, word, 'body');
    } else {
      // The literal marker is its own step, so one Undo restores it.
      const { literal } = result;
      commitHistory((current) =>
        keepIdentity(
          record(record(current, { ...latest, body: literal }), {
            ...latest,
            body: result.document,
          }),
        ),
      );
      update({ ...latest, body: result.document });
    }
    if (result.selection !== undefined) {
      caret.current = result.selection.start;
      selectionNow.current = result.selection;
      setPlaced(result.selection);
    }
  };
  const format = (mark: Mark) => {
    if (pausedNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    if (at.start === at.end) {
      placeTyping(toggled(typingNow.current ?? marksAt(latest.body, at), mark));
      return;
    }
    change({ ...latest, body: toggleMark(latest.body, at, mark) });
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
      latest.body,
      captured.selection,
      draftReplacement(captured.text, replacement),
    );
    change({ ...latest, body: result.document });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    setPlaced(result.selection);
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
    const result = setBlockKind(latest.body, at, kind);
    change({ ...latest, body: result.document });
    selectionNow.current = result.selection ?? at;
    setPlaced(result.selection);
  };
  const editLink = (link: Link, text: string, href?: string) => {
    if (pausedNow.current) {
      return;
    }
    const latest = authored.current;
    const result = setLink(latest.body, link, { text, href });
    change({ ...latest, body: result.document });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    setPlaced(result.selection);
  };
  const insertTemplate = (template: MailTemplate) => {
    if (pausedNow.current) {
      return;
    }
    const latest = authored.current;
    const applied = applyTemplate(latest, selectionNow.current, template);
    change({
      ...latest,
      subject: applied.subject,
      body: applied.edit.document,
    });
    placeTyping(undefined);
    selectionNow.current = applied.edit.selection ?? selectionNow.current;
    setPlaced(applied.edit.selection);
  };
  // Entries still being typed become recipients as one undoable correction; invalid text stays
  // in its field. Returns the finished Draft.
  const finishEntries = useCallback(() => {
    const latest = authored.current;
    let finished = latest;
    for (const field of ['to', 'cc', 'bcc'] as const) {
      finished = addRecipients(finished, {
        field,
        text: entryOf(finished, field),
        all: true,
      }).draft;
    }
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
  // Stores this editor's version, then saves it. Invalid recipient text keeps the Draft open.
  const saveDraft = async () => {
    if (discarded.current || lifetime.current.finishing > 0) {
      return false;
    }
    if (finishEntries().entries !== undefined) {
      setOpen(undefined);
      setClosing('recipients');
      answerLeave(false);
      return false;
    }
    return finishing(storeAndSave);
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
    // Another window's failed save leaves this editor's untouched Draft alone.
    if (authored.current === stored.current && !unsaved.current) {
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
  useCloseGuard(navigation.leave);
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
  const keyDown = ({ nativeEvent }: KeyEvent) => {
    deletion.current = undefined;
    if (pausedNow.current) {
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
    if (discarded.current || lifetime.current.finishing > 0) {
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
    if (reminder === undefined || lifetime.current.finishing > 0) {
      return;
    }
    setReminderFailed(undefined);
    lifetime.current.finishing += 1;
    let removed = false;
    try {
      removed = await sendReminders.cancel(reminder.profile, reminder.draft);
    } catch {
      // An unexpected storage rejection keeps the reminder, to remove again.
    }
    finishOperation();
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
  // keeps it open.
  const send = async () => {
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
      storeShown();
      refusal = await outbox.send(
        () => ({
          ...shown,
          id: cleanup.target(),
          ...(authored.current.conflict ? { conflict: true as const } : {}),
        }),
        setCheck,
      );
      // A refused Send still stored the version shown; Close asks only if saving it failed.
      if (refusal !== undefined && (await store.save())) {
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
  // The question's choices act through this render's Save and Don’t Save.
  const answerSave = useRef<(choice: number) => void>(undefined);
  useLayoutEffect(() => {
    answerSave.current = (choice) => {
      if (choice === 0) {
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
    const question = askInSheet(root.current, {
      title: t('drafts.saveQuestion'),
      detail: t('drafts.saveQuestionDetail'),
      buttons: [
        t('drafts.saveAction'),
        t('drafts.dontSave'),
        t('common.cancel'),
      ],
    });
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
  }, [open, t]);
  const title = clip(draft.subject) || t('drafts.newMessage');
  const titleLabel =
    title.length < draft.subject.length
      ? t('drafts.titleShortened', { title })
      : title;
  const active = typing ?? marksAt(draft.body, selection);
  const kind = blockKindAt(draft.body, selection.start);
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
  const sendButton = (
    <SendMenu
      disabled={closing === 'saving'}
      onSend={() => {
        void send();
      }}
      onRemind={(dueAt, timeZone) => {
        void remind(dueAt, timeZone);
      }}
    />
  );
  // Once Cc or Bcc is shown or holds a recipient, both stay shown for the Draft.
  const copiesShown =
    draft.copies === true || draft.cc.length + draft.bcc.length > 0;

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
                closing === 'saving'
                  ? undefined
                  : () => {
                      void send();
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
        disabled={paused}
        onBlock={(next) => {
          fromControl();
          block(next);
        }}
        onMark={(mark) => {
          fromControl();
          format(mark);
        }}>
        <LinkEditor
          disabled={paused}
          link={editableLinkAt(draft.body, selection)}
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
                  authored.current.body,
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
      <ScrollView contentContainerStyle={styles.content}>
        <ComposerNotices
          closing={closing}
          draft={draft}
          refused={refused}
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
          keyDownEvents={shortcuts}
          multiline
          onChangeText={edit}
          onKeyDown={keyDown}
          onSelectionChange={({ nativeEvent }) => {
            if (linking.current) {
              return;
            }
            const next = nativeEvent.selection;
            // Moving the caret anywhere but past typed text ends marks toggled for typing.
            if (next.start !== next.end || next.start !== caret.current) {
              placeTyping(undefined);
              commitHistory((current) => ({ ...current, typing: false }));
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
                onChange={change}
                onCaretMove={breakTyping}
              />
              <Recipients
                draft={draft}
                getDraft={getDraft}
                editable={!paused}
                field="bcc"
                onChange={change}
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
  onClose,
  onRebind,
  onExpand,
  renderToolbar,
}: {
  readonly id: string;
  readonly onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  readonly onRebind: (id: string) => void;
  readonly onExpand?: ((id: string) => void) | undefined;
  readonly renderToolbar?: Toolbar | undefined;
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
  if (opened !== undefined) {
    return (
      <Editor
        key={editor.key}
        initial={opened}
        onClose={onClose}
        onClosedAfterRemoval={closedAfterRemoval}
        onExpand={onExpand}
        onRebind={rebind}
        renderToolbar={renderToolbar}
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
