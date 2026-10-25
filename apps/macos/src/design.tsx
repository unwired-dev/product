import type {
  MenuSection,
  NativeMenuItem,
} from '@private-email/mail-core/context-menu';
import type { ReactNode } from 'react';
import type {
  ColorValue,
  NativeSyntheticEvent,
  StyleProp,
  TurboModule,
  ViewProps,
  ViewStyle,
} from 'react-native';

import { menuState } from '@private-email/mail-core/context-menu';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Easing,
  findNodeHandle,
  processColor,
  Pressable,
  requireNativeComponent,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  useColorScheme,
  View,
} from 'react-native';

import { Label } from './label.tsx';
import { isAlertChoice, isMenuChoice, isTextChoice } from './native-menu.ts';
import { textStyles, usePalette } from './theme.ts';

const NativeSymbol = requireNativeComponent<
  ViewProps & {
    readonly name: string;
    readonly size: number;
    readonly color: ColorValue;
  }
>('UnwiredSymbol');

const NativePushButton = requireNativeComponent<
  ViewProps & {
    readonly text: string;
    readonly label: string;
    readonly tint: ReturnType<typeof processColor>;
    readonly textColor: ReturnType<typeof processColor>;
    readonly focusColor: ReturnType<typeof processColor>;
    readonly destructive: boolean;
    readonly enabled: boolean;
    readonly onPress: () => void;
  }
>('UnwiredPushButton');

const NativeGlass = requireNativeComponent<
  ViewProps & { readonly cornerRadius: number }
>('UnwiredGlass');

export const ModalBackground = requireNativeComponent<ViewProps>(
  'UnwiredModalBackground',
);

export function Glass({
  cornerRadius,
  style = StyleSheet.absoluteFill,
  ...props
}: ViewProps & { readonly cornerRadius: number }) {
  return (
    <NativeGlass
      {...props}
      cornerRadius={cornerRadius}
      style={[style, { borderRadius: cornerRadius, overflow: 'hidden' }]}
    />
  );
}

// Toolbar buttons are 28pt; the group adds a 4pt inset and takes half its height.
const groupRadius = (28 + 2 * spacing.xs) / 2;

const styles = StyleSheet.create({
  menuContent: { flexGrow: 1 },
  group: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    flexWrap: 'wrap',
    padding: spacing.xs,
    borderRadius: groupRadius,
  },
  toolbarButton: {
    minWidth: 32,
    minHeight: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: groupRadius - spacing.xs,
    borderCurve: 'continuous',
  },
  monogram: {
    width: 36,
    height: 36,
    borderRadius: 18,
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: 'center',
    justifyContent: 'center',
  },
  monogramText: { fontSize: 12, lineHeight: 16, fontWeight: '600' },
  marker: { flexDirection: 'row', alignItems: 'flex-start', gap: spacing.xs },
  markerText: { ...textStyles.subheadline, flex: 1 },
  notice: {
    gap: spacing.s,
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  noticeMessage: { flexDirection: 'row', gap: spacing.s },
  noticeMessageText: { flex: 1 },
  noticeActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s,
    paddingLeft: 16 + spacing.s,
  },
  button: {
    height: 28,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
  },
  buttonSizing: { opacity: 0 },
});

// An SF Symbol at regular weight. It is decorative: the control around it carries the label.
export function SFSymbol({
  name,
  color,
  size = 16,
}: {
  readonly name: string;
  readonly color: ColorValue;
  readonly size?: number;
}) {
  return (
    <NativeSymbol
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      name={name}
      size={size}
      color={color}
      style={{ width: size, height: size }}
    />
  );
}

const NativeContextMenu = requireNativeComponent<
  ViewProps & {
    readonly destructiveColor: ColorValue;
    readonly sections: ReadonlyArray<
      Readonly<{
        palette?: boolean | undefined;
        items: readonly NativeMenuItem[];
      }>
    >;
    readonly onSelect: (event: NativeSyntheticEvent<{ id: string }>) => void;
  }
>('UnwiredContextMenu');

// The system context menu for its children: long-press on iPhone and iPad, secondary click with
// a pointer or on the Mac. Empty sections are left out.
export function ContextMenu({
  sections,
  children,
  ...props
}: ViewProps & { readonly sections: readonly MenuSection[] }) {
  const colors = usePalette();
  const menu = menuState(sections);
  return (
    <NativeContextMenu
      {...props}
      destructiveColor={colors.statusDestructive}
      sections={menu.sections}
      onSelect={({ nativeEvent }) => {
        void menu.runs.get(nativeEvent.id)?.();
      }}>
      {/* React Native's legacy view interop mounts a nested menu without its offset, so another
          menu never becomes this one's direct native child. */}
      <View
        collapsable={false}
        style={styles.menuContent}>
        {children}
      </View>
    </NativeContextMenu>
  );
}

interface NativeMenu extends TurboModule {
  readonly show: (
    anchor: number,
    sections: ReturnType<typeof menuState>['sections'],
    destructiveColor: ReturnType<typeof processColor>,
  ) => Promise<unknown>;
}

// A pull-down button whose AppKit menu drops below it on click, Space or VoiceOver press. Its
// children draw the label; the latest items answer the chosen one.
export function MenuButton({
  sections,
  children,
  style,
  ...props
}: ViewProps & { readonly sections: readonly MenuSection[] }) {
  const colors = usePalette();
  const dark = useColorScheme() === 'dark';
  const anchor = useRef<View>(null);
  const latest = useRef(menuState(sections));
  const [open, setOpen] = useState(false);
  const [focused, setFocused] = useState(false);
  useLayoutEffect(() => {
    latest.current = menuState(sections);
    return () => {
      latest.current.runs.clear();
    };
  });
  const show = async () => {
    const tag = findNodeHandle(anchor.current);
    if (tag === null) {
      return;
    }
    const menu = TurboModuleRegistry.getEnforcing<NativeMenu>('UnwiredMenu');
    setOpen(true);
    const chosen = await menu
      .show(
        tag,
        latest.current.sections,
        processColor(colors.statusDestructive),
      )
      .finally(() => {
        setOpen(false);
      });
    if (isMenuChoice(chosen) && chosen !== null) {
      await latest.current.runs.get(chosen)?.();
    }
  };
  return (
    <Pressable
      {...props}
      ref={anchor}
      collapsable={false}
      accessibilityRole="button"
      // In Dark, an accent/ink ring replaces the system focus ring.
      enableFocusRing={!dark}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={() => {
        void show();
      }}
      style={({ pressed }) => [
        style,
        pressed || open
          ? { backgroundColor: colors.accentSelectionSubtle }
          : null,
        dark && focused
          ? { outlineWidth: 3, outlineColor: colors.accentInk }
          : null,
      ]}>
      {children}
    </Pressable>
  );
}

type SheetQuestion = Readonly<{
  title: string;
  detail: string;
  buttons: readonly string[];
  // The button Escape answers; the last unless given.
  cancel?: number;
  destructive?: number;
  // An SF Symbol in place of the app icon.
  symbol?: Readonly<{ name: string; color: ColorValue }>;
  // A complete selectable text below the detail that scrolls beyond a few lines.
  passage?: string;
  // A focused text field's placeholder; see askForText.
  field?: string;
}>;

interface NativeAlert extends TurboModule {
  readonly show: (
    anchor: number,
    request: number,
    question: Omit<SheetQuestion, 'symbol'> & {
      readonly symbol?: Readonly<{ name: string; color: unknown }>;
    },
  ) => Promise<unknown>;
  readonly retire: (request: number) => void;
}

let alertRequests = 0;

// Asks in an AppKit alert sheet on `anchor`'s window. `answer` resolves the native answer when
// `answers` accepts it, otherwise null; `retire` closes the sheet and ignores later native results.
function sheet<A>(
  anchor: View | null,
  question: SheetQuestion,
  answers: (chosen: unknown) => chosen is A,
) {
  const alert = TurboModuleRegistry.getEnforcing<NativeAlert>('UnwiredAlert');
  const tag = findNodeHandle(anchor);
  alertRequests += 1;
  const request = alertRequests;
  let current = tag !== null;
  const ask = async () => {
    if (tag === null) {
      return null;
    }
    const { symbol } = question;
    const chosen = await alert.show(
      tag,
      request,
      symbol === undefined
        ? question
        : {
            ...question,
            symbol: { name: symbol.name, color: processColor(symbol.color) },
          },
    );
    return current && answers(chosen) ? chosen : null;
  };
  return {
    answer: ask(),
    retire: () => {
      if (current) {
        current = false;
        alert.retire(request);
      }
    },
  };
}

// Asks in an AppKit alert sheet on `anchor`'s window. `answer` resolves the chosen button's index;
// the first button is the default and `cancel` answers Escape. `retire` closes the sheet
// and ignores later native results. The caller must still check its lifetime after awaiting `answer`.
export const askInSheet = (
  anchor: View | null,
  question: Omit<SheetQuestion, 'field'>,
) => sheet(anchor, question, isAlertChoice);

// Asks as askInSheet does, with a focused text field showing `field` as its placeholder; `answer`
// resolves the chosen button's index with the field's text.
export const askForText = (
  anchor: View | null,
  question: SheetQuestion & { readonly field: string },
) => sheet(anchor, question, isTextChoice);

// A Liquid Glass toolbar group on the navigation layer; never place it on content or other glass.
export function GlassGroup({
  children,
  style,
}: {
  readonly children: ReactNode;
  readonly style?: StyleProp<ViewStyle>;
}) {
  const colors = usePalette();
  const cornerRadius = StyleSheet.flatten(style)?.borderRadius;
  return (
    <View
      style={[
        styles.group,
        {
          boxShadow: colors.smallGlassShadow,
          backgroundColor: colors.surfaceContent,
        },
        style,
      ]}>
      <Glass
        cornerRadius={
          typeof cornerRadius === 'number' ? cornerRadius : groupRadius
        }
        style={StyleSheet.absoluteFill}
      />
      {children}
    </View>
  );
}

// A panel that animates and hides from VoiceOver, which core React Native does not do on Mac.
export const AnimatedPanel = Animated.createAnimatedComponent(ModalBackground);

const easeOut = Easing.bezier(0.23, 1, 0.32, 1);

// Reduce Motion, following changes while shown. It reads as on until the system answers.
export function useReducedMotion() {
  const [reduced, setReduced] = useState(true);
  useEffect(() => {
    let current = true;
    const read = async () => {
      const enabled = await AccessibilityInfo.isReduceMotionEnabled();
      if (current) {
        setReduced(enabled);
      }
    };
    void read();
    const subscription = AccessibilityInfo.addEventListener(
      'reduceMotionChanged',
      (enabled) => {
        current = false;
        setReduced(enabled);
      },
    );
    return () => {
      current = false;
      subscription.remove();
    };
  }, []);
  return reduced;
}

// Keeps a menu shown until its exit finishes: it eases in over 200 ms and fades away over 150 ms,
// growing slightly out of its control or arriving 8pt from above. Reduce Motion keeps only the fade.
export function useMenuMotion(open: boolean, arrival: 'grow' | 'drop') {
  const [shown, setShown] = useState(open);
  const progress = useMemo(() => new Animated.Value(0), []);
  const reduced = useReducedMotion();
  if (open && !shown) {
    setShown(true);
  }
  useEffect(() => {
    const animation = Animated.timing(progress, {
      toValue: open ? 1 : 0,
      duration: open ? 200 : 150,
      easing: easeOut,
      useNativeDriver: true,
    });
    animation.start(({ finished }) => {
      if (finished && !open) {
        setShown(false);
      }
    });
    return () => {
      animation.stop();
    };
  }, [open, progress]);
  const transform =
    arrival === 'grow'
      ? {
          scale: progress.interpolate({
            inputRange: [0, 1],
            outputRange: [0.95, 1],
          }),
        }
      : {
          translateY: progress.interpolate({
            inputRange: [0, 1],
            outputRange: [-8, 0],
          }),
        };
  return {
    shown: open || shown,
    style: { opacity: progress, transform: reduced ? [] : [transform] },
  };
}

// A menu that eases out of its control and fades away once closed. Closing hides it from
// VoiceOver and the pointer at once.
export function MenuPresence({
  open,
  origin,
  style,
  children,
  ...props
}: ViewProps & {
  readonly open: boolean;
  // The corner of its control the menu grows from, as a CSS transform origin.
  readonly origin: string;
}) {
  const motion = useMenuMotion(open, 'grow');
  if (!motion.shown) {
    return null;
  }
  return (
    <AnimatedPanel
      {...props}
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      style={[style, motion.style, { transformOrigin: origin }]}>
      {children}
    </AnimatedPanel>
  );
}

// An icon button on a toolbar's glass: the label is for accessibility, the SF Symbol for sight.
export function ToolbarButton({
  label,
  icon,
  onPress,
  disabled = false,
  selected,
  destructive = false,
  accessibilityHint,
}: {
  readonly label: string;
  readonly icon: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  // A toggle, such as a format bar mark, reports whether it is on; it is outlined, not by fill alone.
  readonly selected?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityHint?: string;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityHint={accessibilityHint}
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{
        disabled,
        ...(selected === undefined ? {} : { selected }),
      }}
      disabled={disabled}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.toolbarButton,
        {
          backgroundColor:
            pressed || selected === true
              ? colors.accentSelectionSubtle
              : 'transparent',
          borderWidth: 2,
          borderColor:
            focused || selected === true ? colors.accentInk : 'transparent',
          opacity: disabled ? 0.4 : 1,
        },
      ]}>
      <SFSymbol
        name={icon}
        size={16}
        color={destructive ? colors.statusDestructive : colors.textPrimary}
      />
    </Pressable>
  );
}

// Neutral initials for a sender without a contact photo; never a generated color.
export function Monogram({ name }: { readonly name: string }) {
  const colors = usePalette();
  const initials = name
    .split(/\s+/u)
    .filter((word) => word !== '')
    .slice(0, 2)
    .map((word) => [...word][0]?.toLocaleUpperCase() ?? '')
    .join('');
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.monogram,
        {
          backgroundColor: colors.surfaceBubble,
          borderColor: colors.separator,
        },
      ]}>
      <Text style={[styles.monogramText, { color: colors.textSecondary }]}>
        {initials}
      </Text>
    </View>
  );
}

// A banner beside the content it explains, with its actions stacked under the message.
// A warning tints its icon; the message is an alert when it reports a failure.
export function Notice({
  icon,
  iconColor,
  message,
  messageRole = 'text',
  announce,
  children,
}: {
  readonly icon: string;
  readonly iconColor?: ColorValue;
  readonly message: string;
  readonly messageRole?: 'alert' | 'text';
  // Preserves live-region semantics; native announcement support is platform-specific.
  readonly announce?: 'polite';
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.notice, { backgroundColor: colors.fillQuiet }]}>
      <View style={styles.noticeMessage}>
        <SFSymbol
          name={icon}
          color={iconColor ?? colors.textSecondary}
        />
        <View style={styles.noticeMessageText}>
          <Label
            accessibilityLiveRegion={announce}
            accessibilityRole={messageRole}
            style={[textStyles.body, { color: colors.textPrimary }]}>
            {message}
          </Label>
        </View>
      </View>
      {children === undefined ? null : (
        <View style={styles.noticeActions}>{children}</View>
      )}
    </View>
  );
}

// A push button, 28pt tall, that AppKit draws: the accent tint carries the view's main action and
// the brand tint Welcome's Continue; the others take the standard bezel.
export function Button({
  label,
  onPress,
  fill = 'quiet',
  disabled = false,
  destructive = false,
  accessibilityLabel,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly fill?: 'accent' | 'brand' | 'quiet';
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityLabel?: string;
}) {
  const colors = usePalette();
  const dark = useColorScheme() === 'dark';
  const tints = {
    accent: [colors.accentFill, colors.accentOnFill],
    brand: [colors.brandSeal, colors.brandOnSeal],
    quiet: [undefined, destructive ? colors.statusDestructive : undefined],
  } as const;
  const [tint, textColor] = tints[fill];
  return (
    <View style={styles.button}>
      {/* The hidden title sizes the button, which AppKit draws over it. */}
      <Text
        style={[
          tint === undefined ? textStyles.body : textStyles.bodyEmphasized,
          styles.buttonSizing,
        ]}>
        {label}
      </Text>
      {/* The accessibility props serve Testing Library; VoiceOver reads the AppKit button. */}
      <NativePushButton
        accessible
        accessibilityLabel={accessibilityLabel ?? label}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
        destructive={destructive}
        enabled={!disabled}
        focusColor={dark ? processColor(colors.accentInk) : undefined}
        onPress={onPress}
        style={StyleSheet.absoluteFill}
        label={accessibilityLabel ?? label}
        text={label}
        textColor={processColor(textColor)}
        tint={processColor(tint)}
      />
    </View>
  );
}

// The existing disclosure stays beside unaccepted assistance output and disappears with it.
export function OnDeviceMarker({ label }: { readonly label: string }) {
  const colors = usePalette();
  return (
    <View
      accessible
      accessibilityLabel={label}
      accessibilityRole="text"
      style={styles.marker}>
      <SFSymbol
        name="lock.fill"
        color={colors.onDeviceInk}
      />
      <Text
        selectable
        style={[styles.markerText, { color: colors.onDeviceInk }]}>
        {label}
      </Text>
    </View>
  );
}

// VoiceOver hears an assistance outcome once when it appears, since iOS and macOS ignore live
// regions and the alert role: a ready result after current speech, a failure at once.
export function useOutcomeAnnouncement(
  words: string | undefined,
  queue: boolean,
) {
  useEffect(() => {
    if (words !== undefined) {
      AccessibilityInfo.announceForAccessibilityWithOptions(words, { queue });
    }
  }, [words, queue]);
}
