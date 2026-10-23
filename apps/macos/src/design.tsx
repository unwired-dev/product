import type {
  MenuSection,
  NativeMenuItem,
} from '@private-email/mail-core/context-menu';
import type { ComponentProps, ReactNode } from 'react';
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
  View,
} from 'react-native';

import { Label } from './label.tsx';
import { isMenuChoice } from './native-menu.ts';
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
  panel: { borderRadius: radius.menu, maxWidth: '100%' },
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
    minHeight: 28,
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
  const anchor = useRef<View>(null);
  const latest = useRef(menuState(sections));
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
    const chosen = await TurboModuleRegistry.getEnforcing<NativeMenu>(
      'UnwiredMenu',
    ).show(
      tag,
      latest.current.sections,
      processColor(colors.statusDestructive),
    );
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
      focusable
      onPress={() => {
        void show();
      }}
      style={style}>
      {children}
    </Pressable>
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

const AnimatedPanel = Animated.createAnimatedComponent(ModalBackground);

const easeOut = Easing.bezier(0.23, 1, 0.32, 1);

// A menu that eases out of its control and fades away once closed. Closing hides it from
// VoiceOver and the pointer at once; Reduce Motion keeps only the fade.
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
  const [shown, setShown] = useState(open);
  const progress = useMemo(() => new Animated.Value(0), []);
  const [reduced, setReduced] = useState(true);
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
  if (!shown) {
    return null;
  }
  return (
    <AnimatedPanel
      {...props}
      accessibilityElementsHidden={!open}
      pointerEvents={open ? 'auto' : 'none'}
      style={[
        style,
        {
          opacity: progress,
          transformOrigin: origin,
          transform: reduced
            ? []
            : [
                {
                  scale: progress.interpolate({
                    inputRange: [0, 1],
                    outputRange: [0.95, 1],
                  }),
                },
              ],
        },
      ]}>
      {children}
    </AnimatedPanel>
  );
}

// Menus float independently of their toolbar, with the deeper menu shadow.
export function GlassPanel({
  open,
  children,
  origin = 'top right',
}: {
  readonly open: boolean;
  readonly children: ReactNode;
  // Where the panel grows from: the control or window edge that opened it.
  readonly origin?: string;
}) {
  const colors = usePalette();
  return (
    <MenuPresence
      open={open}
      origin={origin}
      style={[
        styles.panel,
        {
          boxShadow: colors.menuGlassShadow,
          backgroundColor: colors.surfaceContent,
        },
      ]}>
      <Glass
        cornerRadius={radius.menu}
        style={StyleSheet.absoluteFill}
      />
      {children}
    </MenuPresence>
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
  readonly onPress: () => void;
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

// A push button, 28pt tall: the accent fill carries the view's main action, the quiet fill the rest.
export function Button({
  label,
  onPress,
  fill = 'quiet',
  disabled = false,
  destructive = false,
  accessibilityLabel,
  ref,
  onFocus,
  onBlur,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly fill?: 'accent' | 'quiet';
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityLabel?: string;
} & Pick<ComponentProps<typeof Pressable>, 'ref' | 'onFocus' | 'onBlur'>) {
  const colors = usePalette();
  const primary = fill === 'accent';
  const idle = primary ? colors.accentFill : colors.fillQuiet;
  let color = primary ? colors.accentOnFill : colors.textPrimary;
  if (destructive) {
    color = colors.statusDestructive;
  }
  return (
    <Pressable
      ref={ref}
      onFocus={onFocus}
      onBlur={onBlur}
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      focusable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          backgroundColor:
            pressed && !primary ? colors.accentSelectionSubtle : idle,
          opacity: disabled ? 0.5 : 1,
        },
      ]}>
      <Text
        style={[
          primary ? textStyles.bodyEmphasized : textStyles.body,
          { color },
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
