import type {
  Draft,
  RecipientField,
  RecipientNotice,
} from '@private-email/mail-core/drafts';
import type { MailboxConnection } from '@private-email/mail-core/registration';
import type {
  BlockKind,
  Mark,
  Selection,
} from '@private-email/mail-core/semantic-document';
import type { KeyEvent, StyleProp, TextStyle } from 'react-native';

import {
  addRecipients,
  draftOf,
  entryOf,
  draftsOf,
  isEmptyDraft,
  recipientCopy,
  recipientLabel,
  sendingCopy,
  sendingMailboxes,
  sendingStateOf,
} from '@private-email/mail-core/drafts';
import {
  applyText,
  blockKindAt,
  displayOf,
  historyOf,
  marksAt,
  plainText,
  record,
  redo,
  setBlockKind,
  toggled,
  toggleMark,
  undo,
} from '@private-email/mail-core/semantic-document';
import { spacing } from '@private-email/mail-core/theme';
import {
  memo,
  use,
  useCallback,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  useComposerNavigation,
  useDrafts,
  useDraftStore,
  useLeaveComposer,
} from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { usePalette } from './theme.ts';

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

const markControls: ReadonlyArray<
  readonly [Mark, string, string, StyleProp<TextStyle>]
> = [
  ['bold', 'B', 'Bold', { fontWeight: '700' }],
  ['italic', 'I', 'Italic', { fontStyle: 'italic' }],
  ['underline', 'U', 'Underline', { textDecorationLine: 'underline' }],
  [
    'strikethrough',
    'S',
    'Strikethrough',
    { textDecorationLine: 'line-through' },
  ],
  ['code', '</>', 'Inline code', { fontFamily: 'Menlo' }],
];

const blockControls: ReadonlyArray<readonly [BlockKind, string, string]> = [
  ['heading1', 'H1', 'Heading 1'],
  ['heading2', 'H2', 'Heading 2'],
  ['heading3', 'H3', 'Heading 3'],
  ['bulleted', '•', 'Bulleted list'],
  ['numbered', '1.', 'Numbered list'],
  ['quote', '❝', 'Quote'],
  ['code', '{ }', 'Code block'],
];

const saveCopy = {
  saved: 'Saved on this device',
  saving: 'Saving…',
  failed: 'Not saved. Your changes are kept here until saving succeeds.',
  locked: 'Not saved while private storage is locked. Unlock your device.',
} as const;

const fieldNames: Record<RecipientField, string> = {
  to: 'To',
  cc: 'Cc',
  bcc: 'Bcc',
};

const recipientSummary = (draft: Draft) => {
  const all = [...draft.to, ...draft.cc, ...draft.bcc];
  return all.length === 0
    ? 'No recipients'
    : `To ${all.map(({ name, address }) => name ?? address).join(', ')}`;
};

// React Native macOS exposes plain Text to accessibility only through an accessible parent.
function Notice({
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
];

function Action({
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
  return (
    <Pressable
      accessibilityLabel={`${draft.conflict === true ? 'Conflicting Draft' : 'Draft'}. ${draft.subject || 'No subject'}. ${recipientSummary(draft)}. From ${draft.from}`}
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
          {draft.conflict === true ? 'DRAFT · CONFLICT' : 'DRAFT'}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.rowSubject, { color: colors.foreground }]}>
          {draft.subject || 'No subject'}
        </Text>
      </View>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: colors.secondary }]}>
        {recipientSummary(draft)}
      </Text>
      <Text
        numberOfLines={1}
        style={[styles.rowDetail, { color: colors.secondary }]}>
        {plainText(draft.body).replaceAll('\n', ' ') || `From ${draft.from}`}
      </Text>
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
      if (id !== composing && (await leave())) {
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
  const leave = useLeaveComposer();
  if (account === undefined || state.kind === 'closed') {
    return null;
  }
  const senders = sendingMailboxes(account.mailboxes);
  const sender = senders.find(({ id }) => id === scope) ?? senders[0];
  const drafts = draftsOf(state);
  const compose = async (mailbox: MailboxConnection) => {
    if (!(await leave())) {
      return;
    }
    const id = await store.create(mailbox);
    if (id !== undefined) {
      onCompose(id);
    }
  };
  return (
    <View>
      <View style={[styles.bar, { paddingHorizontal: spacing.large }]}>
        <Action
          disabled={state.kind !== 'ready' || sender === undefined}
          label="New Message"
          onPress={() => {
            if (sender !== undefined) {
              void compose(sender);
            }
          }}
        />
      </View>
      {state.kind === 'locked' || state.kind === 'failed' ? (
        <View style={[styles.bar, { paddingHorizontal: spacing.large }]}>
          <Notice
            alert
            style={[styles.notice, { color: colors.foreground }]}>
            {state.kind === 'locked'
              ? 'Drafts are locked. Unlock your device and try again.'
              : 'Drafts could not be opened. They have been kept.'}
          </Notice>
          <Action
            label="Try again"
            onPress={() => {
              void store.load();
            }}
          />
        </View>
      ) : null}
      {drafts.length === 0 ? null : (
        <View
          accessible
          accessibilityLabel="Drafts"
          accessibilityRole="header">
          <Text style={[styles.section, { color: colors.secondary }]}>
            Drafts
          </Text>
        </View>
      )}
    </View>
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
  const mailboxes = account?.mailboxes ?? [];
  const state = sendingStateOf(draft, mailboxes);
  const senders = sendingMailboxes(mailboxes);
  return (
    <View style={styles.field}>
      <Text style={[styles.label, { color: colors.secondary }]}>From</Text>
      <View style={styles.bar}>
        {state === 'available' ? null : (
          <View
            accessibilityLabel={`${draft.from}, cannot send`}
            style={[styles.choice, { borderColor: colors.separator }]}>
            <Text style={{ color: colors.secondary }}>{draft.from}</Text>
          </View>
        )}
        {senders.map((mailbox) => {
          const selected =
            state === 'available' && mailbox.id === draft.connection;
          return (
            <Pressable
              key={mailbox.id}
              accessibilityLabel={`Send from ${mailbox.address}`}
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
              <Text style={{ color: colors.foreground }}>
                {mailbox.address}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {state === 'available' ? null : (
        <Notice
          alert
          style={[styles.notice, { color: colors.foreground }]}>
          {sendingCopy[state]}
        </Notice>
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
}: {
  readonly draft: Draft;
  readonly getDraft: () => Draft;
  readonly field: RecipientField;
  // A typing step when only the unfinished entry changed.
  readonly onChange: (draft: Draft, typing: boolean, field: string) => void;
  readonly onCaretMove: () => void;
}) {
  const colors = usePalette();
  const [notice, setNotice] = useState<RecipientNotice>();
  const selection = useRef<Selection>({ start: 0, end: 0 });
  const caret = useRef<number | undefined>(undefined);
  const name = fieldNames[field];
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
            accessibilityHint="Removes this recipient"
            accessibilityLabel={`${name}: ${recipientLabel(recipient)}`}
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
        placeholder="Name or email address"
        placeholderTextColor={colors.secondary}
        returnKeyType="next"
        style={[styles.input, { color: colors.foreground }]}
        textContentType="emailAddress"
        value={entryOf(draft, field)}
      />
      {notice === undefined ? null : (
        <Notice style={[styles.notice, { color: colors.foreground }]}>
          {recipientCopy[notice]}
        </Notice>
      )}
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
  const [history, setHistory] = useState(() => historyOf(initial));
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
  const rebind = useCallback(
    (id: string) => {
      const bound = (each: Draft): Draft => ({ ...each, id, conflict: true });
      authored.current = bound(authored.current);
      setHistory((current) => ({
        ...current,
        past: current.past.map(bound),
        present: bound(current.present),
        future: current.future.map(bound),
      }));
      onRebind(id);
    },
    [onRebind],
  );
  const [selection, setSelection] = useState<Selection>({ start: 0, end: 0 });
  // Where the editor must place the caret after a change it did not type itself.
  const [placed, setPlaced] = useState<Selection>();
  // Marks toggled at a caret apply to the text typed there next.
  const [typing, setTyping] = useState<readonly Mark[]>();
  const [closing, setClosing] = useState<
    'saving' | 'blocked' | 'discard-blocked' | 'discard' | 'recipients'
  >();
  const caret = useRef<number | undefined>(undefined);
  const typingField = useRef<string | undefined>(undefined);
  const subjectSelection = useRef<Selection>({ start: 0, end: 0 });
  const subjectCaret = useRef<number | undefined>(undefined);
  const deletion = useRef<'backward' | 'forward' | undefined>(undefined);
  const draft = history.present;
  const breakTyping = () => {
    setHistory((current) => ({ ...current, typing: false }));
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
      authored.current = bound;
      if (!discarded.current) {
        void store.update(bound, previous, rebind);
      }
    },
    [rebind, store],
  );
  const change = (next: Draft, word = false, field?: string) => {
    const continuing = typingField.current === field;
    setHistory((current) =>
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
  const travel = (to: typeof history) => {
    setHistory(() => keepIdentity(to));
    setTyping(undefined);
    update(to.present);
  };
  const edit = (text: string) => {
    const latest = authored.current;
    const textBefore = displayOf(latest.body).text;
    const result = applyText(latest.body, text, {
      marks: typing,
      selection,
      deletion: deletion.current,
    });
    deletion.current = undefined;
    // One character added after the caret continues a typing step until a word ends.
    const added = text.length === textBefore.length + 1;
    const word = added && !/\s/u.test(text[selection.start] ?? ' ');
    caret.current = selection.end + text.length - textBefore.length;
    if (result.literal === undefined) {
      change({ ...latest, body: result.document }, word, 'body');
    } else {
      // The literal marker is its own step, so one Undo restores it.
      const { literal } = result;
      setHistory((current) =>
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
      setPlaced(result.selection);
    }
  };
  const format = (mark: Mark) => {
    const latest = authored.current;
    if (selection.start === selection.end) {
      setTyping(toggled(typing ?? marksAt(latest.body, selection), mark));
      return;
    }
    change({ ...latest, body: toggleMark(latest.body, selection, mark) });
  };
  const block = (kind: BlockKind) => {
    const latest = authored.current;
    const result = setBlockKind(latest.body, selection, kind);
    change({ ...latest, body: result.document });
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
      setHistory((current) => keepIdentity(record(current, finished)));
      update(finished);
    }
    if (finished.entries !== undefined) {
      setClosing('recipients');
      return false;
    }
    setClosing('saving');
    if (isEmptyDraft(finished)) {
      if (await store.discard(authored.current.id, { onlyIfEmpty: true })) {
        onClose();
        return true;
      }
      setClosing('blocked');
      return false;
    }
    if (await store.save()) {
      onClose();
      return true;
    }
    setClosing('blocked');
    return false;
  }, [keepIdentity, onClose, store, update]);
  const navigation = useComposerNavigation();
  useLayoutEffect(() => navigation.register(close), [navigation, close]);
  const keyDown = ({ nativeEvent }: KeyEvent) => {
    deletion.current = undefined;
    if (nativeEvent.key === 'Delete') {
      deletion.current = 'forward';
    } else if (nativeEvent.key === 'Backspace') {
      deletion.current = 'backward';
    }
    if (!nativeEvent.metaKey) {
      return;
    }
    if (nativeEvent.key === 'z') {
      travel(nativeEvent.shiftKey ? redo(history) : undo(history));
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
    let removed = false;
    try {
      removed = await store.discard(previous.id);
    } catch {
      // An unexpected storage rejection leaves the editor retryable too.
    }
    if (!removed) {
      discarded.current = false;
      if (authored.current !== previous) {
        void store.update(authored.current, previous, rebind);
      }
      setClosing('discard-blocked');
    }
    if (removed) {
      onClose();
    }
  };
  const active = typing ?? marksAt(draft.body, selection);
  const kind = blockKindAt(draft.body, selection.start);

  return (
    <View style={[styles.fill, { backgroundColor: colors.background }]}>
      <ScrollView contentContainerStyle={styles.content}>
        <View style={styles.bar}>
          <Action
            disabled={closing === 'saving'}
            label="Close"
            onPress={() => {
              void close();
            }}
          />
          <View
            accessible
            accessibilityLabel={draft.subject || 'New Message'}
            accessibilityRole="header"
            style={styles.grow}>
            <Text
              numberOfLines={1}
              style={[
                styles.actionText,
                { color: colors.foreground, fontWeight: '600' },
              ]}>
              {draft.subject || 'New Message'}
            </Text>
          </View>
          <Action
            disabled={history.past.length === 0}
            label="Undo"
            onPress={() => {
              travel(undo(history));
            }}
          />
          <Action
            disabled={history.future.length === 0}
            label="Redo"
            onPress={() => {
              travel(redo(history));
            }}
          />
          <Action
            destructive
            label="Discard"
            onPress={() => {
              setClosing('discard');
            }}
          />
        </View>
        <Notice style={[styles.status, { color: colors.secondary }]}>
          {`Draft · ${saveCopy[save]}`}
        </Notice>
        {closing === 'blocked' || closing === 'discard-blocked' ? (
          <View style={styles.bar}>
            <Notice
              alert
              style={[styles.notice, { color: colors.foreground }]}>
              {closing === 'discard-blocked'
                ? 'This Draft could not be discarded, so it stays open. Try again.'
                : 'This Draft could not be saved, so it stays open. Try again, or discard it.'}
            </Notice>
            <Action
              label="Try again"
              onPress={() => {
                void (closing === 'discard-blocked' ? discard() : close());
              }}
            />
          </View>
        ) : null}
        {closing === 'recipients' ? (
          <Notice
            alert
            style={[styles.notice, { color: colors.foreground }]}>
            Correct or remove the invalid address to close this Draft.
          </Notice>
        ) : null}
        {closing === 'discard' ? (
          <View style={styles.bar}>
            <Notice
              alert
              style={[styles.notice, { color: colors.foreground }]}>
              Discard this Draft? It is deleted from this device.
            </Notice>
            <Action
              destructive
              label="Discard Draft"
              onPress={() => {
                void discard();
              }}
            />
            <Action
              label="Keep Editing"
              onPress={() => {
                setClosing(undefined);
              }}
            />
          </View>
        ) : null}
        <SendingMailbox
          draft={draft}
          onChange={(mailbox) => {
            change({
              ...authored.current,
              connection: mailbox.id,
              from: mailbox.address,
            });
          }}
        />
        <Recipients
          draft={draft}
          getDraft={getDraft}
          field="to"
          onChange={change}
          onCaretMove={breakTyping}
        />
        {draft.copies === true || draft.cc.length + draft.bcc.length > 0 ? (
          <>
            <Recipients
              draft={draft}
              getDraft={getDraft}
              field="cc"
              onChange={change}
              onCaretMove={breakTyping}
            />
            <Recipients
              draft={draft}
              getDraft={getDraft}
              field="bcc"
              onChange={change}
              onCaretMove={breakTyping}
            />
          </>
        ) : (
          <Action
            accessibilityLabel="Show Cc and Bcc"
            label="Cc/Bcc"
            onPress={() => {
              change({ ...authored.current, copies: true });
            }}
          />
        )}
        <View style={styles.field}>
          <TextInput
            accessibilityLabel="Subject"
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
                setHistory((current) => ({ ...current, typing: false }));
              }
              subjectCaret.current = undefined;
              subjectSelection.current = next;
            }}
            placeholder="Subject"
            placeholderTextColor={colors.secondary}
            style={[styles.input, { color: colors.foreground }]}
            value={draft.subject}
          />
        </View>
        <View
          accessibilityLabel="Formatting"
          accessibilityRole="toolbar"
          style={styles.bar}>
          {markControls.map(([mark, label, name, style]) => (
            <Pressable
              key={mark}
              accessibilityLabel={name}
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
              <Text style={[{ color: colors.foreground }, style]}>{label}</Text>
            </Pressable>
          ))}
          {blockControls.map(([value, label, name]) => (
            <Pressable
              key={value}
              accessibilityLabel={name}
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
        </View>
        <TextInput
          accessibilityLabel="Message body"
          keyDownEvents={shortcuts}
          multiline
          onChangeText={edit}
          onKeyDown={keyDown}
          onSelectionChange={({ nativeEvent }) => {
            const next = nativeEvent.selection;
            // Moving the caret anywhere but past typed text ends marks toggled for typing.
            if (next.start !== next.end || next.start !== caret.current) {
              setTyping(undefined);
              setHistory((current) => ({ ...current, typing: false }));
            }
            caret.current = undefined;
            setPlaced(undefined);
            setSelection(next);
          }}
          placeholder="Message"
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
      </ScrollView>
    </View>
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
    <View style={[styles.fill, { backgroundColor: colors.background }]}>
      <View style={styles.content}>
        {waiting ? (
          <ActivityIndicator accessibilityLabel="Loading Draft" />
        ) : (
          <>
            <Notice style={[styles.actionText, { color: colors.foreground }]}>
              {state.kind === 'locked'
                ? 'Drafts are locked. Unlock your device and try again.'
                : 'This Draft is not available.'}
            </Notice>
            {state.kind === 'locked' || state.kind === 'failed' ? (
              <Action
                label="Try again"
                onPress={() => {
                  void store.load();
                }}
              />
            ) : null}
            <Action
              label="Close"
              onPress={onClose}
            />
          </>
        )}
      </View>
    </View>
  );
}
