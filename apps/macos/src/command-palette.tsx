import type {
  Command,
  CommandChoice,
  CommandRegistry,
} from '@private-email/mail-core/commands';
import type { ReactNode } from 'react';
import type {
  KeyEvent,
  TextInput as TextInputHandle,
  TurboModule,
} from 'react-native';

import {
  createCommandRegistry,
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
  NativeEventEmitter,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { Glass, SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
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

interface CommandMenu extends TurboModule {
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
}

// The Commands… menu item, Command-P, names the key window it was chosen in.
const commandMenu = () =>
  TurboModuleRegistry.get<CommandMenu>('UnwiredCommands');

// The keys the palette's input handles itself; the rest edit the query as usual.
const handledKeys = [
  { key: 'ArrowUp' },
  { key: 'ArrowDown' },
  { key: 'Escape' },
];

const barHeight = 44;
const inputHeight = 36;
const inputWidth = 320;
const panelWidth = 460;
// The focus ring sits 3pt outside the input.
const ringWidth = 3;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  bar: {
    height: barHeight,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: spacing.m,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  pill: {
    width: inputWidth,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    height: inputHeight,
    paddingLeft: spacing.m,
    paddingRight: spacing.s,
    borderRadius: inputHeight / 2,
    borderCurve: 'continuous',
  },
  focusRing: {
    position: 'absolute',
    top: -ringWidth,
    left: -ringWidth,
    right: -ringWidth,
    bottom: -ringWidth,
    borderWidth: ringWidth,
    borderRadius: inputHeight / 2 + ringWidth,
    borderCurve: 'continuous',
    opacity: 0.3,
  },
  pillText: { ...textStyles.body, flex: 1 },
  key: {
    fontSize: 10,
    lineHeight: 13,
    fontWeight: '500',
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 5,
    overflow: 'hidden',
  },
  chip: {
    ...textStyles.bodyEmphasized,
    paddingHorizontal: spacing.s,
    paddingVertical: 2,
    borderRadius: radius.control,
    overflow: 'hidden',
  },
  input: { ...textStyles.body, flex: 1, paddingVertical: 0 },
  layer: { zIndex: 10 },
  // Beneath the bar and its panel, over the window's content.
  scrim: { zIndex: 5 },
  panel: {
    position: 'absolute',
    // 6pt beneath the input, which is centered in the bar.
    top: (barHeight + inputHeight) / 2 + 6,
    left: spacing.m,
    width: panelWidth,
    maxHeight: 520,
    padding: 6,
    borderRadius: radius.card + 2,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
  },
  backRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.xs,
    paddingBottom: spacing.s,
    marginBottom: spacing.xs,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  back: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    height: 24,
    paddingHorizontal: spacing.s,
    borderRadius: radius.control,
  },
  backText: { ...textStyles.body },
  choosing: { ...textStyles.bodyEmphasized, flex: 1 },
  choosingSubject: { ...textStyles.subheadline, flexShrink: 1 },
  section: {
    ...textStyles.subheadline,
    fontWeight: '600',
    paddingTop: spacing.s,
    paddingBottom: spacing.xs,
    paddingHorizontal: spacing.s + 2,
  },
  divider: { borderTopWidth: StyleSheet.hairlineWidth, marginTop: spacing.xs },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    height: 28,
    paddingLeft: spacing.s,
    paddingRight: 10,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  title: { ...textStyles.body, flex: 1 },
  // A command that cannot run keeps its name legible but recedes behind its reason.
  dimmed: { opacity: 0.35 },
  detail: { ...textStyles.subheadline },
  empty: { ...textStyles.body, padding: spacing.m },
  hints: {
    flexDirection: 'row',
    gap: spacing.l,
    paddingHorizontal: 10,
    paddingTop: spacing.s,
    paddingBottom: spacing.xs,
    borderTopWidth: StyleSheet.hairlineWidth,
    marginTop: spacing.xs,
  },
  hint: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  hintText: { fontSize: 10, lineHeight: 13 },
});

// Mounts the palette over its children; every window has one.
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
  const value = useMemo(
    () => ({
      registry,
      opened,
      open: () => {
        if (opened !== undefined) {
          return;
        }
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
        {opened === undefined ? null : (
          // A click anywhere outside the bar and its panel closes the palette without reaching the
          // control beneath.
          <Pressable
            accessibilityLabel={t('commands.close')}
            accessibilityRole="button"
            onPress={() => {
              value.close();
            }}
            style={[StyleSheet.absoluteFill, styles.scrim]}
          />
        )}
      </View>
    </PaletteContext>
  );
}

// Opens this window's palette when its Commands… menu item, Command-P, is chosen.
export function CommandMenuListener({
  windowId,
}: {
  readonly windowId: string;
}) {
  const { open } = useCommandPalette();
  useEffect(() => {
    const menu = commandMenu();
    if (menu === null) {
      return;
    }
    const subscription = new NativeEventEmitter(menu).addListener(
      'openCommandPalette',
      ({ window }: { readonly window: string }) => {
        if (window === `inbox-window-${windowId}`) {
          open();
        }
      },
    );
    return () => {
      subscription.remove();
    };
  }, [open, windowId]);
  return null;
}

// The command input that stays visible at the top of the window. While the palette is closed it
// is a button; open, it is the focused query with the matching commands beneath.
export function CommandBar() {
  const { opened, open } = use(PaletteContext);
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View
      style={[
        styles.bar,
        styles.layer,
        {
          backgroundColor: colors.surfaceSidebar,
          borderBottomColor: colors.separator,
        },
      ]}>
      {opened === undefined ? (
        <Pressable
          accessibilityLabel={t('commands.openPalette')}
          accessibilityRole="button"
          onPress={open}
          style={[styles.pill, { boxShadow: colors.smallGlassShadow }]}>
          <Glass cornerRadius={inputHeight / 2} />
          <SFSymbol
            name="command"
            color={colors.textSecondary}
          />
          <Text style={[styles.pillText, { color: colors.textSecondary }]}>
            {t('commands.open')}
          </Text>
          <Text
            style={[
              styles.key,
              {
                backgroundColor: colors.fillQuiet,
                color: colors.textSecondary,
              },
            ]}>
            {t('commands.shortcut')}
          </Text>
        </Pressable>
      ) : (
        <Palette opened={opened} />
      )}
    </View>
  );
}

// The open palette: the focused query in the bar, and beneath it the matching commands or the
// choices of the command being completed. Up and Down select, Return runs, Escape goes back.
function Palette({ opened }: { readonly opened: readonly Command[] }) {
  const { registry, close } = use(PaletteContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const [query, setQuery] = useState('');
  const [choosing, setChoosing] = useState<Command>();
  const [choiceQuery, setChoiceQuery] = useState('');
  const [highlighted, setHighlighted] = useState(0);
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
      setHighlighted(0);
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
  const back = () => {
    setChoosing(undefined);
    setHighlighted(0);
  };
  const subject = opened.find(({ target }) => target !== undefined)?.target
    ?.subject;
  const choices =
    choosing?.choices === undefined
      ? undefined
      : matchCommands(choiceQuery, choosing.choices);
  // The highlighted row among the enabled ones, which Up and Down move through.
  const rows: ReadonlyArray<Command | CommandChoice> = choices ?? listed;
  const enabled = rows
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => item.disabled === undefined);
  const selected =
    enabled.length === 0
      ? undefined
      : enabled[Math.min(highlighted, enabled.length - 1)];
  const submit = () => {
    if (selected === undefined) {
      return;
    }
    if ('section' in selected.item) {
      run(selected.item);
    } else {
      choose(selected.item);
    }
  };
  const keyDown = ({ nativeEvent }: KeyEvent) => {
    if (nativeEvent.key === 'Escape') {
      if (choosing === undefined) {
        close();
      } else {
        back();
      }
    } else if (nativeEvent.key === 'ArrowDown') {
      setHighlighted(Math.min(highlighted + 1, enabled.length - 1));
    } else if (nativeEvent.key === 'ArrowUp') {
      setHighlighted(Math.max(highlighted - 1, 0));
    }
  };
  const prompt =
    choosing === undefined
      ? t('commands.placeholder')
      : t('commands.chooseFolder');
  return (
    <>
      <View style={[styles.pill, { boxShadow: colors.smallGlassShadow }]}>
        <Glass cornerRadius={inputHeight / 2} />
        <View
          pointerEvents="none"
          style={[styles.focusRing, { borderColor: colors.accentFill }]}
        />
        <SFSymbol
          name="command"
          color={colors.textPrimary}
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
          keyDownEvents={handledKeys}
          onChangeText={(text) => {
            setHighlighted(0);
            if (choosing === undefined) {
              setQuery(text);
            } else {
              setChoiceQuery(text);
            }
          }}
          onKeyDown={keyDown}
          // The input receives focus as soon as the palette, or its picker, appears.
          onLayout={() => {
            input.current?.focus();
          }}
          onSubmitEditing={submit}
          placeholder={prompt}
          placeholderTextColor={colors.textSecondary}
          ref={input}
          style={[styles.input, { color: colors.textPrimary }]}
          value={choosing === undefined ? query : choiceQuery}
        />
        <Text
          style={[
            styles.key,
            { backgroundColor: colors.fillQuiet, color: colors.textSecondary },
          ]}>
          {t('commands.escape')}
        </Text>
      </View>
      <View
        style={[
          styles.panel,
          { borderColor: colors.separator, boxShadow: colors.menuShadow },
        ]}
        testID="command-palette">
        <Glass cornerRadius={radius.card + 2} />
        {choosing === undefined ? null : (
          <View
            style={[styles.backRow, { borderBottomColor: colors.separator }]}>
            <Pressable
              accessibilityLabel={t('commands.backLabel')}
              accessibilityRole="button"
              onPress={back}
              style={[styles.back, { backgroundColor: colors.fillQuiet }]}>
              <SFSymbol
                name="chevron.left"
                color={colors.textPrimary}
                size={12}
              />
              <Text style={[styles.backText, { color: colors.textPrimary }]}>
                {t('commands.back')}
              </Text>
            </Pressable>
            <Label style={[styles.choosing, { color: colors.textPrimary }]}>
              {choosing.choosing ?? choosing.title}
            </Label>
            {/* A picker belongs to the open message, so the subject is always known here. */}
            <Text
              numberOfLines={1}
              style={[styles.choosingSubject, { color: colors.textSecondary }]}>
              {subject}
            </Text>
          </View>
        )}
        <ScrollView>
          {choices === undefined ? (
            <CommandList
              commands={listed}
              highlighted={selected?.index}
              onRun={run}
              subject={subject}
            />
          ) : (
            choices.map((choice, index) => (
              <CommandRow
                detail={choice.disabled}
                disabled={choice.disabled !== undefined}
                highlighted={selected?.index === index}
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
            <Label style={[styles.empty, { color: colors.textSecondary }]}>
              {t('commands.empty')}
            </Label>
          ) : null}
        </ScrollView>
        <View style={[styles.hints, { borderTopColor: colors.separator }]}>
          <Hint
            keys={t('commands.keys.arrows')}
            label={t('commands.keys.select')}
          />
          <Hint
            keys={t('commands.keys.return')}
            label={t(
              choosing === undefined
                ? 'commands.keys.run'
                : 'commands.keys.move',
            )}
          />
          <Hint
            keys={t('commands.keys.escape')}
            label={t(
              choosing === undefined
                ? 'commands.keys.close'
                : 'commands.keys.back',
            )}
          />
        </View>
      </View>
    </>
  );
}

function Hint({
  keys,
  label,
}: {
  readonly keys: string;
  readonly label: string;
}) {
  const colors = usePalette();
  return (
    <View style={styles.hint}>
      <Text
        style={[
          styles.key,
          { backgroundColor: colors.fillQuiet, color: colors.textSecondary },
        ]}>
        {keys}
      </Text>
      <Text style={[styles.hintText, { color: colors.textSecondary }]}>
        {label}
      </Text>
    </View>
  );
}

function CommandList({
  commands,
  highlighted,
  onRun,
  subject,
}: {
  readonly commands: readonly Command[];
  readonly highlighted: number | undefined;
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
          <Label
            accessibilityRole="header"
            style={[
              styles.section,
              index === 0
                ? null
                : [styles.divider, { borderTopColor: colors.separator }],
              { color: colors.textSecondary },
            ]}>
            {sectionTitle(t, command.section, subject)}
          </Label>
        ) : null}
        <CommandRow
          detail={command.disabled}
          disabled={command.disabled !== undefined}
          highlighted={highlighted === index}
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
  highlighted,
  more = false,
  onPress,
}: {
  readonly icon: string;
  readonly title: string;
  readonly detail: string | undefined;
  readonly disabled: boolean;
  readonly highlighted: boolean;
  readonly more?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const color = highlighted ? colors.accentOnFill : colors.textPrimary;
  const secondary = highlighted ? colors.accentOnFill : colors.textSecondary;
  const dimmed = disabled ? styles.dimmed : null;
  return (
    <Pressable
      accessibilityLabel={detail === undefined ? title : `${title}. ${detail}`}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected: highlighted }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.row,
        highlighted ? { backgroundColor: colors.accentFill } : null,
      ]}>
      <View style={dimmed}>
        <SFSymbol
          name={icon}
          color={color}
        />
      </View>
      <Text
        numberOfLines={1}
        style={[styles.title, dimmed, { color }]}>
        {title}
      </Text>
      {detail === undefined ? null : (
        <Text style={[styles.detail, { color: secondary }]}>{detail}</Text>
      )}
      {more ? (
        <SFSymbol
          name="chevron.right"
          color={secondary}
          size={12}
        />
      ) : null}
    </Pressable>
  );
}
