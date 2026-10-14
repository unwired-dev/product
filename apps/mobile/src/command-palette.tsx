import type {
  Command,
  CommandChoice,
  CommandRegistry,
  NativePreferences,
} from '@private-email/mail-core/commands';
import type { ReactNode } from 'react';
import type {
  GestureResponderEvent,
  TextInput as TextInputHandle,
  TurboModule,
  StyleProp,
  ViewProps,
  ViewStyle,
} from 'react-native';

import {
  createCommandRegistry,
  createPaletteHint,
  expectedCommands,
  matchCommands,
  mergeCommands,
  offeredCommand,
  orderCommands,
  sectionTitle,
} from '@private-email/mail-core/commands';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TurboModuleRegistry,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Glass, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const PaletteContext = createContext<
  Readonly<{
    registry: CommandRegistry;
    // The commands as listed when the palette opened, while it is open.
    opened: readonly Command[] | undefined;
    open: () => void;
    close: () => void;
  }>
>({
  registry: createCommandRegistry(),
  opened: undefined,
  open: () => undefined,
  close: () => undefined,
});

export function useCommandPalette() {
  const { opened, open, close } = use(PaletteContext);
  return { open, close, isOpen: opened !== undefined };
}

// Offers commands while it is mounted, with the same handlers the owning screen's buttons use.
// They are built outside rendering, so a handler may read a ref.
export function RegisterCommands({
  offer,
}: {
  readonly offer: () => readonly Command[];
}) {
  const { registry } = use(PaletteContext);
  const owner = useMemo(() => Symbol('commands'), []);
  useLayoutEffect(
    () => registry.register(owner, offer()),
    [registry, owner, offer],
  );
  return null;
}

interface PreferenceModule extends TurboModule, NativePreferences {}

const preferences = () =>
  TurboModuleRegistry.get<PreferenceModule>('UnwiredRegistration');

// This device's one-time gesture hint; a host without saved preferences shows it each launch.
const hint = createPaletteHint({
  preference: (key) =>
    preferences()?.preference(key) ?? Promise.resolve({ value: null }),
  setPreference: (key, value) =>
    preferences()?.setPreference(key, value) ?? Promise.resolve({}),
});

// iPad keeps a visible command input; iPhone opens the palette by gesture alone.
const pad = Platform.OS === 'ios' && Platform.isPad;
const scrim = 'rgba(0, 0, 0, 0.3)';

const styles = StyleSheet.create({
  fill: { flex: 1 },
  layer: { zIndex: 10, elevation: 10 },
  sheet: {
    borderBottomLeftRadius: radius.window,
    borderBottomRightRadius: radius.window,
    borderCurve: 'continuous',
    paddingBottom: spacing.s,
    maxHeight: '80%',
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.s,
  },
  field: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
    paddingHorizontal: spacing.m,
    borderRadius: 22,
    borderCurve: 'continuous',
  },
  input: { ...textStyles.body, flex: 1, paddingVertical: 0 },
  chip: {
    ...textStyles.subheadline,
    fontWeight: '600',
    paddingHorizontal: 10,
    paddingVertical: 3,
    borderRadius: radius.chip,
    overflow: 'hidden',
  },
  cancel: { ...textStyles.body, paddingVertical: spacing.s },
  backRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    marginHorizontal: spacing.l,
    paddingBottom: spacing.xs,
    marginBottom: spacing.xs,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  back: { minHeight: 44, justifyContent: 'center' },
  backPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 2,
    height: 36,
    paddingLeft: spacing.s,
    paddingRight: spacing.m,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  backText: { ...textStyles.subheadline },
  choosing: { ...textStyles.subheadline, fontWeight: '600', flex: 1 },
  list: { paddingHorizontal: spacing.m },
  section: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingTop: spacing.m,
    paddingBottom: spacing.xs,
    paddingHorizontal: spacing.s,
  },
  divider: { borderTopWidth: StyleSheet.hairlineWidth, marginTop: spacing.s },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 44,
    paddingHorizontal: spacing.s,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  title: { ...textStyles.body, flex: 1 },
  // A command that cannot run keeps its name legible but recedes behind its reason.
  dimmed: { opacity: 0.35 },
  detail: { ...textStyles.footnote },
  empty: { ...textStyles.subheadline, padding: spacing.l },
  pill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 36,
    paddingHorizontal: spacing.m,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  pillText: { ...textStyles.subheadline },
  // Matches the reader's header and the composer's top bar, where the input otherwise sits.
  commandRow: {
    width: '100%',
    maxWidth: 760,
    alignSelf: 'center',
    alignItems: 'flex-end',
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.xl,
  },
  hint: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    marginHorizontal: spacing.l,
    marginBottom: spacing.l,
    paddingLeft: 14,
    paddingRight: 10,
    paddingVertical: spacing.m,
    borderRadius: radius.bubble,
    borderCurve: 'continuous',
  },
  hintText: { flex: 1, gap: 2 },
  hintTitle: { ...textStyles.subheadline, fontWeight: '600' },
  hintDetail: { ...textStyles.footnote },
  dismiss: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  dismissCircle: {
    width: 30,
    height: 30,
    borderRadius: 15,
    alignItems: 'center',
    justifyContent: 'center',
  },
});

// Mounts the palette over its children; every window or root layout has one.
export function CommandPaletteProvider({
  children,
}: {
  readonly children: ReactNode;
}) {
  const registry = useMemo(() => createCommandRegistry(), []);
  const { t } = useLocalization();
  const [opened, setOpened] = useState<readonly Command[]>();
  // The control focused when the palette opened, which closing hands focus back to.
  const previous = useRef<ReturnType<
    typeof TextInput.State.currentlyFocusedInput
  > | null>(null);
  useEffect(() => {
    if (!pad) {
      void hint.load();
    }
  }, []);
  const value = useMemo(
    () => ({
      registry,
      opened,
      open: () => {
        if (opened !== undefined) {
          return;
        }
        void hint.dismiss();
        previous.current = TextInput.State.currentlyFocusedInput();
        const placeholders = expectedCommands(t, {
          disabled: t('commands.selectConversation'),
        });
        const commands = mergeCommands([
          ...placeholders,
          ...registry.getSnapshot(),
        ]);
        setOpened(orderCommands(commands));
      },
      close: () => {
        setOpened(undefined);
        previous.current?.focus();
        previous.current = null;
      },
    }),
    [registry, opened, t],
  );
  return (
    <PaletteContext value={value}>
      <View style={styles.fill}>
        {children}
        {opened === undefined ? null : <Palette opened={opened} />}
      </View>
    </PaletteContext>
  );
}

// The open palette: a sheet attached to the top with the query focused and matching commands
// beneath, or the choices of the command being completed.
function Palette({ opened }: { readonly opened: readonly Command[] }) {
  const { registry, close } = use(PaletteContext);
  const colors = usePalette();
  const insets = useSafeAreaInsets();
  const { t } = useLocalization();
  const [query, setQuery] = useState('');
  const [choosing, setChoosing] = useState<Command>();
  const [choiceQuery, setChoiceQuery] = useState('');
  // Commands whose message disappeared after the palette opened.
  const [gone, setGone] = useState<readonly string[]>([]);
  const input = useRef<TextInputHandle>(null);
  const live = useSyncExternalStore(registry.subscribe, registry.getSnapshot);
  const vanished = (command: Command): Command =>
    gone.includes(command.id)
      ? { ...command, disabled: t('commands.gone') }
      : command;
  const listed = matchCommands(query, opened.map(vanished));
  // Closing hands focus back first, so a command that focuses a control keeps that focus.
  const run = (command: Command) => {
    const found = offeredCommand(live, command);
    if (found === undefined) {
      setGone([...gone, command.id]);
      return;
    }
    if (found.choices !== undefined) {
      setChoosing(found);
      setChoiceQuery('');
      return;
    }
    close();
    void found.run?.();
  };
  const choose = (choice: CommandChoice) => {
    const found =
      choosing === undefined ? undefined : offeredCommand(live, choosing);
    const option = found?.choices?.find(({ id }) => id === choice.id);
    if (option === undefined || option.disabled !== undefined) {
      if (choosing !== undefined) {
        setGone([...gone, choosing.id]);
      }
      setChoosing(undefined);
      return;
    }
    close();
    option.run();
  };
  const subject = opened.find(({ target }) => target !== undefined)?.target
    ?.subject;
  const choices =
    choosing?.choices === undefined
      ? undefined
      : matchCommands(choiceQuery, choosing.choices);
  const submit = () => {
    if (choices === undefined) {
      const first = listed.find(({ disabled }) => disabled === undefined);
      if (first !== undefined) {
        run(first);
      }
      return;
    }
    const first = choices.find(({ disabled }) => disabled === undefined);
    if (first !== undefined) {
      choose(first);
    }
  };
  const prompt =
    choosing === undefined
      ? t('commands.placeholder')
      : t('commands.chooseFolder');
  return (
    <View
      // Assistive controls stay within the palette while it is open.
      accessibilityViewIsModal
      style={[StyleSheet.absoluteFill, styles.layer]}
      testID="command-palette">
      <Pressable
        accessibilityLabel={t('commands.close')}
        accessibilityRole="button"
        onPress={close}
        style={[StyleSheet.absoluteFill, { backgroundColor: scrim }]}
      />
      <View
        style={[
          styles.sheet,
          {
            // The sheet floats over the screens, so it clears the status bar itself.
            paddingTop: insets.top,
            paddingLeft: insets.left,
            paddingRight: insets.right,
            backgroundColor: colors.surfaceContent,
            boxShadow: colors.menuShadow,
          },
        ]}>
        <View style={styles.inputRow}>
          <View style={[styles.field, { backgroundColor: colors.fillQuiet }]}>
            <SFSymbol
              name="command"
              color={colors.textSecondary}
            />
            {choosing === undefined ? null : (
              <Text
                style={[
                  styles.chip,
                  {
                    backgroundColor: colors.accentFill,
                    color: colors.accentOnFill,
                  },
                ]}>
                {choosing.chip ?? choosing.title}
              </Text>
            )}
            <TextInput
              accessibilityLabel={prompt}
              autoCapitalize="none"
              autoCorrect={false}
              key={choosing === undefined ? 'commands' : 'choices'}
              onChangeText={choosing === undefined ? setQuery : setChoiceQuery}
              // The input receives focus as soon as the palette, or its picker, appears.
              onLayout={() => {
                input.current?.focus();
              }}
              onSubmitEditing={submit}
              placeholder={prompt}
              placeholderTextColor={colors.textSecondary}
              ref={input}
              returnKeyType="go"
              style={[styles.input, { color: colors.textPrimary }]}
              value={choosing === undefined ? query : choiceQuery}
            />
          </View>
          <Pressable
            accessibilityRole="button"
            onPress={close}>
            <Text style={[styles.cancel, { color: colors.accentInk }]}>
              {t('common.cancel')}
            </Text>
          </Pressable>
        </View>
        {choosing === undefined ? null : (
          <View
            style={[styles.backRow, { borderBottomColor: colors.separator }]}>
            <Pressable
              accessibilityLabel={t('commands.backLabel')}
              accessibilityRole="button"
              onPress={() => {
                setChoosing(undefined);
              }}
              style={styles.back}>
              <View
                style={[
                  styles.backPill,
                  { backgroundColor: colors.fillQuiet },
                ]}>
                <SFSymbol
                  name="chevron.left"
                  color={colors.textPrimary}
                  size={14}
                />
                <Text style={[styles.backText, { color: colors.textPrimary }]}>
                  {t('commands.back')}
                </Text>
              </View>
            </Pressable>
            <Text style={[styles.choosing, { color: colors.textPrimary }]}>
              {choosing.choosing ?? choosing.title}
            </Text>
          </View>
        )}
        <ScrollView
          contentContainerStyle={styles.list}
          keyboardShouldPersistTaps="handled">
          {choices === undefined ? (
            <CommandList
              commands={listed}
              onRun={run}
              subject={subject}
            />
          ) : (
            choices.map((choice) => (
              <CommandRow
                detail={choice.disabled}
                disabled={choice.disabled !== undefined}
                icon={choice.icon ?? 'folder'}
                key={choice.id}
                onPress={() => {
                  choose(choice);
                }}
                title={choice.title}
              />
            ))
          )}
          {(choices ?? listed).length === 0 ? (
            <Text style={[styles.empty, { color: colors.textSecondary }]}>
              {t('commands.empty')}
            </Text>
          ) : null}
        </ScrollView>
      </View>
    </View>
  );
}

function CommandList({
  commands,
  onRun,
  subject,
}: {
  readonly commands: readonly Command[];
  readonly onRun: (command: Command) => void;
  readonly subject: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return commands.map((command, index) => {
    const first =
      index === 0 || commands[index - 1]?.section !== command.section;
    return (
      <View key={command.id}>
        {first ? (
          <Text
            accessibilityRole="header"
            style={[
              styles.section,
              index === 0
                ? null
                : [styles.divider, { borderTopColor: colors.separator }],
              { color: colors.textSecondary },
            ]}>
            {sectionTitle(t, command.section, subject)}
          </Text>
        ) : null}
        <CommandRow
          detail={command.disabled}
          disabled={command.disabled !== undefined}
          icon={command.icon}
          more={command.choices !== undefined}
          onPress={() => {
            onRun(command);
          }}
          title={command.title}
        />
      </View>
    );
  });
}

function CommandRow({
  icon,
  title,
  detail,
  disabled,
  more = false,
  onPress,
}: {
  readonly icon: string;
  readonly title: string;
  readonly detail: string | undefined;
  readonly disabled: boolean;
  readonly more?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const dimmed = disabled ? styles.dimmed : null;
  return (
    <Pressable
      accessibilityLabel={detail === undefined ? title : `${title}. ${detail}`}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={styles.row}>
      <View style={dimmed}>
        <SFSymbol
          name={icon}
          color={colors.textPrimary}
        />
      </View>
      <Text
        numberOfLines={1}
        style={[styles.title, dimmed, { color: colors.textPrimary }]}>
        {title}
      </Text>
      {detail === undefined ? null : (
        <Text style={[styles.detail, { color: colors.textSecondary }]}>
          {detail}
        </Text>
      )}
      {more ? (
        <SFSymbol
          name="chevron.right"
          color={colors.textSecondary}
          size={12}
        />
      ) : null}
    </Pressable>
  );
}

// The visible command input of iPad layouts; iPhone opens the palette by gesture alone.
export function CommandInput({
  style,
}: {
  readonly style?: StyleProp<ViewStyle>;
}) {
  const { open } = useCommandPalette();
  const colors = usePalette();
  const { t } = useLocalization();
  if (!pad) {
    return null;
  }
  return (
    <Pressable
      accessibilityLabel={t('commands.openPalette')}
      accessibilityRole="button"
      onPress={open}
      style={[styles.pill, style, { boxShadow: colors.smallGlassShadow }]}>
      <Glass cornerRadius={18} />
      <SFSymbol
        name="command"
        color={colors.textSecondary}
      />
      <Text style={[styles.pillText, { color: colors.textSecondary }]}>
        {t('commands.open')}
      </Text>
    </Pressable>
  );
}

// The iPad command input on its own row at the top of a screen state that has no header of its
// own, such as a reader or composer that is loading or cannot open; nothing on iPhone.
export function CommandInputRow() {
  if (!pad) {
    return null;
  }
  return (
    <View style={styles.commandRow}>
      <CommandInput />
    </View>
  );
}

const swipe = 24;

// Opens the palette from a header. `swipe` goes on the header's whole area: a downward swipe
// starting on it opens the palette, while swipes that start in the content below scroll it as
// usual. `action` goes on the header's accessible element, where assistive controls find the
// Open Command Palette action.
export function usePaletteHeader(): Readonly<{
  swipe: ViewProps;
  action: ViewProps;
}> {
  const { open } = useCommandPalette();
  const { t } = useLocalization();
  const start = useRef<{ x: number; y: number } | undefined>(undefined);
  const moved = ({ nativeEvent }: GestureResponderEvent) => {
    const from = start.current;
    if (from === undefined) {
      return false;
    }
    const dx = Math.abs(nativeEvent.pageX - from.x);
    const dy = nativeEvent.pageY - from.y;
    return dy >= swipe && dy > dx;
  };
  return {
    swipe: {
      onTouchStart: ({ nativeEvent }) => {
        start.current = { x: nativeEvent.pageX, y: nativeEvent.pageY };
      },
      onMoveShouldSetResponder: moved,
      onResponderGrant: () => {
        start.current = undefined;
        open();
      },
    },
    action: {
      accessibilityActions: [
        { name: 'openCommandPalette', label: t('commands.openPalette') },
      ],
      onAccessibilityAction: ({ nativeEvent }) => {
        if (nativeEvent.actionName === 'openCommandPalette') {
          open();
        }
      },
    },
  };
}

// The one-time explanation of the header swipe on iPhone, kept until dismissed or the palette
// first opens.
export function PaletteHint() {
  const due = useSyncExternalStore(hint.subscribe, hint.getSnapshot);
  const colors = usePalette();
  const { t } = useLocalization();
  if (!due) {
    return null;
  }
  return (
    <View
      style={[
        styles.hint,
        {
          backgroundColor: colors.surfaceContent,
          boxShadow: colors.menuShadow,
        },
      ]}>
      <SFSymbol
        name="hand.draw"
        color={colors.accentInk}
        size={22}
      />
      <View style={styles.hintText}>
        <Text style={[styles.hintTitle, { color: colors.textPrimary }]}>
          {t('commands.hint')}
        </Text>
        <Text style={[styles.hintDetail, { color: colors.textSecondary }]}>
          {t('commands.hintDetail')}
        </Text>
      </View>
      <Pressable
        accessibilityLabel={t('commands.dismissHint')}
        accessibilityRole="button"
        onPress={() => {
          void hint.dismiss();
        }}
        style={styles.dismiss}>
        <View
          style={[styles.dismissCircle, { backgroundColor: colors.fillQuiet }]}>
          <SFSymbol
            name="xmark"
            color={colors.textSecondary}
            size={14}
          />
        </View>
      </Pressable>
    </View>
  );
}
