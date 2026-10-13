import type { ReactNode } from 'react';
import type { ColorValue, StyleProp, ViewProps, ViewStyle } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import {
  Pressable,
  requireNativeComponent,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Label } from './label.tsx';
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

// Toolbar buttons are 28pt; the group adds a 4pt inset and takes half its height.
const groupRadius = (28 + 2 * spacing.xs) / 2;

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
    <View style={[styles.group, { boxShadow: colors.smallGlassShadow }, style]}>
      <NativeGlass
        cornerRadius={
          typeof cornerRadius === 'number' ? cornerRadius : groupRadius
        }
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
          selected ? textStyles.bodyEmphasized : textStyles.body,
          { flexShrink: 1 },
          { color: selected ? colors.accentOnFill : colors.textPrimary },
        ]}>
        {label}
      </Text>
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
        <View style={styles.noticeMessageText}>
          <Label style={[textStyles.body, { color: colors.textPrimary }]}>
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
