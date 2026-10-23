import type {
  MenuSection,
  NativeMenuItem,
} from '@private-email/mail-core/context-menu';
import type { ReactNode, Ref } from 'react';
import type {
  ColorValue,
  GestureResponderEvent,
  NativeSyntheticEvent,
  StyleProp,
  TextProps,
  ViewProps,
  ViewStyle,
} from 'react-native';

import { menuState } from '@private-email/mail-core/context-menu';
import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { GlassView } from 'expo-glass-effect';
import { useEffect, useMemo, useState } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Easing,
  Pressable,
  Platform,
  requireNativeComponent,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { textStyles, usePalette } from './theme.ts';

const NativeSymbol = requireNativeComponent<
  ViewProps & {
    readonly name: string;
    readonly size: number;
    readonly color: ColorValue;
  }
>('UnwiredSymbol');

export function Glass({
  cornerRadius,
  interactive = false,
  style = StyleSheet.absoluteFill,
  ...props
}: ViewProps & {
  readonly cornerRadius: number;
  // Controls inside interactive glass get the system press response.
  readonly interactive?: boolean;
}) {
  return (
    <GlassView
      {...props}
      isInteractive={interactive}
      style={[style, { borderRadius: cornerRadius }]}
    />
  );
}

interface NavigationChromeProps extends Pick<ViewProps, 'testID'> {
  readonly onPop?: (() => void) | undefined;
  // A screen that names its Back keeps the system navigation bar instead of hiding it.
  readonly backLabel?: string | undefined;
  // Shown on a disk beside the Back chevron; empty shows the chevron alone.
  readonly backCount?: string | undefined;
  // Fills the screen behind the bar.
  readonly surface?: ColorValue | undefined;
}

const NativeNavigationChrome = requireNativeComponent<
  ViewProps & NavigationChromeProps
>('UnwiredNavigationChrome');

// Hides the native navigation bar while a compact screen shows its own header, unless the screen
// names its system Back. Back or the edge swipe pops the screen, and onPop lets its route follow.
export function NavigationChrome(props: NavigationChromeProps) {
  return (
    <NativeNavigationChrome
      {...props}
      style={{ position: 'absolute', width: 0, height: 0 }}
    />
  );
}

const easeOut = Easing.bezier(0.23, 1, 0.32, 1);
const easeSheet = Easing.bezier(0.32, 0.72, 0, 1);

// Keep the presentation mounted until its exit finishes, but hide closing controls immediately.
export function useMenuMotion(open: boolean, kind: 'menu' | 'grow') {
  const [shown, setShown] = useState(open);
  const progress = useMemo(() => new Animated.Value(0), []);
  const [reduced, setReduced] = useState(true);
  const enteringDuration = kind === 'menu' || reduced ? 200 : 300;
  if (open && !shown) {
    setShown(true);
  }
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
  useEffect(() => {
    const animation = Animated.timing(progress, {
      toValue: open ? 1 : 0,
      duration: open ? enteringDuration : 150,
      easing: open && kind !== 'menu' ? easeSheet : easeOut,
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
  }, [open, kind, enteringDuration, progress]);
  const backdropStyle = { opacity: progress };
  // A grown sheet starts small at its control; a menu barely scales.
  const transform = [
    {
      scale: progress.interpolate({
        inputRange: [0, 1],
        outputRange: [kind === 'grow' ? 0.3 : 0.95, 1],
      }),
    },
  ];
  const style = {
    opacity:
      kind === 'grow'
        ? progress.interpolate({
            inputRange: [0, 0.3, 1],
            outputRange: [0, 1, 1],
          })
        : progress,
    transform: reduced ? [] : transform,
  };
  return { shown: open || shown, style, backdropStyle };
}

// The iPhone's menus open above its bottom toolbar; elsewhere they hang from the top one.
const iphone = Platform.OS === 'ios' && !Platform.isPad;

// Toolbar buttons are 44pt for touch; the group adds a 4pt inset and takes half its height.
const groupRadius = (44 + 2 * spacing.xs) / 2;

const styles = StyleSheet.create({
  menuContent: { flexGrow: 1 },
  group: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    flexWrap: 'wrap',
    padding: spacing.xs,
    borderRadius: groupRadius,
  },
  anchor: { alignSelf: 'flex-start', flexShrink: 1 },
  panel: { borderRadius: radius.menu, maxWidth: '100%' },
  toolbarButton: {
    minWidth: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: groupRadius - spacing.xs,
    borderCurve: 'continuous',
  },
  chipTarget: { minHeight: 44, maxWidth: '100%', justifyContent: 'center' },
  buttonTarget: { minHeight: 44, justifyContent: 'center' },
  buttonFill: {
    minHeight: 28,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  monogram: {
    borderWidth: StyleSheet.hairlineWidth,
    alignItems: 'center',
    justifyContent: 'center',
  },
  monogramText: { fontSize: 12, lineHeight: 16, fontWeight: '600' },
  marker: { flexDirection: 'row', alignItems: 'flex-start', gap: spacing.xs },
  markerText: { ...textStyles.footnote, flex: 1 },
  notice: {
    gap: spacing.s,
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  noticeMessage: { flexDirection: 'row', gap: spacing.s },
  noticeText: {
    ...(Platform.OS === 'ios' && Platform.isPad
      ? typography.ipadList.body
      : textStyles.body),
    flex: 1,
  },
  noticeActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s,
    paddingLeft: 16 + spacing.s,
  },
  button: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
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
    readonly previewColor: ColorValue;
    readonly previewRadius: number;
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
      previewColor={colors.surfaceContent}
      previewRadius={radius.card}
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

const NativeMenuButton = requireNativeComponent<
  ViewProps & {
    readonly sections: ReadonlyArray<
      Readonly<{
        palette?: boolean | undefined;
        items: readonly NativeMenuItem[];
      }>
    >;
    readonly onSelect: (event: NativeSyntheticEvent<{ id: string }>) => void;
  }
>('UnwiredMenuButton');

// A pull-down button whose system menu opens on tap or click. Its children only draw the label:
// the native button receives every touch and carries the accessibility label.
export function MenuButton({
  sections,
  children,
  style,
  ...props
}: ViewProps & { readonly sections: readonly MenuSection[] }) {
  const menu = menuState(sections);
  return (
    <NativeMenuButton
      {...props}
      accessibilityRole="button"
      sections={menu.sections}
      onSelect={({ nativeEvent }) => {
        void menu.runs.get(nativeEvent.id)?.();
      }}
      style={style}>
      <View
        collapsable={false}
        pointerEvents="none"
        style={styles.menuContent}>
        {children}
      </View>
    </NativeMenuButton>
  );
}

// A Liquid Glass toolbar group on the navigation layer; never place it on content or other glass.
export function GlassGroup({
  children,
  style,
  ref,
  pointerEvents,
}: {
  readonly children: ReactNode;
  readonly style?: StyleProp<ViewStyle>;
  readonly pointerEvents?: ViewProps['pointerEvents'];
  // Where a popover anchors to the group.
  readonly ref?: Ref<View> | undefined;
}) {
  const colors = usePalette();
  const cornerRadius = StyleSheet.flatten(style)?.borderRadius;
  const group = (
    <Glass
      interactive
      pointerEvents={pointerEvents}
      cornerRadius={
        typeof cornerRadius === 'number' ? cornerRadius : groupRadius
      }
      style={[styles.group, { boxShadow: colors.smallGlassShadow }, style]}>
      {children}
    </Glass>
  );
  // shortcut: Expo resolves another React Ref type; drop this host anchor when its types align.
  return ref === undefined ? (
    group
  ) : (
    <View
      ref={ref}
      style={styles.anchor}>
      {group}
    </View>
  );
}

// Menus float independently of their toolbar, with the deeper menu shadow.
export function GlassPanel({
  open,
  children,
  cornerRadius = radius.menu,
  origin = iphone ? 'bottom' : 'top right',
  style,
}: {
  readonly open: boolean;
  readonly children: ReactNode;
  readonly cornerRadius?: number;
  readonly style?: StyleProp<ViewStyle>;
  // Where the panel grows from: the control that opened it.
  readonly origin?: string;
}) {
  const colors = usePalette();
  const motion = useMenuMotion(open, 'menu');
  if (!motion.shown) {
    return null;
  }
  return (
    <Animated.View
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      style={[
        styles.panel,
        style,
        motion.style,
        {
          borderRadius: cornerRadius,
          boxShadow: colors.menuGlassShadow,
          backgroundColor: colors.surfaceContent,
          transformOrigin: origin,
        },
      ]}>
      <Glass
        cornerRadius={cornerRadius}
        style={StyleSheet.absoluteFill}
      />
      {children}
    </Animated.View>
  );
}

// An icon button on a toolbar's glass: the label is for accessibility, the SF Symbol for sight.
export function ToolbarButton({
  label,
  icon,
  onPress,
  disabled = false,
  expanded,
  selected,
  destructive = false,
  accessibilityHint,
}: {
  readonly label: string;
  readonly icon: string;
  readonly onPress: (event: GestureResponderEvent) => void;
  readonly disabled?: boolean;
  // A control that reveals a panel reports whether the panel is open.
  readonly expanded?: boolean;
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
        ...(expanded === undefined ? {} : { expanded }),
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
            pressed || expanded === true || selected === true
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
        size={20}
        color={destructive ? colors.statusDestructive : colors.textPrimary}
      />
    </Pressable>
  );
}

// Neutral initials for a sender without a contact photo; never a generated color.
export function Monogram({
  name,
  size = 36,
}: {
  readonly name: string;
  readonly size?: 36 | 48;
}) {
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
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: colors.surfaceBubble,
          borderColor: colors.separator,
        },
      ]}>
      <Text
        style={[
          size === 48 ? textStyles.headline : styles.monogramText,
          { color: colors.textSecondary },
        ]}>
        {initials}
      </Text>
    </View>
  );
}

// A banner beside the content it explains, with its actions stacked under the message. A warning
// tints its icon; the message is an alert when it reports a failure.
export function Notice({
  icon,
  iconColor,
  message,
  messageRole,
  messageActions,
  announce,
  children,
}: {
  readonly icon: string;
  readonly iconColor?: ColorValue;
  readonly message: string;
  readonly messageRole?: 'alert';
  // Accessibility actions on the message, such as a screen header's Open Command Palette.
  readonly messageActions?:
    | Pick<TextProps, 'accessibilityActions' | 'onAccessibilityAction'>
    | undefined;
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
        <Text
          accessibilityLiveRegion={announce}
          accessibilityRole={messageRole}
          style={[styles.noticeText, { color: colors.textPrimary }]}
          {...messageActions}>
          {message}
        </Text>
      </View>
      {children === undefined ? null : (
        <View style={styles.noticeActions}>{children}</View>
      )}
    </View>
  );
}

// A push button: the accent fill carries the view's main action, the quiet fill the rest. The
// compact size is the 28pt pill of the compose format bar and banners inside a 44pt touch target.
export function Button({
  label,
  onPress,
  fill = 'quiet',
  size = 'regular',
  disabled = false,
  destructive = false,
  accessibilityLabel,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly fill?: 'accent' | 'quiet';
  readonly size?: 'regular' | 'compact';
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityLabel?: string;
}) {
  const colors = usePalette();
  const primary = fill === 'accent';
  const compact = size === 'compact';
  const idle = primary ? colors.accentFill : colors.fillQuiet;
  let color = primary ? colors.accentOnFill : colors.textPrimary;
  if (destructive) {
    color = colors.statusDestructive;
  }
  let labelStyle = primary ? textStyles.headline : textStyles.body;
  if (compact) {
    labelStyle = textStyles.subheadline;
  }
  const fillOf = (pressed: boolean) => ({
    backgroundColor: pressed && !primary ? colors.accentSelectionSubtle : idle,
  });
  const text = <Text style={[labelStyle, { color }]}>{label}</Text>;
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      focusable
      onPress={onPress}
      style={({ pressed }) => [
        compact ? styles.buttonTarget : [styles.button, fillOf(pressed)],
        { opacity: disabled ? 0.5 : 1 },
      ]}>
      {({ pressed }) =>
        compact ? (
          <View style={[styles.buttonFill, fillOf(pressed)]}>{text}</View>
        ) : (
          text
        )
      }
    </Pressable>
  );
}

// The existing disclosure stays beside unaccepted assistance output and disappears with it.
export function OnDeviceMarker({ label }: { readonly label: string }) {
  const colors = usePalette();
  return (
    <View
      accessible
      accessibilityLabel={label}
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
