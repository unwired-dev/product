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
  StyleSheet,
  Text,
  TextInput,
  useColorScheme,
  View,
} from 'react-native';

import { kindStyles, LinkEditor, markStyle } from './composer-controls.tsx';
import { Button, SFSymbol, ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import { SettingsGroup, SettingsRow, SettingsRowButton } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  editor: {
    gap: 10,
    padding: 14,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  format: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  body: {
    ...textStyles.body,
    minHeight: 78,
    padding: spacing.m,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  actions: { flexDirection: 'row', justifyContent: 'flex-end' },
});

const marks: ReadonlyArray<readonly [Mark, string]> = [
  ['bold', 'bold'],
  ['italic', 'italic'],
  ['underline', 'underline'],
];

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
  // Closing Settings while typing still stores the signature.
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
  const change = (next: SemanticDocument, at?: typeof selection) => {
    show(next);
    if (at !== undefined) {
      selectionNow.current = at;
      setSelection(at);
      setPlaced(at);
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
    <>
      <SettingsGroup title={t('signatures.edit', { address })} />
      <View style={[styles.editor, { backgroundColor: colors.fillQuiet }]}>
        <View
          accessibilityLabel={t('drafts.formatting')}
          accessibilityRole="toolbar"
          style={styles.format}>
          {marks.map(([mark, icon]) => (
            <ToolbarButton
              key={mark}
              disabled={busy}
              icon={icon}
              label={t(`drafts.marks.${mark}`)}
              selected={active.includes(mark)}
              onPress={() => {
                format(mark);
              }}
            />
          ))}
          <LinkEditor
            disabled={busy}
            link={editableLinkAt(document, selection)}
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
              selectionNow.current = result.selection;
              setSelection(result.selection);
              setPlaced(result.selection);
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
        <View style={styles.actions}>
          <Button
            destructive
            disabled={busy || signature === undefined}
            label={t('signatures.delete')}
            onPress={() => {
              show(emptyDocument);
              void commit(emptyDocument);
            }}
          />
        </View>
      </View>
    </>
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
          return (
            <SettingsRowButton
              key={id}
              accessibilityLabel={address}
              accessibilityRole="button"
              accessibilityState={{ selected: id === editing.id }}
              accessibilityValue={{ text: summary }}
              onPress={() => {
                setChosen(id);
              }}>
              <SettingsRow
                title={address}
                subtitle={
                  signatureFailure === id
                    ? t('signatures.changeFailed')
                    : undefined
                }
                subtitleTone="warning">
                <Text
                  numberOfLines={1}
                  style={[textStyles.body, { color: colors.textSecondary }]}>
                  {summary}
                </Text>
                <SFSymbol
                  name="chevron.right"
                  size={10}
                  color={colors.textSecondary}
                />
              </SettingsRow>
            </SettingsRowButton>
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
