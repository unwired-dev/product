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
import type { StyleProp, TextInputChangeEvent, TextStyle } from 'react-native';

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
import { SafeAreaView } from 'react-native-screens/experimental';

import { Commands } from './command-palette.tsx';
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

// Fabric includes the post-edit selection; RN's Flow declaration has it, but its TS type omits it.
type BodyChangeEvent = TextInputChangeEvent & {
  readonly nativeEvent: { readonly selection?: Selection };
};

const styles = StyleSheet.create({
  fill: { flex: 1 },
  content: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    padding: spacing.xl,
    gap: spacing.l,
  },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
  },
  grow: { flex: 1 },
  action: { minHeight: 44, justifyContent: 'center', paddingHorizontal: 8 },
  actionText: { ...textStyles.body },
  status: { ...textStyles.footnote },
  label: { ...textStyles.footnote, fontWeight: '600' },
  field: {
    gap: 6,
    paddingBottom: spacing.s,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  input: { ...textStyles.body, minHeight: 44, paddingVertical: 8 },
  tokens: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  token: {
    minHeight: 32,
    justifyContent: 'center',
    paddingHorizontal: 10,
    borderRadius: radius.chip,
  },
  notice: { ...textStyles.subheadline },
  quoted: { ...textStyles.reading.body, paddingVertical: 8 },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: 12,
    borderWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  format: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
  },
  body: { ...textStyles.reading.body, minHeight: 240, paddingVertical: 8 },
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
  asset: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.s,
    paddingVertical: 4,
  },
  thumbnail: { width: 64, height: 64, borderRadius: radius.control },
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

type MarkName = `drafts.marks.${Mark}`;
type BlockName = `drafts.blocks.${Exclude<BlockKind, 'paragraph'>}`;

export const markControls: ReadonlyArray<
  readonly [Mark, string, MarkName, StyleProp<TextStyle>]
> = [
  ['bold', 'B', 'drafts.marks.bold', { fontWeight: '700' }],
  ['italic', 'I', 'drafts.marks.italic', { fontStyle: 'italic' }],
  [
    'underline',
    'U',
    'drafts.marks.underline',
    { textDecorationLine: 'underline' },
  ],
  [
    'strikethrough',
    'S',
    'drafts.marks.strikethrough',
    { textDecorationLine: 'line-through' },
  ],
  ['code', '</>', 'drafts.marks.code', { fontFamily: 'Menlo' }],
];

export const blockControls: ReadonlyArray<
  readonly [BlockKind, string, BlockName]
> = [
  ['heading1', 'H1', 'drafts.blocks.heading1'],
  ['heading2', 'H2', 'drafts.blocks.heading2'],
  ['heading3', 'H3', 'drafts.blocks.heading3'],
  ['bulleted', '•', 'drafts.blocks.bulleted'],
  ['numbered', '1.', 'drafts.blocks.numbered'],
  ['quote', '❝', 'drafts.blocks.quote'],
  ['code', '{ }', 'drafts.blocks.code'],
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
      // Native Back can hide the secondary column without changing its selected Draft.
      // Selecting it again reveals that same editor and must not try to leave it.
      if (id === composing || (await leave(id))) {
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
  const accountId = account?.productAccountId;
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  const navigation = useComposerNavigation();
  const windowProfile = useProfile();
  const owner = useMemo(
    () => ({ accountId, navigation, scope, store, windowProfile }),
    [accountId, navigation, scope, store, windowProfile],
  );
  const creating = useRef<object | undefined>(undefined);
  const scopeOwner = useRef<object | undefined>(undefined);
  const [creatingOwner, setCreatingOwner] = useState<object | undefined>();
  const creatingShown = creatingOwner === owner;
  useLayoutEffect(() => {
    scopeOwner.current = owner;
    return () => {
      scopeOwner.current = undefined;
    };
  }, [owner]);
  if (account === undefined || state.kind === 'closed') {
    return null;
  }
  // The unified Inbox sends from the window's Profile.
  const senders = sendingMailboxes(
    account.mailboxes,
    scope === undefined ? windowProfile : profileOf(scope, account.mailboxes),
  );
  const sender = senders.find(({ id }) => id === scope) ?? senders[0];
  const draftReasons = {
    loading: t('commandPalette.busy'),
    locked: t('drafts.listLocked'),
    failed: t('drafts.listFailed'),
    ready: undefined,
  };
  const composeUnavailable =
    draftReasons[state.kind] ??
    (sender === undefined ? t('commandPalette.noSender') : undefined);
  const composeDisabled = creatingShown
    ? t('commandPalette.busy')
    : composeUnavailable;
  // One new Draft at a time within this scope: a second press does nothing.
  const compose = async (mailbox: MailboxConnection) => {
    if (scopeOwner.current !== owner || creating.current === owner) {
      return false;
    }
    creating.current = owner;
    setCreatingOwner(owner);
    // Leaving and creating resolve rather than reject, so the press always settles here.
    const result = await navigation.createResult(store, mailbox);
    if (owner !== scopeOwner.current) {
      return false;
    }
    creating.current = undefined;
    setCreatingOwner(undefined);
    if (result?.kind === 'created') {
      onCompose(result.id);
      return true;
    }
    return result?.kind === 'failed' ? ('failed' as const) : false;
  };
  return (
    <View>
      <Commands
        commands={[
          {
            id: 'compose',
            label: t('drafts.newMessage'),
            keywords: t('commandPalette.composeKeywords'),
            group: 'app',
            disabled: composeDisabled,
            onRun: async () => {
              if (sender === undefined) {
                return false;
              }
              const result = await compose(sender);
              if (result === 'failed') {
                throw new Error('Composer could not finish');
              }
              return result;
            },
          },
        ]}
      />
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
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.textPrimary }]}>
            {state.kind === 'locked'
              ? t('drafts.listLocked')
              : t('drafts.listFailed')}
          </Text>
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
        // Shown wherever the person returns to the Inbox, including the iPhone system Back that
        // leaves a composer without its own notice.
        <View style={[styles.bar, { paddingHorizontal: spacing.xl }]}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.textPrimary }]}>
            {t(`drafts.unsaved.${state.save}`)}
          </Text>
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
    <Text
      accessibilityRole="header"
      style={[styles.section, { color: colors.textSecondary }]}>
      {t('drafts.heading')}
    </Text>
  );
}

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
  const colors = usePalette();
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const state = sendingStateOf(draft, mailboxes);
  const microsoft =
    mailboxes.find(({ id }) => id === draft.connection)?.provider ===
    'microsoft-graph';
  // Only the Draft's own Mail Profile can send it.
  const senders = sendingMailboxes(
    mailboxes,
    profileOf(draft.connection, mailboxes),
  );
  const from = clip(draft.from);
  return (
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.textSecondary }]}>
        {t('drafts.fromLabel')}
      </Text>
      <View style={styles.bar}>
        {state === 'available' ? null : (
          <View
            accessible
            accessibilityLabel={t(
              from.length < draft.from.length
                ? 'drafts.cannotSendShortened'
                : 'drafts.cannotSend',
              { from },
            )}
            style={[styles.choice, { borderColor: colors.separator }]}>
            <Text style={{ color: colors.textSecondary }}>{from}</Text>
          </View>
        )}
        {senders.map((mailbox) => {
          const address = clip(mailbox.address);
          const selected =
            state === 'available' && mailbox.id === draft.connection;
          return (
            <Pressable
              key={mailbox.id}
              accessibilityLabel={t(
                address.length < mailbox.address.length
                  ? 'drafts.sendFromShortened'
                  : 'drafts.sendFrom',
                { address },
              )}
              accessibilityRole="button"
              accessibilityState={{ selected, disabled: !editable }}
              disabled={!editable}
              onPress={() => {
                onChange(mailbox);
              }}
              style={[
                styles.choice,
                {
                  backgroundColor: selected
                    ? colors.accentSelectionSubtle
                    : colors.surfaceSidebar,
                  borderColor: selected ? colors.accentInk : 'transparent',
                },
              ]}>
              <Text style={{ color: colors.textPrimary }}>{address}</Text>
            </Pressable>
          );
        })}
      </View>
      {state === 'available' ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.notice, { color: colors.textPrimary }]}>
          {t(
            state === 'authorization' && microsoft
              ? 'drafts.sending.authorization_microsoft'
              : `drafts.sending.${state}`,
          )}
        </Text>
      )}
    </View>
  );
}

function Recipients({
  draft,
  getDraft,
  field,
  onChange,
  onCaretMove,
  editable,
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly field: RecipientField;
  readonly editable: boolean;
  // A typing step when only the unfinished entry changed.
  readonly onChange: (draft: Draft, typing: boolean, field: string) => void;
  readonly onCaretMove: () => void;
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
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.textSecondary }]}>
        {name}
      </Text>
      <View style={styles.tokens}>
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
            style={[
              styles.token,
              { backgroundColor: colors.accentSelectionSubtle },
            ]}>
            <Text style={{ color: colors.textPrimary }}>
              {`${recipient.name ?? recipient.address} ×`}
            </Text>
          </Pressable>
        ))}
      </View>
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
          caret.current = selection.current.end + value.length - text.length;
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
      {notice === undefined ? null : (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.notice, { color: colors.textPrimary }]}>
          {t(`drafts.recipient.${notice}`)}
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
    <View style={styles.asset}>
      {preview?.kind === 'ready' ? (
        <Image
          accessibilityIgnoresInvertColors
          accessibilityLabel={t('drafts.assets.inlineImage', {
            name: asset.name,
          })}
          source={{ uri: preview.uri }}
          style={styles.thumbnail}
        />
      ) : null}
      <View
        accessible
        accessibilityLabel={t('drafts.assets.row', {
          name: asset.name,
          status,
        })}
        style={styles.grow}>
        <Text style={{ color: colors.textPrimary }}>{asset.name}</Text>
        <Text style={[styles.status, { color: colors.textSecondary }]}>
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
      <Action
        disabled={!editable}
        accessibilityLabel={t('drafts.assets.removeLabel', {
          name: asset.name,
        })}
        label={t('drafts.assets.remove')}
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
  const colors = usePalette();
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
    <View>
      {unsendableAssets(draft).length > 0 ? (
        <Text
          accessibilityRole="alert"
          style={[styles.notice, { color: colors.textPrimary }]}>
          {t('drafts.assets.unsendable')}
        </Text>
      ) : null}
      {attachments.length > 0 ? (
        <Text
          accessibilityRole="header"
          style={[styles.label, { color: colors.textSecondary }]}>
          {t('drafts.assets.attachments')}
        </Text>
      ) : null}
      {rows(attachments, false)}
      {images.length > 0 ? (
        <Text
          accessibilityRole="header"
          style={[styles.label, { color: colors.textSecondary }]}>
          {t('drafts.assets.inlineImages')}
        </Text>
      ) : null}
      {rows(images, true)}
    </View>
  );
}

// A reply's or forward's quoted correspondence, read-only beneath the authored body when shown.
function QuotedText({ quoted }: { readonly quoted: SemanticDocument }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [shown, setShown] = useState(false);
  return (
    <View>
      <Pressable
        accessibilityRole="button"
        accessibilityState={{ expanded: shown }}
        onPress={() => {
          setShown((current) => !current);
        }}>
        <Text style={[styles.notice, { color: colors.accentInk }]}>
          {shown
            ? t('drafts.response.hideQuoted')
            : t('drafts.response.showQuoted')}
        </Text>
      </Pressable>
      {shown ? (
        <Text
          selectable
          style={[styles.quoted, { color: colors.textSecondary }]}>
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
  const colors = usePalette();
  const { t } = useLocalization();
  const provider = use(AccountContext)?.mailboxes.find(
    ({ id }) => id === connection,
  )?.provider;
  return refused === undefined ? null : (
    <Text
      accessibilityRole="alert"
      style={[styles.notice, { color: colors.textPrimary }]}>
      {t(
        refused === 'too-large'
          ? tooLarge[provider ?? 'gmail']
          : `drafts.sendRefused.${refused}`,
      )}
    </Text>
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

function Editor({
  initial,
  onClose,
  onRebind,
}: {
  readonly initial: Draft;
  readonly onClose: () => void;
  // Another editor changed this Draft first, so this editor's version is now the copy `id`.
  readonly onRebind: (id: string) => void;
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
  // The wrapper calls onChange before onChangeText for the same native edit.
  const changedSelection = useRef<Selection | undefined>(undefined);
  // Where the editor must place the caret after a change it did not type itself.
  const [placed, setPlaced] = useState<Selection>();
  // Marks toggled at a caret apply to the text typed there next.
  const [typing, setTyping] = useState<readonly Mark[]>();
  const typingNow = useRef(typing);
  const placeTyping = (next: readonly Mark[] | undefined) => {
    typingNow.current = next;
    setTyping(next);
  };
  const [closing, setClosing] = useState<
    'saving' | 'blocked' | 'discard-blocked' | 'discard' | 'recipients'
  >();
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
    const after = changedSelection.current;
    changedSelection.current = undefined;
    // Forward deletion leaves the caret in place. Backspace moves it, even without a key event.
    const forward =
      at.start === at.end &&
      text.length < textBefore.length &&
      after?.start === at.start &&
      after.end === at.start;
    const result = applyText(latest.body, text, {
      marks: typingNow.current,
      selection: at,
      ...(forward ? { deletion: 'forward' } : {}),
    });
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
      return 'failed' as const;
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
    return 'failed' as const;
  }, [commitHistory, finishOperation, keepIdentity, onClose, store, update]);
  const navigation = useComposerNavigation();
  useLayoutEffect(() => navigation.register(close), [navigation, close]);
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

  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <ScrollView
        automaticallyAdjustKeyboardInsets
        contentContainerStyle={styles.content}
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled">
        <View style={styles.bar}>
          <Action
            disabled={closing === 'saving'}
            label={t('drafts.close')}
            onPress={() => {
              void close();
            }}
          />
          <Text
            accessibilityLabel={titleLabel}
            accessibilityRole="header"
            numberOfLines={1}
            style={[
              styles.grow,
              styles.actionText,
              { color: colors.textPrimary, fontWeight: '600' },
            ]}>
            {title}
          </Text>
          <Action
            disabled={lockedUnless(history.past.length > 0)}
            label={t('drafts.undo')}
            onPress={() => {
              travel(undo);
            }}
          />
          <Action
            disabled={lockedUnless(history.future.length > 0)}
            label={t('drafts.redo')}
            onPress={() => {
              travel(redo);
            }}
          />
          <Action
            destructive
            disabled={sending}
            label={t('drafts.discard')}
            onPress={() => {
              if (!sendingNow.current) {
                setClosing('discard');
              }
            }}
          />
          <Action
            disabled={closing === 'saving'}
            label={t('drafts.send')}
            onPress={() => {
              void send();
            }}
          />
        </View>
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.status, { color: colors.textSecondary }]}>
          {t('drafts.status', { status: t(`drafts.save.${save}`) })}
        </Text>
        {closing === 'blocked' || closing === 'discard-blocked' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.textPrimary },
              ]}>
              {closing === 'discard-blocked'
                ? t('drafts.discardBlocked')
                : t('drafts.saveBlocked')}
            </Text>
            <Action
              label={t('common.retry')}
              onPress={() => {
                void (closing === 'discard-blocked' ? discard() : close());
              }}
            />
          </View>
        ) : null}
        {closing === 'recipients' ? (
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.textPrimary }]}>
            {t('drafts.invalidRecipients')}
          </Text>
        ) : null}
        <SendRefusalNotice
          connection={draft.connection}
          refused={refused}
        />
        {closing === 'discard' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.textPrimary },
              ]}>
              {t('drafts.discardConfirm')}
            </Text>
            <Action
              destructive
              label={t('drafts.discardDraft')}
              onPress={() => {
                void discard();
              }}
            />
            <Action
              label={t('drafts.keepEditing')}
              onPress={() => {
                setClosing(undefined);
              }}
            />
          </View>
        ) : null}
        <SendingMailbox
          draft={draft}
          editable={!sending}
          onChange={(mailbox) => {
            change(withSender(authored.current, mailbox));
          }}
        />
        <Recipients
          draft={draft}
          getDraft={getDraft}
          editable={!sending}
          field="to"
          onChange={change}
          onCaretMove={breakTyping}
        />
        {draft.copies === true || draft.cc.length + draft.bcc.length > 0 ? (
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
        ) : (
          <Action
            disabled={sending}
            accessibilityLabel={t('drafts.showCcBcc')}
            label={t('drafts.ccBcc')}
            onPress={() => {
              change({ ...authored.current, copies: true });
            }}
          />
        )}
        <View style={styles.field}>
          <TextInput
            accessibilityLabel={t('drafts.subject')}
            editable={!sending}
            accessibilityState={{ disabled: sending }}
            onChangeText={(subject) => {
              const previous = authored.current.subject;
              subjectCaret.current =
                subjectSelection.current.end + subject.length - previous.length;
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
        <View
          accessibilityLabel={t('drafts.formatting')}
          accessibilityRole="toolbar"
          style={styles.bar}>
          {markControls.map(([mark, label, name, style]) => (
            <Pressable
              key={mark}
              accessibilityLabel={t(name)}
              accessibilityRole="button"
              accessibilityState={{
                selected: active.includes(mark),
                disabled: sending,
              }}
              disabled={sending}
              onPress={() => {
                format(mark);
              }}
              style={[
                styles.format,
                {
                  backgroundColor: active.includes(mark)
                    ? colors.accentSelectionSubtle
                    : 'transparent',
                },
              ]}>
              <Text style={[{ color: colors.textPrimary }, style]}>
                {label}
              </Text>
            </Pressable>
          ))}
          {blockControls.map(([value, label, name]) => (
            <Pressable
              key={value}
              accessibilityLabel={t(name)}
              accessibilityRole="button"
              accessibilityState={{
                selected: kind === value,
                disabled: sending,
              }}
              disabled={sending}
              onPress={() => {
                block(value);
              }}
              style={[
                styles.format,
                {
                  backgroundColor:
                    kind === value
                      ? colors.accentSelectionSubtle
                      : 'transparent',
                },
              ]}>
              <Text style={{ color: colors.textPrimary }}>{label}</Text>
            </Pressable>
          ))}
          {translation === undefined ? null : (
            <Action
              disabled={lockedUnless(
                hasTranslatableText(
                  selectedText(
                    draft.body,
                    selection,
                    translationInputLimit + 1,
                  ),
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
              <Action
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
                <Action
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
        </View>
        <View
          accessibilityLabel={t('drafts.assets.toolbar')}
          accessibilityRole="toolbar"
          style={styles.bar}>
          <Action
            disabled={sending}
            label={t('drafts.assets.attachFile')}
            onPress={() => {
              void choose('files', false);
            }}
          />
          <Action
            disabled={sending}
            label={t('drafts.assets.attachPhoto')}
            onPress={() => {
              void choose('photos', false);
            }}
          />
          <Action
            disabled={sending}
            label={t('drafts.assets.insertImage')}
            onPress={() => {
              void choose('photos', true);
            }}
          />
          <Action
            disabled={sending}
            label={t('drafts.assets.pasteImage')}
            onPress={() => {
              void choose('paste', true);
            }}
          />
        </View>
        {captured === undefined ? null : (
          <CapturedAssistance
            key={captured.id}
            captured={captured}
            assistance={assistance}
            translation={translation}
            onApply={applyCaptured}
            onClose={closeCaptured}
          />
        )}
        <TextInput
          accessibilityLabel={t('drafts.body')}
          editable={!sending}
          accessibilityState={{ disabled: sending }}
          multiline
          onChange={({ nativeEvent }: BodyChangeEvent) => {
            changedSelection.current = nativeEvent.selection;
          }}
          onChangeText={edit}
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
      </ScrollView>
    </SafeAreaView>
  );
}

// Opens a Draft directly for editing; it has no read-only presentation.
export function Composer({
  id,
  onClose,
  onRebind,
}: {
  readonly id: string;
  readonly onClose: () => void;
  // Follows the editor to its conflicting copy without reopening it.
  readonly onRebind: (id: string) => void;
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
        onClose={onClose}
        onRebind={rebind}
      />
    );
  }
  const waiting = state.kind === 'loading';
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <View style={styles.content}>
        {waiting ? (
          <ActivityIndicator accessibilityLabel={t('drafts.loading')} />
        ) : (
          <>
            <Text
              accessibilityRole="header"
              style={[styles.actionText, { color: colors.textPrimary }]}>
              {state.kind === 'locked'
                ? t('drafts.listLocked')
                : t('drafts.unavailable')}
            </Text>
            {state.kind === 'locked' || state.kind === 'failed' ? (
              <Action
                label={t('common.retry')}
                onPress={() => {
                  void store.load();
                }}
              />
            ) : null}
            <Action
              label={t('drafts.close')}
              onPress={onClose}
            />
          </>
        )}
      </View>
    </SafeAreaView>
  );
}
