import type { Translate } from '@private-email/localization';
import type {
  AssetPreview,
  Draft,
  PickedFile,
  PickSource,
  RecipientField,
  RecipientNotice,
} from '@private-email/mail-core/drafts';
import type { SendRefusal } from '@private-email/mail-core/outbox';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  Asset,
  BlockKind,
  Mark,
  Selection,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';
import type { StyleProp, TextInputChangeEvent, TextStyle } from 'react-native';

import {
  addRecipients,
  draftOf,
  entryOf,
  isEmptyDraft,
  recipientLabel,
  draftSummary,
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
import { spacing } from '@private-email/mail-core/theme';
import {
  draftReplacement,
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

import { useLocalization } from './localization.ts';
import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useLeaveComposer,
  useOutbox,
} from './mailbox.tsx';
import { fileSize } from './message-body.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';
import { DraftTranslation } from './translation.tsx';

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
    padding: spacing.large,
    gap: spacing.medium,
  },
  bar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.small,
  },
  grow: { flex: 1 },
  editing: { gap: spacing.medium },
  action: { minHeight: 44, justifyContent: 'center', paddingHorizontal: 8 },
  actionText: { fontSize: 16 },
  status: { fontSize: 13 },
  label: { fontSize: 13, fontWeight: '600' },
  field: {
    gap: 6,
    paddingBottom: spacing.small,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  input: { fontSize: 17, minHeight: 44, paddingVertical: 8 },
  tokens: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  token: {
    minHeight: 32,
    justifyContent: 'center',
    paddingHorizontal: 10,
    borderRadius: 16,
  },
  notice: { fontSize: 14 },
  quoted: { fontSize: 15, lineHeight: 22, paddingVertical: 8 },
  choice: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: 12,
    borderWidth: 2,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  format: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 8,
  },
  body: { fontSize: 17, lineHeight: 26, minHeight: 240, paddingVertical: 8 },
  section: {
    fontSize: 13,
    fontWeight: '600',
    paddingHorizontal: spacing.large,
    paddingTop: spacing.small,
  },
  row: {
    marginHorizontal: spacing.small,
    padding: 14,
    gap: 4,
    borderWidth: 2,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  rowTitle: { flexDirection: 'row', gap: spacing.small, alignItems: 'center' },
  badge: { fontSize: 12, fontWeight: '700' },
  rowSubject: { flex: 1, fontSize: 15, fontWeight: '500' },
  rowDetail: { fontSize: 13 },
  footer: { fontSize: 13, paddingHorizontal: spacing.large },
  asset: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.small,
    paddingVertical: 4,
  },
  thumbnail: { width: 64, height: 64, borderRadius: 6 },
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

const markControls: ReadonlyArray<
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

const blockControls: ReadonlyArray<readonly [BlockKind, string, BlockName]> = [
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
  let color = destructive ? colors.destructive : colors.accent;
  if (disabled) {
    color = colors.secondary;
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
          backgroundColor: selected ? colors.selected : colors.sidebar,
          borderColor: 'transparent',
        },
      ]}>
      <View style={styles.rowTitle}>
        <Text style={[styles.badge, { color: colors.accent }]}>
          {draft.conflict === true
            ? t('drafts.conflictBadge')
            : t('drafts.badge')}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.rowSubject, { color: colors.foreground }]}>
          {subject}
        </Text>
      </View>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: colors.secondary }]}>
        {recipients}
      </Text>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: colors.secondary }]}>
        {t('drafts.from', { from })}
      </Text>
      {preview === '' ? null : (
        <Text
          numberOfLines={1}
          style={[styles.rowDetail, { color: colors.secondary }]}>
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
  const store = useDraftStore();
  const state = useDrafts();
  const colors = usePalette();
  const { t } = useLocalization();
  const navigation = useComposerNavigation();
  const creating = useRef(false);
  const [creatingShown, setCreatingShown] = useState(false);
  if (account === undefined || state.kind === 'closed') {
    return null;
  }
  const senders = sendingMailboxes(account.mailboxes);
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
      <View style={[styles.bar, { paddingHorizontal: spacing.large }]}>
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
        <View style={[styles.bar, { paddingHorizontal: spacing.large }]}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.foreground }]}>
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
        <View style={[styles.bar, { paddingHorizontal: spacing.large }]}>
          <Text
            accessibilityRole="alert"
            style={[styles.notice, styles.grow, { color: colors.foreground }]}>
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
      style={[styles.section, { color: colors.secondary }]}>
      {t('drafts.heading')}
    </Text>
  );
}

function SendingMailbox({
  draft,
  onChange,
}: {
  readonly draft: Draft;
  readonly onChange: (mailbox: MailboxConnection) => void;
}) {
  const account = use(AccountContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const mailboxes = account?.mailboxes ?? [];
  const state = sendingStateOf(draft, mailboxes);
  const senders = sendingMailboxes(mailboxes);
  const from = clip(draft.from);
  return (
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.secondary }]}>
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
            <Text style={{ color: colors.secondary }}>{from}</Text>
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
              accessibilityState={{ selected }}
              onPress={() => {
                onChange(mailbox);
              }}
              style={[
                styles.choice,
                {
                  backgroundColor: selected ? colors.selected : colors.sidebar,
                  borderColor: selected ? colors.accent : 'transparent',
                },
              ]}>
              <Text style={{ color: colors.foreground }}>{address}</Text>
            </Pressable>
          );
        })}
      </View>
      {state === 'available' ? null : (
        <Text
          accessibilityRole="alert"
          style={[styles.notice, { color: colors.foreground }]}>
          {t(`drafts.sending.${state}`)}
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
      <Text style={[styles.label, { color: colors.secondary }]}>{name}</Text>
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
            style={[styles.token, { backgroundColor: colors.selected }]}>
            <Text style={{ color: colors.foreground }}>
              {`${recipient.name ?? recipient.address} ×`}
            </Text>
          </Pressable>
        ))}
      </View>
      <TextInput
        accessibilityLabel={name}
        editable={editable}
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
        placeholderTextColor={colors.secondary}
        returnKeyType="next"
        style={[styles.input, { color: colors.foreground }]}
        textContentType="emailAddress"
        value={entryOf(draft, field)}
      />
      {notice === undefined ? null : (
        <Text
          accessibilityLiveRegion="polite"
          style={[styles.notice, { color: colors.foreground }]}>
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
  inline,
  running,
  onRemove,
  onCancel,
}: {
  readonly asset: Asset;
  readonly inline: boolean;
  readonly running: boolean;
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
        <Text style={{ color: colors.foreground }}>{asset.name}</Text>
        <Text style={[styles.status, { color: colors.secondary }]}>
          {status}
        </Text>
      </View>
      {preview?.kind === 'locked' || preview?.kind === 'incomplete' ? (
        <Action
          accessibilityLabel={t('drafts.assets.retryLabel', {
            name: asset.name,
          })}
          label={t('common.retry')}
          onPress={retry}
        />
      ) : null}
      {running ? (
        <Action
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
  onRemove,
  onCancel,
}: {
  readonly draft: Draft;
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
          style={[styles.notice, { color: colors.foreground }]}>
          {t('drafts.assets.unsendable')}
        </Text>
      ) : null}
      {attachments.length > 0 ? (
        <Text
          accessibilityRole="header"
          style={[styles.label, { color: colors.secondary }]}>
          {t('drafts.assets.attachments')}
        </Text>
      ) : null}
      {rows(attachments, false)}
      {images.length > 0 ? (
        <Text
          accessibilityRole="header"
          style={[styles.label, { color: colors.secondary }]}>
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
        <Text style={[styles.notice, { color: colors.accent }]}>
          {shown
            ? t('drafts.response.hideQuoted')
            : t('drafts.response.showQuoted')}
        </Text>
      </Pressable>
      {shown ? (
        <Text
          selectable
          style={[styles.quoted, { color: colors.secondary }]}>
          {displayOf(quoted).text.replaceAll(imageCharacter, '')}
        </Text>
      ) : null}
    </View>
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
  // Body text captured for an explicitly requested translation, until it is applied or kept.
  const [translating, setTranslating] = useState<
    Readonly<{
      body: Draft['body'];
      selection: Selection;
      text: string;
      id: number;
    }>
  >();
  const captureNow = useRef<typeof translating>(undefined);
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
  const outbox = useOutbox();
  const caret = useRef<number | undefined>(undefined);
  const typingField = useRef<string | undefined>(undefined);
  const subjectSelection = useRef<Selection>({ start: 0, end: 0 });
  const subjectCaret = useRef<number | undefined>(undefined);
  const draft = history.present;
  // Any body edit makes the captured text stale, so its translation is forgotten.
  if (translating !== undefined && translating.body !== draft.body) {
    setTranslating(undefined);
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
      if (bound.body !== previous.body) {
        captureNow.current = undefined;
        setTranslating(undefined);
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
    commitHistory((current) => keepIdentity(step(current)));
    placeTyping(undefined);
    update(historyNow.current.present);
  };
  const edit = (text: string) => {
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
    const at = selectionNow.current;
    const latest = authored.current;
    if (at.start === at.end) {
      placeTyping(toggled(typingNow.current ?? marksAt(latest.body, at), mark));
      return;
    }
    change({ ...latest, body: toggleMark(latest.body, at, mark) });
  };
  // Replaces exactly the captured selection with its reviewed translation as one undoable edit.
  // Recipients, attachments and delivery state are left as they are.
  const applyTranslation = (translated: string) => {
    const latest = authored.current;
    if (
      !lifetime.current.mounted ||
      translating === undefined ||
      captureNow.current !== translating ||
      latest.body !== translating.body
    ) {
      return;
    }
    captureNow.current = undefined;
    setTranslating(undefined);
    const result = replaceSelection(
      latest.body,
      translating.selection,
      draftReplacement(translating.text, translated),
    );
    change({ ...latest, body: result.document });
    placeTyping(undefined);
    selectionNow.current = result.selection ?? selectionNow.current;
    setPlaced(result.selection);
  };
  const block = (kind: BlockKind) => {
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
    setSending(true);
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
      style={[styles.fill, { backgroundColor: colors.background }]}>
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
              { color: colors.foreground, fontWeight: '600' },
            ]}>
            {title}
          </Text>
          <Action
            disabled={sending || history.past.length === 0}
            label={t('drafts.undo')}
            onPress={() => {
              travel(undo);
            }}
          />
          <Action
            disabled={sending || history.future.length === 0}
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
              setClosing('discard');
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
          style={[styles.status, { color: colors.secondary }]}>
          {t('drafts.status', { status: t(`drafts.save.${save}`) })}
        </Text>
        {closing === 'blocked' || closing === 'discard-blocked' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.foreground },
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
            style={[styles.notice, { color: colors.foreground }]}>
            {t('drafts.invalidRecipients')}
          </Text>
        ) : null}
        {refused === undefined ? null : (
          <Text
            accessibilityRole="alert"
            style={[styles.notice, { color: colors.foreground }]}>
            {t(`drafts.sendRefused.${refused}`)}
          </Text>
        )}
        {closing === 'discard' ? (
          <View style={styles.bar}>
            <Text
              accessibilityRole="alert"
              style={[
                styles.notice,
                styles.grow,
                { color: colors.foreground },
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
        <View
          pointerEvents={sending ? 'none' : 'auto'}
          style={styles.editing}>
          <SendingMailbox
            draft={draft}
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
              placeholderTextColor={colors.secondary}
              style={[styles.input, { color: colors.foreground }]}
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
                accessibilityState={{ selected: active.includes(mark) }}
                onPress={() => {
                  format(mark);
                }}
                style={[
                  styles.format,
                  {
                    backgroundColor: active.includes(mark)
                      ? colors.selected
                      : 'transparent',
                  },
                ]}>
                <Text style={[{ color: colors.foreground }, style]}>
                  {label}
                </Text>
              </Pressable>
            ))}
            {blockControls.map(([value, label, name]) => (
              <Pressable
                key={value}
                accessibilityLabel={t(name)}
                accessibilityRole="button"
                accessibilityState={{ selected: kind === value }}
                onPress={() => {
                  block(value);
                }}
                style={[
                  styles.format,
                  {
                    backgroundColor:
                      kind === value ? colors.selected : 'transparent',
                  },
                ]}>
                <Text style={{ color: colors.foreground }}>{label}</Text>
              </Pressable>
            ))}
            <Action
              disabled={
                !hasTranslatableText(
                  selectedText(
                    draft.body,
                    selection,
                    translationInputLimit + 1,
                  ),
                )
              }
              label={t('translation.translate')}
              accessibilityLabel={t('translation.translateSelectionLabel')}
              onPress={() => {
                const at = selectionNow.current;
                const { body } = authored.current;
                const text = selectedText(body, at, translationInputLimit + 1);
                if (!lifetime.current.mounted || !hasTranslatableText(text)) {
                  return;
                }
                captureGeneration.current += 1;
                const capture = {
                  body,
                  selection: at,
                  text,
                  id: captureGeneration.current,
                };
                captureNow.current = capture;
                setTranslating(capture);
              }}
            />
          </View>
          <View
            accessibilityLabel={t('drafts.assets.toolbar')}
            accessibilityRole="toolbar"
            style={styles.bar}>
            <Action
              label={t('drafts.assets.attachFile')}
              onPress={() => {
                void choose('files', false);
              }}
            />
            <Action
              label={t('drafts.assets.attachPhoto')}
              onPress={() => {
                void choose('photos', false);
              }}
            />
            <Action
              label={t('drafts.assets.insertImage')}
              onPress={() => {
                void choose('photos', true);
              }}
            />
            <Action
              label={t('drafts.assets.pasteImage')}
              onPress={() => {
                void choose('paste', true);
              }}
            />
          </View>
          {translating === undefined ? null : (
            <DraftTranslation
              key={translating.id}
              text={translating.text}
              onApply={applyTranslation}
              onClose={() => {
                if (captureNow.current === translating) {
                  captureNow.current = undefined;
                  setTranslating(undefined);
                }
              }}
            />
          )}
          <TextInput
            accessibilityLabel={t('drafts.body')}
            editable={!sending}
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
            placeholderTextColor={colors.secondary}
            scrollEnabled={false}
            selection={placed}
            style={[styles.body, { color: colors.foreground }]}
            textAlignVertical="top">
            {display.lines.map((line, index) => (
              <Text
                // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
                key={index}
                style={[
                  kindStyles[line.kind],
                  line.kind === 'quote' ? { color: colors.secondary } : null,
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
            onCancel={(id) => {
              void store.cancelImport(id);
            }}
            onRemove={removeAsset}
          />
        </View>
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
      style={[styles.fill, { backgroundColor: colors.background }]}>
      <View style={styles.content}>
        {waiting ? (
          <ActivityIndicator accessibilityLabel={t('drafts.loading')} />
        ) : (
          <>
            <Text
              accessibilityRole="header"
              style={[styles.actionText, { color: colors.foreground }]}>
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
