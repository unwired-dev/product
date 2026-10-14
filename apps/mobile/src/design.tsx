import type { ReactNode } from 'react';
import type {
  ColorValue,
  GestureResponderEvent,
  StyleProp,
  ViewProps,
  ViewStyle,
} from 'react-native';

import { radius, spacing, typography } from '@private-email/mail-core/theme';
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
  useWindowDimensions,
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

const NativeGlass = requireNativeComponent<
  ViewProps & { readonly cornerRadius: number }
>('UnwiredGlass');

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

const easeOut = Easing.bezier(0.23, 1, 0.32, 1);
const easeSheet = Easing.bezier(0.32, 0.72, 0, 1);

// Keep the presentation mounted until its exit finishes, but hide closing controls immediately.
export function useMenuMotion(open: boolean, kind: 'menu' | 'reply' | 'sheet') {
  const [shown, setShown] = useState(open);
  const progress = useMemo(() => new Animated.Value(0), []);
  const [reduced, setReduced] = useState(true);
  const { height } = useWindowDimensions();
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
  const initialScale = kind === 'reply' ? 0.3 : 0.95;
  const transform =
    kind === 'sheet'
      ? [
          {
            translateY: progress.interpolate({
              inputRange: [0, 1],
              outputRange: [height, 0],
            }),
          },
        ]
      : [
          {
            scale: progress.interpolate({
              inputRange: [0, 1],
              outputRange: [initialScale, 1],
            }),
          },
        ];
  const style = {
    opacity:
      kind === 'reply'
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
const compact = Platform.OS === 'ios' && !Platform.isPad;

// Toolbar buttons are 44pt for touch; the group adds a 4pt inset and takes half its height.
const groupRadius = (44 + 2 * spacing.xs) / 2;

const styles = StyleSheet.create({
  group: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    flexWrap: 'wrap',
    padding: spacing.xs,
    borderRadius: groupRadius,
  },
  panel: { borderRadius: radius.menu, maxWidth: '100%' },
  toolbarButton: {
    minWidth: 44,
    minHeight: 44,
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

// Menus float independently of their toolbar, with the deeper menu shadow.
export function GlassPanel({
  open,
  children,
}: {
  readonly open: boolean;
  readonly children: ReactNode;
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
        motion.style,
        {
          boxShadow: colors.menuGlassShadow,
          backgroundColor: colors.surfaceContent,
          transformOrigin: compact ? 'bottom' : 'top right',
        },
      ]}>
      <Glass
        cornerRadius={radius.menu}
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
}: {
  readonly label: string;
  readonly icon: string;
  readonly onPress: (event: GestureResponderEvent) => void;
  readonly disabled?: boolean;
  // A control that reveals a panel reports whether the panel is open.
  readonly expanded?: boolean;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{
        disabled,
        ...(expanded === undefined ? {} : { expanded }),
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
            pressed || expanded === true
              ? colors.accentSelectionSubtle
              : 'transparent',
          borderWidth: 2,
          borderColor: focused ? colors.accentInk : 'transparent',
          opacity: disabled ? 0.4 : 1,
        },
      ]}>
      <SFSymbol
        name={icon}
        size={20}
        color={colors.textPrimary}
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

// A banner beside the content it explains, with its actions stacked under the message. A warning
// tints its icon; the message is an alert when it reports a failure.
export function Notice({
  icon,
  iconColor,
  message,
  messageRole,
  announce,
  children,
}: {
  readonly icon: string;
  readonly iconColor?: ColorValue;
  readonly message: string;
  readonly messageRole?: 'alert';
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
          style={[styles.noticeText, { color: colors.textPrimary }]}>
          {message}
        </Text>
      </View>
      {children === undefined ? null : (
        <View style={styles.noticeActions}>{children}</View>
      )}
    </View>
  );
}

// A push button: the primary one carries the accent fill, others the quiet fill.
export function Button({
  label,
  onPress,
  fill = 'quiet',
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly fill?: 'accent' | 'quiet';
}) {
  const colors = usePalette();
  const primary = fill === 'accent';
  const idle = primary ? colors.accentFill : colors.fillQuiet;
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      focusable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          backgroundColor:
            pressed && !primary ? colors.accentSelectionSubtle : idle,
        },
      ]}>
      <Text
        style={[
          primary ? textStyles.headline : textStyles.body,
          { color: primary ? colors.accentOnFill : colors.textPrimary },
        ]}>
        {label}
      </Text>
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
