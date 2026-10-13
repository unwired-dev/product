import type { ReactNode } from 'react';
import type { ColorValue, ViewProps } from 'react-native';

import { radius, spacing, typography } from '@private-email/mail-core/theme';
import {
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

const NativeGlass = requireNativeComponent<
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
