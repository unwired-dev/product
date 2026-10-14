import type { ReactNode } from 'react';
import type { ColorValue, ViewProps } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import {
  Pressable,
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

export const NativeGlass = requireNativeComponent<
  ViewProps & { readonly cornerRadius: number }
>('UnwiredGlass');

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
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    minHeight: 28,
    maxWidth: '100%',
    paddingLeft: 10,
    paddingRight: spacing.m,
    borderRadius: radius.chip,
    borderCurve: 'continuous',
  },
  chipTarget: { minHeight: 44, maxWidth: '100%', justifyContent: 'center' },
  button: { minHeight: 44, justifyContent: 'center' },
  buttonFill: {
    minHeight: 28,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  // Matches the format bar's Text style pop-up, as in the touch compose frames.
  buttonLabelPrimary: { ...textStyles.subheadline, fontWeight: '600' },
  toolbarButton: {
    width: 44,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
  },
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
  noticeText: { ...textStyles.subheadline, flex: 1 },
  noticeActions: { paddingLeft: 16 + spacing.s },
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
export function GlassGroup({ children }: { readonly children: ReactNode }) {
  const colors = usePalette();
  return (
    <View style={[styles.group, { boxShadow: colors.smallGlassShadow }]}>
      <NativeGlass
        cornerRadius={groupRadius}
        style={StyleSheet.absoluteFill}
      />
      {children}
    </View>
  );
}

// A selectable filter: the icon and label together carry its meaning.
export function Chip({
  label,
  icon,
  selected,
  onPress,
}: {
  readonly label: string;
  readonly icon: string;
  readonly selected: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={onPress}
      style={styles.chipTarget}>
      <View
        style={[
          styles.chip,
          { backgroundColor: selected ? colors.accentFill : colors.fillQuiet },
        ]}>
        <SFSymbol
          name={icon}
          color={selected ? colors.accentOnFill : colors.textSecondary}
        />
        <Text
          style={[
            textStyles.subheadline,
            { flexShrink: 1 },
            selected && { fontWeight: '600' },
            { color: selected ? colors.accentOnFill : colors.textPrimary },
          ]}>
          {label}
        </Text>
      </View>
    </Pressable>
  );
}

// A banner beside the content it explains, with its actions stacked under the message.
export function Notice({
  icon,
  message,
  children,
}: {
  readonly icon: string;
  readonly message: string;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.notice, { backgroundColor: colors.fillQuiet }]}>
      <View style={styles.noticeMessage}>
        <SFSymbol
          name={icon}
          color={colors.textSecondary}
        />
        <Text style={[styles.noticeText, { color: colors.textPrimary }]}>
          {message}
        </Text>
      </View>
      {children === undefined ? null : (
        <View style={styles.noticeActions}>{children}</View>
      )}
    </View>
  );
}

// A push button, 28pt tall: Primary (graphite) carries the view's main action, Secondary the rest.
export function Button({
  label,
  onPress,
  variant = 'secondary',
  disabled = false,
  destructive = false,
  accessibilityLabel,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly variant?: 'primary' | 'secondary';
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityLabel?: string;
}) {
  const colors = usePalette();
  const primary = variant === 'primary';
  let color = primary ? colors.accentOnFill : colors.textPrimary;
  if (destructive) {
    color = colors.statusDestructive;
  }
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[styles.button, { opacity: disabled ? 0.5 : 1 }]}>
      <View
        style={[
          styles.buttonFill,
          { backgroundColor: primary ? colors.accentFill : colors.fillQuiet },
        ]}>
        <Text
          style={[
            primary ? styles.buttonLabelPrimary : textStyles.subheadline,
            { color },
          ]}>
          {label}
        </Text>
      </View>
    </Pressable>
  );
}

// An icon-only toolbar button; the label names it for accessibility.
export function ToolbarButton({
  icon,
  label,
  onPress,
  disabled = false,
  selected = false,
  destructive = false,
  accessibilityHint,
}: {
  readonly icon: string;
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
  readonly selected?: boolean;
  readonly destructive?: boolean;
  readonly accessibilityHint?: string;
}) {
  const colors = usePalette();
  let color = destructive ? colors.statusDestructive : colors.textPrimary;
  if (disabled) {
    color = colors.textSecondary;
  }
  return (
    <Pressable
      accessibilityHint={accessibilityHint}
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.toolbarButton,
        {
          backgroundColor: selected
            ? colors.accentSelectionSubtle
            : 'transparent',
          borderWidth: selected ? 2 : 0,
          borderColor: colors.accentInk,
        },
      ]}>
      <SFSymbol
        name={icon}
        color={color}
      />
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
