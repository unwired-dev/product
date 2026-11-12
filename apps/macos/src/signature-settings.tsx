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
  const storedNow = () =>
    mailboxesOf(store.getSnapshot().snapshot).find(
      (mailbox) => mailbox.id === id,
    )?.signature;
  const commit = async (next: SemanticDocument) => {
    const chosen = plainText(next).trim() === '' ? undefined : next;
    if (stored(chosen) === stored(storedNow())) {
      return;
    }
    await store.chooseSignature(id, chosen);
    if (store.getSnapshot().signatureFailure === id) {
      show(storedNow() ?? emptyDocument);
    }
  };
  // Closing Settings while typing still stores the signature.
  const commitNow = useRef(commit);
  useLayoutEffect(() => {
    commitNow.current = commit;
  });
  useEffect(
    () => () => {
      if (focused.current) {
        void commitNow.current(documentNow.current);
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
      change(toggleMark(document, at, mark));
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
            void commit(documentNow.current);
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
