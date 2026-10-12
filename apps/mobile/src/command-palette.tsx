import type { PaletteCommand } from '@private-email/mail-core/command-palette';
import type { ReactNode } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';

import {
  commandChoices,
  commandHintSeen,
  commandKey,
  createCommandPalette,
  matchingCommands,
} from '@private-email/mail-core/command-palette';
import {
  createContext,
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
  KeyboardAvoidingView,
  NativeModules,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
  requireNativeComponent,
} from 'react-native';

import { useLocalization } from './localization.ts';
import { usePalette } from './theme.ts';

const nativeCommands = (
  NativeModules as {
    readonly UnwiredCommandPalette?: {
      readonly hintSeen?: unknown;
      readonly markHintSeen?: () => void;
    };
  }
).UnwiredCommandPalette;

const NativeHost = requireNativeComponent<
  ViewProps & {
    enabled: boolean;
    presentation: 'open' | 'dismissed' | 'retired';
    headerInset: number;
    onCommandKey: (event: NativeSyntheticEvent<unknown>) => void;
  }
>('UnwiredCommandPalette');

type Palette = ReturnType<typeof createCommandPalette>;
const CommandContext = createContext<
  Readonly<{ store: Palette; open: () => void; close: () => void }> | undefined
>(undefined);

export function useCommands(commands: readonly PaletteCommand[]) {
  const context = use(CommandContext);
  const owner = useMemo(() => ({}), []);
  useLayoutEffect(() => {
    context?.store.register(owner, commands);
  }, [context, owner, commands]);
  useLayoutEffect(
    () => () => {
      context?.store.remove(owner);
    },
    [context, owner],
  );
}

export function useCommandScope(scope: string) {
  const context = use(CommandContext);
  const previous = useRef(scope);
  useLayoutEffect(() => {
    if (previous.current !== scope) {
      previous.current = scope;
      context?.close();
    }
  }, [context, scope]);
}

export function Commands({
  commands,
}: {
  readonly commands: readonly PaletteCommand[];
}) {
  useCommands(commands);
  return null;
}

const styles = StyleSheet.create({
  fill: { flex: 1 },
  bar: { padding: 8, borderBottomWidth: StyleSheet.hairlineWidth },
  input: {
    fontSize: 16,
    minHeight: 44,
    paddingHorizontal: 12,
    borderWidth: 1,
    borderRadius: 8,
  },
  overlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 100,
  },
  shade: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  },
  panel: {
    margin: 8,
    borderWidth: 1,
    borderRadius: 10,
    maxHeight: '85%',
    alignSelf: 'stretch',
  },
  controls: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    padding: 12,
  },
  row: { minHeight: 48, paddingHorizontal: 16, paddingVertical: 10 },
  line: { flexDirection: 'row', justifyContent: 'space-between', gap: 8 },
  label: { fontSize: 16 },
  secondary: { fontSize: 13, marginTop: 4 },
  hint: { padding: 8, fontSize: 13 },
});

function CommandHeader({
  children,
  label,
}: {
  readonly children: ReactNode;
  readonly label?: string;
}) {
  const context = use(CommandContext);
  const { t } = useLocalization();
  return (
    <View
      accessible={label !== undefined}
      accessibilityLabel={label}
      accessibilityActions={[
        { name: 'openCommands', label: t('commandPalette.open') },
      ]}
      onAccessibilityAction={({ nativeEvent }) => {
        if (nativeEvent.actionName === 'openCommands') {
          context?.open();
        }
      }}>
      {children}
    </View>
  );
}

export function UnavailableCommands({ stars = false }: { readonly stars?: boolean }) {
  const { t } = useLocalization();
  const defaults = useMemo<readonly PaletteCommand[]>(
    () => [
      ...(
        [
          [
            'archive',
            t('gmailActions.label.archive'),
            t('commandPalette.archiveKeywords'),
          ],
          ['read', t('message.markRead'), t('commandPalette.readKeywords')],
          ['unread', t('message.markUnread'), t('commandPalette.readKeywords')],
          ['move', t('commandPalette.move'), t('commandPalette.moveKeywords')],
          ['reply', t('message.reply'), t('commandPalette.replyKeywords')],
          ['replyAll', t('message.replyAll'), t('commandPalette.replyKeywords')],
          ['forward', t('message.forward'), t('commandPalette.forwardKeywords')],
          ['trash', t('gmailActions.label.trash'), ''],
          ['spam', t('gmailActions.label.spam'), ''],
          ...(stars
            ? ([['star', t('gmailActions.label.star'), ''], ['unstar', t('gmailActions.label.unstar'), '']] as const)
            : []),
        ] as const
      ).map(([id, label, keywords]) => ({
        id,
        label,
        keywords,
        group: 'selection' as const,
        disabled: t('commandPalette.select'),
        onRun: () => false,
      })),
      {
        id: 'compose',
        label: t('drafts.newMessage'),
        keywords: t('commandPalette.composeKeywords'),
        group: 'app',
        disabled: t('commandPalette.unavailable'),
        onRun: () => false,
      },
    ],
    [t, stars],
  );
  return <Commands commands={defaults} />;
}

export function CommandPalette({
  children,
  topInset = 0,
}: {
  readonly children: ReactNode;
  readonly topInset?: number;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const store = useMemo(() => createCommandPalette(''), []);
  useLayoutEffect(() => {
    store.setUnavailable(t('commandPalette.unavailable'));
  }, [store, t]);
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const [query, setQuery] = useState('');
  const currentQuery = useRef('');
  const currentPath = useRef<readonly string[]>([]);
  const currentSelected = useRef(0);
  const [path, setPath] = useState<readonly string[]>([]);
  const [selected, setSelected] = useState(0);
  const [pending, setPending] = useState(false);
  const running = useRef(false);
  const session = useRef(0);
  const [failure, setFailure] = useState(false);
  const input = useRef<TextInput>(null);
  const list = useRef<ScrollView>(null);
  const positions = useRef(new Map<string, number>());
  const previous =
    useRef<ReturnType<typeof TextInput.State.currentlyFocusedInput>>(null);
  const persistent = Platform.OS !== 'ios' || Platform.isPad;
  const [hint, setHint] = useState(() => {
    const seen: unknown = nativeCommands?.hintSeen;
    return !persistent && !commandHintSeen(seen);
  });
  useEffect(() => {
    if (hint && state.commands.length > 0) {
      nativeCommands?.markHintSeen?.();
    }
  }, [hint, state.commands.length]);
  const open = useCallback(() => {
    const current = store.getSnapshot();
    if (current.open || current.commands.length === 0) {
      return;
    }
    session.current += 1;
    previous.current = TextInput.State.currentlyFocusedInput();
    currentQuery.current = '';
    currentPath.current = [];
    currentSelected.current = 0;
    setQuery('');
    setPath([]);
    setSelected(0);
    setFailure(false);
    setHint(false);
    nativeCommands?.markHintSeen?.();
    store.open();
  }, [store]);
  const close = useCallback((presentation: 'dismissed' | 'retired' = 'retired') => {
    session.current += 1;
    if (presentation === 'retired') {
      previous.current = null;
    }
    store.close(presentation);
  }, [store]);
  const context = useMemo(() => ({ store, open, close }), [store, open, close]);
  const dismiss = () => {
    if (!store.getSnapshot().open) {
      return;
    }
    close('dismissed');
    previous.current?.focus();
  };
  useEffect(() => {
    if (state.open) {
      input.current?.focus();
    }
  }, [state.open]);
  const { commands, disabled: parentDisabled } = commandChoices(
    state.commands,
    path,
    t('commandPalette.unavailable'),
  );
  const results = matchingCommands(commands, query);
  const index = Math.min(selected, Math.max(0, results.length - 1));
  const selectedId = results[index]?.id;
  useEffect(() => {
    if (selectedId !== undefined) {
      list.current?.scrollTo({
        y: positions.current.get(selectedId) ?? 0,
        animated: false,
      });
    }
  }, [selectedId, list, positions]);
  const back = () => {
    currentPath.current = currentPath.current.slice(0, -1);
    currentQuery.current = '';
    currentSelected.current = 0;
    setPath(currentPath.current);
    setQuery('');
    setSelected(0);
    setFailure(false);
  };
  const run = async (requested: PaletteCommand) => {
    const current = store.getSnapshot();
    const latest = commandChoices(
      current.commands,
      currentPath.current,
      t('commandPalette.unavailable'),
    );
    const command = latest.commands.find(
      (candidate) =>
        candidate.id === requested.id && candidate.target === requested.target,
    );
    if (!current.open || command === undefined || latest.disabled !== undefined) {
      return;
    }
    const started = session.current;
    if (running.current || command.disabled !== undefined) {
      return;
    }
    if (command.choices !== undefined) {
      currentPath.current = [...currentPath.current, command.id];
      currentQuery.current = '';
      currentSelected.current = 0;
      setPath(currentPath.current);
      setQuery('');
      setSelected(0);
      return;
    }
    running.current = true;
    setPending(true);
    setFailure(false);
    try {
      const completed = await command.onRun();
      if (completed !== false && started === session.current) {
        dismiss();
      }
    } catch {
      if (started === session.current) {
        setFailure(true);
      }
    }
    running.current = false;
    setPending(false);
  };
  const inputMatches = () =>
    matchingCommands(
      commandChoices(
        store.getSnapshot().commands,
        currentPath.current,
        t('commandPalette.unavailable'),
      ).commands,
      currentQuery.current,
    );
  const selectedCommand = () => {
    const matches = inputMatches();
    return matches[
      Math.min(currentSelected.current, Math.max(0, matches.length - 1))
    ];
  };
  const key = (event: NativeSyntheticEvent<unknown>) => {
    const decodedKey = commandKey(event.nativeEvent);
    if (decodedKey === undefined) {
      return;
    }
    switch (decodedKey) {
      case 'open': {
        open();
        break;
      }
      case 'escape': {
        if (currentPath.current.length > 0) {
          back();
        } else {
          dismiss();
        }
        break;
      }
      case 'up': {
        currentSelected.current = Math.max(
          0,
          Math.min(currentSelected.current, inputMatches().length - 1) - 1,
        );
        setSelected(currentSelected.current);
        break;
      }
      case 'down': {
        const matches = inputMatches();
        currentSelected.current = Math.max(
          0,
          Math.min(matches.length - 1, currentSelected.current + 1),
        );
        setSelected(currentSelected.current);
        break;
      }
      case 'enter': {
        const command = selectedCommand();
        if (command !== undefined) {
          void run(command);
        }
        break;
      }
      default: {
        break;
      }
    }
  };
  const field = (
    <TextInput
      ref={input}
      accessibilityLabel={t('commandPalette.title')}
      placeholder={t('commandPalette.placeholder')}
      placeholderTextColor={colors.secondary}
      autoCorrect={false}
      autoCapitalize="none"
      value={query}
      onChangeText={(text) => {
        currentQuery.current = text;
        currentSelected.current = 0;
        setQuery(text);
        setSelected(0);
      }}
      onSubmitEditing={() => {
        const command = selectedCommand();
        if (command !== undefined) {
          void run(command);
        }
      }}
      submitBehavior="submit"
      style={[
        styles.input,
        { color: colors.foreground, borderColor: colors.separator },
      ]}
    />
  );
  return (
    <CommandContext value={context}>
      <NativeHost
        testID="command-palette-host"
        style={styles.fill}
        headerInset={topInset}
        enabled={state.commands.length > 0}
        presentation={state.presentation}
        onCommandKey={key}>
        <View
          collapsable={false}
          style={styles.fill}
          accessibilityElementsHidden={state.open}
          importantForAccessibility={state.open ? 'no-hide-descendants' : 'auto'}>
          {persistent && state.commands.length > 0 ? (
            <CommandHeader>
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={t('commandPalette.open')}
                onPress={open}
                style={[
                  styles.bar,
                  {
                    paddingTop: topInset + 8,
                    borderColor: colors.separator,
                    backgroundColor: colors.background,
                  },
                ]}>
                <Text
                  style={[
                    styles.input,
                    { color: colors.secondary, borderColor: colors.separator },
                  ]}>
                  {t('commandPalette.placeholder')} ⌘P
                </Text>
              </Pressable>
            </CommandHeader>
          ) : null}
          <View style={styles.fill}>{children}</View>
        </View>
        {!persistent && state.commands.length > 0 ? (
          <View style={{ position: 'absolute', top: topInset, left: 0 }}>
            <CommandHeader label={t('commandPalette.app')}>
              <View style={{ width: 1, height: 1 }} />
            </CommandHeader>
          </View>
        ) : null}
        {hint && state.commands.length > 0 ? (
          <Text
            pointerEvents="none"
            style={[
              styles.hint,
              {
                position: 'absolute',
                top: topInset + 52,
                alignSelf: 'center',
                color: colors.secondary,
                backgroundColor: colors.background,
              },
            ]}>
            {t('commandPalette.hint')}
          </Text>
        ) : null}
        {state.open ? (
          <KeyboardAvoidingView
            behavior={Platform.OS === 'ios' ? 'padding' : undefined}
            style={[styles.overlay, { top: topInset }]}>
            <Pressable
              accessible={false}
              style={[
                styles.shade,
                { backgroundColor: colors.foreground, opacity: 0.2 },
              ]}
              onPress={dismiss}
            />
            <View
              accessibilityViewIsModal
              style={[
                styles.panel,
                {
                  backgroundColor: colors.background,
                  borderColor: colors.separator,
                },
              ]}>
              {field}
              <View style={styles.controls}>
                {path.length > 0 ? (
                  <Pressable
                    accessibilityRole="button"
                    onPress={back}>
                    <Text style={{ color: colors.accent }}>
                      {t('commandPalette.back')}
                    </Text>
                  </Pressable>
                ) : (
                  <Text style={[styles.label, { color: colors.foreground }]}>
                    {t('commandPalette.title')}
                  </Text>
                )}
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel={t('commandPalette.cancel')}
                  onPress={dismiss}>
                  <Text style={{ color: colors.accent }}>
                    {t('common.cancel')}
                  </Text>
                </Pressable>
              </View>
              {failure ? (
                <Text
                  accessibilityRole="alert"
                  style={[styles.hint, { color: colors.destructive }]}>
                  {t('commandPalette.failed')}
                </Text>
              ) : null}
              <ScrollView
                ref={list}
                keyboardShouldPersistTaps="handled">
                {results.length === 0 ? (
                  <Text style={[styles.hint, { color: colors.secondary }]}>
                    {t('commandPalette.empty')}
                  </Text>
                ) : null}
                {results.map((command, row) => {
                  const disabled =
                    command.disabled ??
                    parentDisabled ??
                    (pending ? t('commandPalette.busy') : undefined);
                  return (
                    <Pressable
                      key={command.id}
                      onLayout={({ nativeEvent }) => {
                        positions.current.set(command.id, nativeEvent.layout.y);
                      }}
                      accessibilityRole="button"
                      accessibilityState={{
                        disabled: disabled !== undefined,
                        selected: row === index,
                      }}
                      accessibilityLabel={command.label}
                      accessibilityHint={disabled}
                      disabled={disabled !== undefined}
                      onPress={() => {
                        void run(command);
                      }}
                      style={[
                        styles.row,
                        {
                          backgroundColor:
                            row === index ? colors.selected : colors.background,
                          borderLeftWidth: 3,
                          borderLeftColor:
                            row === index ? colors.accent : 'transparent',
                        },
                      ]}>
                      <View style={styles.line}>
                        <Text
                          style={[
                            styles.label,
                            {
                              color:
                                disabled === undefined
                                  ? colors.foreground
                                  : colors.secondary,
                            },
                          ]}>
                          {command.label}
                        </Text>
                        {command.shortcut === undefined ? null : (
                          <Text style={{ color: colors.secondary }}>
                            {command.shortcut}
                          </Text>
                        )}
                      </View>
                      {disabled === undefined ? null : (
                        <Text
                          style={[styles.secondary, { color: colors.secondary }]}>
                          {disabled}
                        </Text>
                      )}
                    </Pressable>
                  );
                })}
              </ScrollView>
            </View>
          </KeyboardAvoidingView>
        ) : null}
      </NativeHost>
    </CommandContext>
  );
}
