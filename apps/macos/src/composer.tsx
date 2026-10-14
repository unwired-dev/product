import type { Translate } from '@private-email/localization';
import type {
  CapturedDraftText,
  NativeAssistance,
} from '@private-email/mail-core/assistance';
import type {
  AssetPreview,
  Draft,
  PickedFile,
  PickSource,
  RecipientField,
  RecipientNotice,
} from '@private-email/mail-core/drafts';
import type { SendRefusal } from '@private-email/mail-core/outbox';
import type {
  MailboxConnection,
  MailProvider,
} from '@private-email/mail-core/registration';
import type {
  Asset,
  BlockKind,
  Mark,
  Selection,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { NativeTranslation } from '@private-email/mail-core/translation';
import type { ReactNode } from 'react';
import type {
  KeyEvent,
  StyleProp,
  TextInputMacOSProps,
  TextStyle,
} from 'react-native';

import {
  canRewrite,
  canSuggestReply,
  captureDraftText,
  draftReplacement,
  sameDraftAssistanceSource,
} from '@private-email/mail-core/assistance';
import {
  addRecipients,
  draftOf,
  entryOf,
  isEmptyDraft,
  recipientLabel,
  draftSummary,
  profileOf,
  sendingMailboxes,
  pickLimit,
  sendingStateOf,
  unsendableAssets,
  prepareFiles,
  withAsset,
  withSender,
} from '@private-email/mail-core/drafts';
import {
  applyText,
  blockKindAt,
  displayOf,
  historyOf,
  imageCharacter,
  imagesOf,
  marksAt,
  clip,
  previewOf,
  record,
  redo,
  replaceSelection,
  selectedText,
  setBlockKind,
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
  ActivityIndicator,
  AppState,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  ComposerActions,
  FormatBar,
  MenuItem,
  PopUp,
} from './composer-controls.tsx';
import { Button, SFSymbol, ToolbarButton } from './design.tsx';
import { DraftAssistance } from './draft-assistance.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useLeaveComposer,
  useOutbox,
  useProfile,
} from './mailbox.tsx';
import { fileSize } from './message-body.tsx';
import { AssistanceContext } from './message-summary.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';
import { DraftTranslation, TranslationContext } from './translation.tsx';

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
  status: {
    ...textStyles.subheadline,
    paddingHorizontal: fieldInset,
    paddingBottom: spacing.xs,
  },
  alerts: {
    gap: spacing.s,
    paddingHorizontal: fieldInset,
    paddingBottom: spacing.s,
  },
  alert: {
    gap: spacing.s,
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  alertMessage: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.s,
  },
  alertActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
    paddingLeft: 16 + spacing.s,
  },
  divider: { width: StyleSheet.hairlineWidth, height: 16, marginHorizontal: 2 },
  content: { paddingBottom: spacing.s },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  action: { minHeight: 28, justifyContent: 'center', paddingHorizontal: 8 },
  actionText: { ...textStyles.body },
  notice: { ...textStyles.body },
  review: { paddingHorizontal: fieldInset, paddingTop: spacing.m },
  body: {
    ...textStyles.reading.body,
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
  assetStatus: { ...textStyles.subheadline },
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
  input: {
    ...textStyles.body,
    flex: 1,
    minWidth: 120,
    minHeight: 28,
    paddingVertical: 0,
  },
  // The whole 28pt row height removes the recipient; its chip stays compact.
  token: { minHeight: 28, justifyContent: 'center' },
  tokenFill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.s,
    paddingVertical: 2,
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

const kindStyles: Record<BlockKind, TextStyle> = {
  paragraph: {},
  heading1: { fontSize: 26, lineHeight: 34, fontWeight: '700' },
  heading2: { fontSize: 22, lineHeight: 30, fontWeight: '700' },
  heading3: { fontSize: 19, lineHeight: 28, fontWeight: '600' },
  bulleted: {},
  numbered: {},
  quote: { fontStyle: 'italic' },
  code: { fontFamily: 'Menlo' },
};

const decorations = {
  underline: 'underline',
  strikethrough: 'line-through',
  both: 'underline line-through',
} as const;

const markStyle = (marks: readonly Mark[] = []): TextStyle => {
  const underline = marks.includes('underline');
  const strikethrough = marks.includes('strikethrough');
  let decoration: (typeof decorations)[keyof typeof decorations] | undefined =
    undefined;
  if (underline && strikethrough) {
    decoration = decorations.both;
  } else if (underline) {
    decoration = decorations.underline;
  } else if (strikethrough) {
    decoration = decorations.strikethrough;
  }
  return {
    ...(marks.includes('bold') ? { fontWeight: '700' } : {}),
    ...(marks.includes('italic') ? { fontStyle: 'italic' } : {}),
    ...(marks.includes('code') ? { fontFamily: 'Menlo' } : {}),
    ...(decoration === undefined ? {} : { textDecorationLine: decoration }),
  };
};

// What keeps the composer from closing, or asks before it does.
type Closing =
  | 'saving'
  | 'blocked'
  | 'discard-blocked'
  | 'discard'
  | 'recipients';

// A quiet banner beside the content it explains, with its actions under the message.
function Alert({
  message,
  children,
}: {
  readonly message: string;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.alert, { backgroundColor: colors.fillQuiet }]}>
      <View style={styles.alertMessage}>
        <SFSymbol
          name="exclamationmark.triangle"
          color={colors.textSecondary}
        />
        <Notice
          alert
          style={[styles.notice, { color: colors.textPrimary }]}>
          {message}
        </Notice>
      </View>
      {children === undefined ? null : (
        <View style={styles.alertActions}>{children}</View>
      )}
    </View>
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

export function Action({
  label,
  onPress,
  disabled = false,
  destructive = false,
  accessibilityLabel,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityLabel?: string;
}) {
  const colors = usePalette();
  let color = destructive ? colors.statusDestructive : colors.accentInk;
  if (disabled) {
    color = colors.textSecondary;
  }
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={styles.action}>
      <Text style={[styles.actionText, { color }]}>{label}</Text>
    </Pressable>
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
      onPress={() => {
        void onOpen(draft.id);
      }}
      style={[
        styles.row,
        {
          backgroundColor: selected ? colors.accentFill : colors.surfaceContent,
          borderColor: 'transparent',
        },
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

// The Inbox list's Draft controls: starting a new message and Drafts storage status. The Draft
// rows themselves are list items, so a long list stays virtualized.
export function DraftList({
  onCompose,
  scope,
}: {
  readonly onCompose: (id: string) => void;
  // The mailbox the Inbox shows, which a new message sends from when it can.
  readonly scope: string | undefined;
}) {
  const account = use(AccountContext);
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  const navigation = useComposerNavigation();
  const windowProfile = useProfile();
  const creating = useRef(false);
  const [creatingShown, setCreatingShown] = useState(false);
  if (account === undefined || state.kind === 'closed') {
    return null;
  }
  // The unified Inbox sends from the window's Profile.
  const senders = sendingMailboxes(
    account.mailboxes,
    scope === undefined ? windowProfile : profileOf(scope, account.mailboxes),
  );
  const sender = senders.find(({ id }) => id === scope) ?? senders[0];
  // One new Draft at a time: a second press while one is being created does nothing.
  const compose = async (mailbox: MailboxConnection) => {
    if (creating.current) {
      return;
    }
    creating.current = true;
    setCreatingShown(true);
    // Leaving and creating resolve rather than reject, so the press always settles here.
    const id = await navigation.create(store, mailbox);
    creating.current = false;
    setCreatingShown(false);
    if (id !== undefined) {
      onCompose(id);
    }
  };
  return (
    <View>
      <View style={[styles.bar, { paddingHorizontal: spacing.xl }]}>
        <Action
          disabled={
            state.kind !== 'ready' || sender === undefined || creatingShown
          }
          label={t('drafts.newMessage')}
          onPress={() => {
            if (sender !== undefined) {
              void compose(sender);
            }
          }}
        />
      </View>
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
function SendingMailbox({
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
  const [open, setOpen] = useState(false);
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
      above
      quiet
      accessibilityLabel={label}
      disabled={!editable}
      label={from}
      open={open}
      prefix={t('drafts.fromLabel')}
      selected={state === 'available'}
      onToggle={() => {
        setOpen((current) => !current);
      }}>
      {senders.map((mailbox) => {
        const address = clip(mailbox.address);
        return (
          <MenuItem
            key={mailbox.id}
            disabled={!editable}
            accessibilityLabel={t(
              address.length < mailbox.address.length
                ? 'drafts.sendFromShortened'
                : 'drafts.sendFrom',
              { address },
            )}
            label={address}
            selected={state === 'available' && mailbox.id === draft.connection}
            onPress={() => {
              setOpen(false);
              onChange(mailbox);
            }}
          />
        );
      })}
    </PopUp>
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

function Recipients({
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
  const name = t(`drafts.fields.${field}`);
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
              <View
                style={[
                  styles.tokenFill,
                  { backgroundColor: colors.fillQuiet },
                ]}>
                <Text style={[styles.tokenText, { color: colors.textPrimary }]}>
                  {recipient.name ?? recipient.address}
                </Text>
                <SFSymbol
                  name="xmark"
                  size={10}
                  color={colors.textSecondary}
                />
              </View>
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
            onBlur={() => {
              add(entryOf(getDraft(), field), true);
            }}
            onChangeText={(value) => {
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
              add(entryOf(getDraft(), field), true);
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
    preview,
  }: Readonly<{
    asset: Asset;
    running: boolean;
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

function AssetRow({
  asset,
  editable,
  inline,
  running,
  onRemove,
  onCancel,
}: {
  readonly asset: Asset;
  readonly inline: boolean;
  readonly running: boolean;
  readonly editable: boolean;
  readonly onRemove: (id: string) => void;
  readonly onCancel: (id: string) => void;
}) {
  const colors = usePalette();
  const { t, settings } = useLocalization();
  const sizeFormat = useMemo(
    () => new Intl.NumberFormat(settings.locale, { maximumFractionDigits: 1 }),
    [settings.locale],
  );
  const { preview, retry } = usePreview(asset, inline);
  const status = assetStatus(t, (bytes) => fileSize(t, sizeFormat, bytes), {
    asset,
    running,
    preview,
  });
  return (
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
        style={styles.assetMeta}>
        <Text
          numberOfLines={1}
          style={[styles.assetName, { color: colors.textPrimary }]}>
          {asset.name}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.assetStatus, { color: colors.textSecondary }]}>
          {status}
        </Text>
      </View>
      {preview?.kind === 'locked' || preview?.kind === 'incomplete' ? (
        <Action
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
}

// A Draft's attachments and inline images, with what can still be done to each.
function DraftAssets({
  draft,
  editable,
  onRemove,
  onCancel,
}: {
  readonly draft: Draft;
  readonly editable: boolean;
  readonly onRemove: (id: string) => void;
  readonly onCancel: (id: string) => void;
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
        editable={editable}
        inline={inline}
        onCancel={onCancel}
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
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ expanded: shown }}
        onPress={() => {
          setShown((current) => !current);
        }}
        style={styles.action}>
        <Text style={[styles.notice, { color: colors.accentInk }]}>
          {shown
            ? t('drafts.response.hideQuoted')
            : t('drafts.response.showQuoted')}
        </Text>
      </Pressable>
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

export const rewriteLabel = (at: Selection) =>
  at.start === at.end
    ? 'assistance.rewriteDraftLabel'
    : 'assistance.rewriteSelectionLabel';

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
      message={t(
        refused === 'too-large'
          ? tooLarge[provider ?? 'gmail']
          : `drafts.sendRefused.${refused}`,
      )}
    />
  );
}

// A body or admitted reply-context revision retires the captured input. So does Mail Assistance
// Enablement turning off, so turning it on again never restarts the request by itself.
export const retires = (
  captured: CapturedDraftText,
  draft: CapturedDraftText['draft'],
  {
    assistance,
    translation,
  }: Readonly<{
    assistance: NativeAssistance | undefined;
    translation: NativeTranslation | undefined;
  }>,
) =>
  !sameDraftAssistanceSource(captured.draft, draft, captured.purpose) ||
  (captured.purpose === 'translate' ? translation : assistance) === undefined;

// The review panel for captured Draft text, while its framework is enabled.
export function CapturedAssistance({
  captured,
  assistance,
  translation,
  onApply,
  onClose,
}: {
  readonly captured: CapturedDraftText;
  readonly assistance: NativeAssistance | undefined;
  readonly translation: NativeTranslation | undefined;
  readonly onApply: (text: string) => void;
  readonly onClose: () => void;
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
      purpose={captured.purpose}
      issue={captured.issue}
      input={captured.input}
      onApply={onApply}
      onClose={onClose}
    />
  );
}

// Why the composer stays open, or what it asks before discarding, above the format bar.
function ComposerNotices({
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
        <Alert message={t('drafts.invalidRecipients')} />
      ) : null}
      <SendRefusalNotice
        connection={draft.connection}
        refused={refused}
      />
      <SendingNotice draft={draft} />
      {closing === 'discard' ? (
        <Alert message={t('drafts.discardConfirm')}>
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

function Editor({
  initial,
  onClose,
  onRebind,
  expanded = false,
  onExpand,
}: {
  readonly initial: Draft;
  readonly onClose: () => void;
  // Another editor changed this Draft first, so this editor's version is now the copy `id`.
  readonly onRebind: (id: string) => void;
  // Whether the composer takes over the window, and the control that toggles it when offered.
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  const [history, setHistory] = useState(() => historyOf(initial));
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
      authored.current = bound(authored.current);
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
  const [captured, setCaptured] = useState<
    CapturedDraftText & { readonly id: number }
  >();
  const captureNow = useRef<typeof captured>(undefined);
  const assistanceEnabled = useMailAssistanceLifetime(
    useCallback(() => {
      captureNow.current = undefined;
      setCaptured(undefined);
    }, []),
  );
  const captureGeneration = useRef(0);
  // The latest body selection, ahead of rendering, for text events that follow a caret move.
  const selectionNow = useRef(selection);
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
  // Why the last Send left this Draft here.
  const [refused, setRefused] = useState<SendRefusal>();
  // While Send is pending the editor accepts no edits, so nothing typed then is lost.
  const [sending, setSending] = useState(false);
  // Native callbacks can arrive before the disabled props commit.
  const sendingNow = useRef(false);
  // A control that also waits while Send is pending.
  const lockedUnless = (available: boolean) => sending || !available;
  const outbox = useOutbox();
  const caret = useRef<number | undefined>(undefined);
  const typingField = useRef<string | undefined>(undefined);
  const subjectSelection = useRef<Selection>({ start: 0, end: 0 });
  const subjectCaret = useRef<number | undefined>(undefined);
  const deletion = useRef<'backward' | 'forward' | undefined>(undefined);
  const draft = history.present;
  const assistance = use(AssistanceContext);
  const translation = use(TranslationContext);
  if (
    captured !== undefined &&
    retires(captured, draft, { assistance, translation })
  ) {
    setCaptured(undefined);
  }
  const breakTyping = () => {
    commitHistory((current) => ({ ...current, typing: false }));
  };
  const display = displayOf(draft.body);
  const save = state.kind === 'ready' ? state.save : 'failed';

  // Holds saving during discard; a failed discard restores edits accepted while it waited.
  const discarded = useRef(false);
  const update = useCallback(
    (next: Draft) => {
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
      }
      authored.current = bound;
      if (!discarded.current) {
        setRefused(undefined);
        void store.update(bound, previous, rebind);
      }
    },
    [rebind, store],
  );
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
    if (!discarded.current) {
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
        authored.current = patch(authored.current);
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
    if (sendingNow.current) {
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
    if (sendingNow.current) {
      return;
    }
    commitHistory((current) => keepIdentity(step(current)));
    placeTyping(undefined);
    update(historyNow.current.present);
  };
  const edit = (text: string) => {
    if (sendingNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const textBefore = displayOf(latest.body).text;
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
    if (sendingNow.current) {
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
      !sendingNow.current &&
      captured !== undefined &&
      captureNow.current === captured
    ) {
      captureNow.current = undefined;
      setCaptured(undefined);
    }
  };
  // Captures authored text for an explicitly requested translation, rewrite or reply suggestion.
  const capture = (purpose: CapturedDraftText['purpose'], at: Selection) => {
    if (
      sendingNow.current ||
      !lifetime.current.mounted ||
      !assistanceEnabled()
    ) {
      return;
    }
    captureGeneration.current += 1;
    const next = {
      ...captureDraftText(purpose, authored.current, at),
      id: captureGeneration.current,
    };
    captureNow.current = next;
    setCaptured(next);
  };
  const block = (kind: BlockKind) => {
    if (sendingNow.current) {
      return;
    }
    const at = selectionNow.current;
    const latest = authored.current;
    const result = setBlockKind(latest.body, at, kind);
    change({ ...latest, body: result.document });
    selectionNow.current = result.selection ?? at;
    setPlaced(result.selection);
  };
  const close = useCallback(async () => {
    if (discarded.current) {
      return false;
    }
    // Entries still being typed become recipients; invalid text keeps the Draft open.
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
    if (finished.entries !== undefined) {
      setClosing('recipients');
      return false;
    }
    setClosing('saving');
    let closed = false;
    lifetime.current.finishing += 1;
    try {
      closed = isEmptyDraft(finished)
        ? await store.discard(() => authored.current.id, {
            onlyIfEmpty: true,
            expected: () => authored.current,
          })
        : await store.save();
    } catch {
      // An unexpected storage rejection keeps the composer open and retryable too.
    }
    finishOperation();
    if (!lifetime.current.mounted) {
      return closed;
    }
    if (closed) {
      onClose();
      return true;
    }
    setClosing('blocked');
    return false;
  }, [commitHistory, finishOperation, keepIdentity, onClose, store, update]);
  const navigation = useComposerNavigation();
  useLayoutEffect(() => navigation.register(close), [navigation, close]);
  const keyDown = ({ nativeEvent }: KeyEvent) => {
    deletion.current = undefined;
    if (sendingNow.current) {
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
  const discard = async () => {
    if (discarded.current) {
      return;
    }
    const previous = authored.current;
    setClosing('saving');
    discarded.current = true;
    lifetime.current.finishing += 1;
    let removed = false;
    // The content Discard froze, following any conflict rebind that lands before deletion runs.
    const baseline = () =>
      previous.id === authored.current.id
        ? previous
        : { ...previous, id: authored.current.id, conflict: true as const };
    try {
      removed = await store.discard(() => authored.current.id, {
        // Discard suppresses later autosaves; freeze its content while following any rebind.
        expected: baseline,
      });
    } catch {
      // An unexpected storage rejection leaves the editor retryable too.
    }
    if (!removed) {
      discarded.current = false;
      // Edits accepted meanwhile follow the same version, so they save as one sequential edit.
      if (authored.current !== previous) {
        void store.update(authored.current, baseline(), rebind);
      }
    }
    // A failed discard may have rebound its restored edit; release after that update.
    finishOperation();
    if (lifetime.current.mounted) {
      if (removed) {
        onClose();
      } else {
        setClosing('discard-blocked');
      }
    }
  };
  // Admits the Draft as this editor shows it to the Outbox, then closes; a refusal keeps it open.
  const send = async () => {
    if (discarded.current) {
      return;
    }
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
    if (finished.entries !== undefined) {
      setClosing(undefined);
      setRefused('entries');
      return;
    }
    const previous = authored.current;
    setRefused(undefined);
    setClosing('saving');
    sendingNow.current = true;
    setSending(true);
    captureNow.current = undefined;
    setCaptured(undefined);
    // As for Discard, later edits wait: the version shown at Send is the one sent.
    discarded.current = true;
    lifetime.current.finishing += 1;
    const baseline = () =>
      previous.id === authored.current.id
        ? previous
        : { ...previous, id: authored.current.id, conflict: true as const };
    let refusal: SendRefusal | undefined = 'storage';
    try {
      refusal = await outbox.send(baseline);
    } catch {
      // An unexpected rejection keeps the Draft open to send again.
    }
    if (refusal !== undefined) {
      sendingNow.current = false;
      discarded.current = false;
      if (authored.current !== previous) {
        void store.update(authored.current, baseline(), rebind);
      }
    }
    finishOperation();
    if (lifetime.current.mounted) {
      if (refusal === undefined) {
        onClose();
      } else {
        setClosing(undefined);
        setRefused(refusal);
        setSending(false);
      }
    }
  };
  const title = clip(draft.subject) || t('drafts.newMessage');
  const titleLabel =
    title.length < draft.subject.length
      ? t('drafts.titleShortened', { title })
      : title;
  const active = typing ?? marksAt(draft.body, selection);
  const kind = blockKindAt(draft.body, selection.start);
  // Once Cc or Bcc is shown or holds a recipient, both stay shown for the Draft.
  const copiesShown =
    draft.copies === true || draft.cc.length + draft.bcc.length > 0;

  return (
    <View
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
            icon={
              expanded
                ? 'arrow.down.right.and.arrow.up.left'
                : 'arrow.up.left.and.arrow.down.right'
            }
            label={t(expanded ? 'drafts.collapse' : 'drafts.expand')}
            onPress={onExpand}
          />
        )}
        <ComposerActions
          disabled={sending}
          onDiscard={() => {
            if (!sendingNow.current) {
              setClosing('discard');
            }
          }}
        />
      </View>
      <View style={styles.bar}>
        <Notice style={[styles.status, { color: colors.textSecondary }]}>
          {t('drafts.status', { status: t(`drafts.save.${save}`) })}
        </Notice>
      </View>
      <ComposerNotices
        closing={closing}
        draft={draft}
        refused={refused}
        onClose={() => {
          void close();
        }}
        onDiscard={() => {
          void discard();
        }}
        onKeepEditing={() => {
          setClosing(undefined);
        }}
      />
      <FormatBar
        active={active}
        kind={kind}
        disabled={sending}
        onBlock={block}
        onMark={format}>
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
        {translation === undefined ? null : (
          <Button
            disabled={lockedUnless(
              hasTranslatableText(
                selectedText(draft.body, selection, translationInputLimit + 1),
              ),
            )}
            label={t('translation.translate')}
            accessibilityLabel={t('translation.translateSelectionLabel')}
            onPress={() => {
              const at = selectionNow.current;
              const { body } = authored.current;
              const text = selectedText(body, at, translationInputLimit + 1);
              if (
                sendingNow.current ||
                !lifetime.current.mounted ||
                !hasTranslatableText(text)
              ) {
                return;
              }
              capture('translate', at);
            }}
          />
        )}
        {assistance === undefined ? null : (
          <>
            <Button
              disabled={lockedUnless(canRewrite(draft.body, selection))}
              label={t('assistance.rewrite')}
              accessibilityLabel={t(rewriteLabel(selection))}
              onPress={() => {
                const at = selectionNow.current;
                if (
                  lifetime.current.mounted &&
                  canRewrite(authored.current.body, at)
                ) {
                  capture('rewrite', at);
                }
              }}
            />
            {canSuggestReply(draft) ? (
              <Button
                disabled={sending}
                label={t('assistance.suggestReply')}
                accessibilityLabel={t('assistance.suggestReplyLabel')}
                onPress={() => {
                  if (lifetime.current.mounted) {
                    capture('reply', selectionNow.current);
                  }
                }}
              />
            ) : null}
          </>
        )}
        <View style={[styles.divider, { backgroundColor: colors.separator }]} />
        <ToolbarButton
          disabled={sending}
          icon="paperclip"
          label={t('drafts.assets.attachFilesPanel')}
          onPress={() => {
            void choose('files', false);
          }}
        />
        <ToolbarButton
          disabled={sending}
          icon="photo.on.rectangle"
          label={t('drafts.assets.insertImagePanel')}
          onPress={() => {
            void choose('photos', true);
          }}
        />
      </FormatBar>
      <ScrollView contentContainerStyle={styles.content}>
        {captured === undefined ? null : (
          <View style={styles.review}>
            <CapturedAssistance
              key={captured.id}
              captured={captured}
              assistance={assistance}
              translation={translation}
              onApply={applyCaptured}
              onClose={closeCaptured}
            />
          </View>
        )}
        <TextInput
          accessibilityLabel={t('drafts.body')}
          editable={!sending}
          accessibilityState={{ disabled: sending }}
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
          scrollEnabled={false}
          selection={placed}
          style={[styles.body, { color: colors.textPrimary }]}
          textAlignVertical="top">
          {display.lines.map((line, index) => (
            <Text
              // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
              key={index}
              style={[
                kindStyles[line.kind],
                line.kind === 'quote' ? { color: colors.textSecondary } : null,
              ]}>
              {line.marker}
              {line.spans.map((span, at) => (
                <Text
                  // oxlint-disable-next-line react/no-array-index-key -- Spans are positional.
                  key={at}
                  style={markStyle(span.marks)}>
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
          draft={draft}
          editable={!sending}
          onCancel={(id) => {
            if (!sendingNow.current) {
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
            editable={!sending}
            field="to"
            onChange={change}
            onCaretMove={breakTyping}
            trailing={
              copiesShown ? undefined : (
                <Action
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
                field="cc"
                onChange={change}
                onCaretMove={breakTyping}
              />
              <Recipients
                draft={draft}
                getDraft={getDraft}
                editable={!sending}
                field="bcc"
                onChange={change}
                onCaretMove={breakTyping}
              />
            </>
          ) : null}
        </View>
      </ScrollView>
      <View style={[styles.actions, { borderTopColor: colors.separator }]}>
        <SendingMailbox
          draft={draft}
          editable={!sending}
          onChange={(mailbox) => {
            change(withSender(authored.current, mailbox));
          }}
        />
        <View style={styles.grow} />
        <Button
          disabled={closing === 'saving'}
          label={t('drafts.send')}
          fill="accent"
          onPress={() => {
            void send();
          }}
        />
      </View>
    </View>
  );
}

// Opens a Draft directly for editing; it has no read-only presentation.
export function Composer({
  id,
  onClose,
  onRebind,
  expanded,
  onExpand,
}: {
  readonly id: string;
  readonly onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  readonly onRebind: (id: string) => void;
  readonly expanded?: boolean | undefined;
  readonly onExpand?: (() => void) | undefined;
}) {
  const state = useDrafts();
  const store = useDraftStore();
  const colors = usePalette();
  const { t } = useLocalization();
  // The editor stays mounted when it moves to its own copy, and remounts for another Draft.
  const [editor, setEditor] = useState({ key: id, followed: id });
  if (editor.followed !== id) {
    setEditor({ key: id, followed: id });
  }
  const rebind = useCallback(
    (copy: string) => {
      setEditor((current) => ({ key: current.key, followed: copy }));
      onRebind(copy);
    },
    [onRebind],
  );
  const draft = draftOf(state, id);
  if (draft !== undefined) {
    return (
      <Editor
        key={editor.key}
        initial={draft}
        expanded={expanded}
        onClose={onClose}
        onExpand={onExpand}
        onRebind={rebind}
      />
    );
  }
  const waiting = state.kind === 'loading';
  return (
    <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.header}>
        <ToolbarButton
          icon="xmark"
          label={t('drafts.close')}
          onPress={onClose}
        />
      </View>
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
