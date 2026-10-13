import type { ReactNode } from 'react';
import type { ColorValue, ViewProps } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
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

const NativeGlass = requireNativeComponent<
  ViewProps & { readonly cornerRadius: number }
>('UnwiredGlass');

export function Glass({
  cornerRadius,
  style,
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
    <View
      style={[
        styles.group,
        {
          boxShadow: colors.smallGlassShadow,
          backgroundColor: colors.surfaceContent,
        },
      ]}>
      <Glass
        cornerRadius={groupRadius}
        style={StyleSheet.absoluteFill}
      />
      {children}
    </View>
  );
}

// Menus float independently of their toolbar, with the deeper menu shadow.
export function GlassPanel({ children }: { readonly children: ReactNode }) {
  const colors = usePalette();
  return (
    <View
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
    </View>
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
  readonly onPress: () => void;
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
