import type {
  MailboxConnection,
  Registration,
} from '@private-email/mail-core/registration';
import type {
  Link,
  Mark,
  SemanticDocument,
} from '@private-email/mail-core/semantic-document';

import { mailboxesOf } from '@private-email/mail-core/registration';
import {
  applyText,
  displayOf,
  editableLinkAt,
  emptyDocument,
  formatStyleOf,
  marksAt,
  plainText,
  setLink,
  toggled,
  toggleMark,
} from '@private-email/mail-core/semantic-document';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  View,
} from 'react-native';

import {
  kindStyles,
  LinkEditor,
  markIcons,
  markStyle,
  useLinkEditor,
} from './composer-controls.tsx';
import { ScaledToolbar, SFSymbol, ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import {
  SettingsBlock,
  SettingsGroup,
  SettingsRow,
  settingsColumns,
} from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  format: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  body: {
    ...textStyles.body,
    minHeight: 78,
    padding: spacing.m,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  summary: { ...textStyles.body, flexShrink: 1 },
});

const marks: readonly Mark[] = ['bold', 'italic', 'underline'];

// A connection's primary address is a Sending Identity unless it is a receive-only IMAP one.
const sends = ({ provider, smtp }: MailboxConnection) =>
  provider !== 'imap' || smtp !== undefined;

const stored = (signature: SemanticDocument | undefined) =>
  JSON.stringify(signature ?? null);

// One identity's signature editor: leaving it, or a format or link change, stores the signature
// through Product Sync, and empty text clears it. A refused edit shows the stored signature again.
function SignatureEditor({
  mailbox: { id, address, signature },
  store,
}: {
  readonly mailbox: MailboxConnection;
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const appearance = useColorScheme() === 'dark' ? 'dark' : 'light';
  const { busy } = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const linkEditor = useLinkEditor();
  const [document, setDocument] = useState(signature ?? emptyDocument);
  const [selection, setSelection] = useState({ start: 0, end: 0 });
  const [placed, setPlaced] = useState<typeof selection>();
  // Marks toggled at the caret for the next typed text.
  const [typing, setTyping] = useState<readonly Mark[]>();
  // The latest text and selection, ahead of rendering, and whether the editor has focus.
  const documentNow = useRef(document);
  const selectionNow = useRef(selection);
  const focused = useRef(false);
  const show = (next: SemanticDocument) => {
    documentNow.current = next;
    setDocument(next);
  };
  // A signature another device stores shows here while it is not being edited.
  useEffect(() => {
    if (!focused.current) {
      documentNow.current = signature ?? emptyDocument;
      setDocument(documentNow.current);
    }
  }, [signature]);
  // The Product Account the editor opened under: a replacement account can hold the same
  // mailbox under the same connection, and must not receive this editor's signature.
  const ownerOf = () => {
    const { snapshot } = store.getSnapshot();
    return snapshot.kind === 'signed-out'
      ? undefined
      : snapshot.productAccountId;
  };
  const owner = useRef(ownerOf());
  const storedNow = () =>
    mailboxesOf(store.getSnapshot().snapshot).find(
      (mailbox) => mailbox.id === id,
    )?.signature;
  const commit = async (next: SemanticDocument) => {
    const chosen = plainText(next).trim() === '' ? undefined : next;
    if (ownerOf() !== owner.current || stored(chosen) === stored(storedNow())) {
      return;
    }
    await store.chooseSignature(id, chosen);
    // A refused save, or one that stored nothing, as when authentication is cancelled.
    if (
      store.getSnapshot().signatureFailure === id ||
      (!focused.current && stored(chosen) !== stored(storedNow()))
    ) {
      show(storedNow() ?? emptyDocument);
    }
  };
  // The document when editing began. Leaving without an edit stores nothing, so a signature
  // another device stored meanwhile is kept and shows here.
  const editing = useRef(document);
  const leave = () => {
    if (stored(documentNow.current) === stored(editing.current)) {
      show(storedNow() ?? emptyDocument);
    } else {
      void commit(documentNow.current);
    }
  };
  // Leaving Settings while typing still stores the signature.
  const leaveNow = useRef(leave);
  useLayoutEffect(() => {
    leaveNow.current = leave;
  });
  useEffect(
    () => () => {
      if (focused.current) {
        leaveNow.current();
      }
    },
    [],
  );
  const select = (at: typeof selection) => {
    selectionNow.current = at;
    setSelection(at);
    setPlaced(at);
  };
  const change = (next: SemanticDocument, at?: typeof selection) => {
    show(next);
    if (at !== undefined) {
      select(at);
    }
    if (!focused.current) {
      void commit(next);
    }
  };
  const format = (mark: Mark) => {
    const at = selectionNow.current;
    if (at.start === at.end) {
      setTyping(toggled(typing ?? marksAt(document, at), mark));
    } else {
      // Rendering the marks collapses the body's selection; keep it for the next control.
      change(toggleMark(document, at, mark), { ...at });
    }
  };
  const active = typing ?? marksAt(document, selection);
  const display = displayOf(document);
  return (
    <SettingsGroup title={t('signatures.edit', { address })}>
      <SettingsBlock>
        <View
          accessibilityLabel={t('drafts.formatting')}
          accessibilityRole="toolbar"
          style={styles.format}>
          <ScaledToolbar value={settingsColumns}>
            {marks.map((mark) => (
              <ToolbarButton
                key={mark}
                disabled={busy}
                icon={markIcons[mark]}
                label={t(`drafts.marks.${mark}`)}
                selected={active.includes(mark)}
                onPress={() => {
                  format(mark);
                }}
              />
            ))}
          </ScaledToolbar>
          <LinkEditor
            state={linkEditor}
            disabled={busy}
            link={editableLinkAt(document, selection)}
            popover={settingsColumns}
            onChange={(link: Link, text, href) => {
              const result = setLink(document, link, { text, href });
              change(result.document, result.selection);
            }}
          />
        </View>
        <TextInput
          accessibilityLabel={t('signatures.signature', { address })}
          editable={!busy}
          multiline
          onBlur={() => {
            focused.current = false;
            leave();
          }}
          onChangeText={(text) => {
            const result = applyText(documentNow.current, text, {
              marks: typing,
              selection: selectionNow.current,
            });
            show(result.document);
            if (result.selection !== undefined) {
              select(result.selection);
            }
          }}
          onFocus={() => {
            focused.current = true;
            editing.current = documentNow.current;
          }}
          onSelectionChange={({ nativeEvent }) => {
            const next = nativeEvent.selection;
            if (next.start !== next.end || next.start !== selection.start) {
              setTyping(undefined);
            }
            selectionNow.current = next;
            setSelection(next);
            setPlaced(undefined);
          }}
          scrollEnabled={false}
          selection={placed}
          style={[
            styles.body,
            {
              backgroundColor: colors.surfaceContent,
              borderColor: colors.separator,
              color: colors.textPrimary,
            },
          ]}>
          {display.lines.map((line, index) => (
            <Text
              // oxlint-disable-next-line react/no-array-index-key -- Blocks are positional.
              key={index}
              style={[
                kindStyles[line.kind],
                line.align === undefined ? null : { textAlign: line.align },
              ]}>
              {line.marker}
              {line.spans.map((span, at) => (
                <Text
                  // oxlint-disable-next-line react/no-array-index-key -- Spans are positional.
                  key={at}
                  style={[
                    markStyle(span.marks, 'link' in span),
                    'link' in span ? { color: colors.accentInk } : null,
                    formatStyleOf(span, appearance),
                  ]}>
                  {span.text}
                </Text>
              ))}
              {index < display.lines.length - 1 ? '\n' : ''}
            </Text>
          ))}
        </TextInput>
      </SettingsBlock>
      <Pressable
        accessibilityLabel={t('signatures.delete')}
        accessibilityRole="button"
        accessibilityState={{ disabled: busy || signature === undefined }}
        disabled={busy || signature === undefined}
        onPress={() => {
          show(emptyDocument);
          void commit(emptyDocument);
        }}
        style={({ pressed }) =>
          pressed && { backgroundColor: colors.accentSelectionSubtle }
        }>
        <SettingsRow
          title={t('signatures.delete')}
          titleTone="destructive"
          disabled={busy || signature === undefined}
        />
      </Pressable>
    </SettingsGroup>
  );
}

// Settings › Signatures: each Sending Identity with its signature's first line, then the chosen
// identity's editor.
export function SignatureSettings({
  mailboxes,
  store,
}: {
  readonly mailboxes: readonly MailboxConnection[];
  readonly store: Registration;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const { signatureFailure } = useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
  );
  const identities = mailboxes.filter(sends);
  const [chosen, setChosen] = useState<string>();
  const editing =
    identities.find(({ id }) => id === chosen) ?? identities.at(0);
  if (editing === undefined) {
    return (
      <SettingsGroup
        title={t('settings.destinations.signatures')}
        footer={t('signatures.noIdentities')}
      />
    );
  }
  return (
    <>
      <SettingsGroup title={t('settings.destinations.signatures')}>
        {identities.map(({ id, address, signature }) => {
          const summary =
            signature === undefined
              ? t('signatures.none')
              : (plainText(signature)
                  .split('\n')
                  .find((line) => line.trim() !== '') ?? '');
          const failed =
            signatureFailure === id ? t('signatures.changeFailed') : undefined;
          return (
            <Pressable
              key={id}
              accessibilityLabel={address}
              accessibilityRole="button"
              accessibilityState={{ selected: id === editing.id }}
              accessibilityValue={{ text: summary }}
              onPress={() => {
                setChosen(id);
              }}
              style={({ pressed }) =>
                (pressed || (settingsColumns && id === editing.id)) && {
                  backgroundColor: colors.accentSelectionSubtle,
                }
              }>
              {/* iPad shows the first line after the address, iPhone below it, as the frames do. */}
              <SettingsRow
                title={address}
                subtitle={settingsColumns ? failed : (failed ?? summary)}
                subtitleTone={failed === undefined ? undefined : 'warning'}>
                {settingsColumns ? (
                  <Text
                    numberOfLines={1}
                    style={[styles.summary, { color: colors.textSecondary }]}>
                    {summary}
                  </Text>
                ) : null}
                <SFSymbol
                  name="chevron.right"
                  size={12}
                  color={colors.textSecondary}
                />
              </SettingsRow>
            </Pressable>
          );
        })}
      </SettingsGroup>
      <SignatureEditor
        key={editing.id}
        mailbox={editing}
        store={store}
      />
    </>
  );
}
