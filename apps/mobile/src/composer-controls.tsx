import type {
  BlockKind,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactNode } from 'react';
import type { StyleProp, TextStyle } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import {
  Animated,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Glass, SFSymbol, ToolbarButton, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  formatBar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.s,
    paddingVertical: spacing.xs,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  formatRail: { flex: 1 },
  formatRailContent: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    flexGrow: 1,
  },
  divider: { width: StyleSheet.hairlineWidth, height: 16, marginHorizontal: 2 },
  // Keeps an open menu above the content that follows it.
  menuAnchor: { zIndex: 1 },
  popUp: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    minHeight: 44,
    paddingLeft: spacing.m,
    paddingRight: 10,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  iconPopUp: {
    width: 44,
    justifyContent: 'center',
    paddingLeft: 0,
    paddingRight: 0,
  },
  menuTrailing: { left: 'auto', right: 0 },
  popUpText: { ...textStyles.subheadline, flexShrink: 1 },
  menu: {
    position: 'absolute',
    left: 0,
    minWidth: 240,
    padding: 6,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
  },
  menuBelow: { top: '100%', marginTop: spacing.xs },
  menuAbove: { bottom: '100%', marginBottom: spacing.xs },
  menuItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
  },
  menuItemText: { ...textStyles.body, flex: 1 },
});

type MarkName = `drafts.marks.${Mark}`;
type BlockName = `drafts.blocks.${Exclude<BlockKind, 'paragraph'>}`;
export const markControls: ReadonlyArray<
  readonly [Mark, string, MarkName, StyleProp<TextStyle>]
> = [
  ['bold', 'B', 'drafts.marks.bold', { fontWeight: '700' }],
  ['italic', 'I', 'drafts.marks.italic', { fontStyle: 'italic' }],
  [
    'underline',
    'U',
    'drafts.marks.underline',
    { textDecorationLine: 'underline' },
  ],
  [
    'strikethrough',
    'S',
    'drafts.marks.strikethrough',
    { textDecorationLine: 'line-through' },
  ],
  ['code', '</>', 'drafts.marks.code', { fontFamily: 'Menlo' }],
];

export const blockControls: ReadonlyArray<
  readonly [BlockKind, string, BlockName]
> = [
  ['heading1', 'H1', 'drafts.blocks.heading1'],
  ['heading2', 'H2', 'drafts.blocks.heading2'],
  ['heading3', 'H3', 'drafts.blocks.heading3'],
  ['bulleted', '•', 'drafts.blocks.bulleted'],
  ['numbered', '1.', 'drafts.blocks.numbered'],
  ['quote', '❝', 'drafts.blocks.quote'],
  ['code', '{ }', 'drafts.blocks.code'],
];

// The format bar's SF Symbols for each mark, and the block kinds its Text Style menu offers.
const markIcons: Readonly<Record<Mark, string>> = {
  bold: 'bold',
  italic: 'italic',
  underline: 'underline',
  strikethrough: 'strikethrough',
  code: 'chevron.left.forwardslash.chevron.right',
};
const blockNames = {
  paragraph: 'drafts.blocks.body',
  heading1: 'drafts.blocks.heading1',
  heading2: 'drafts.blocks.heading2',
  heading3: 'drafts.blocks.heading3',
  bulleted: 'drafts.blocks.bulleted',
  numbered: 'drafts.blocks.numbered',
  quote: 'drafts.blocks.quote',
  code: 'drafts.blocks.code',
} as const satisfies Record<BlockKind, string>;
const textStyleKinds: readonly BlockKind[] = [
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'quote',
  'code',
];

// A pop-up control whose menu opens in flow beside it; the menu lists its children.
// shortcut: the menu closes only from its control or an item, not from a tap elsewhere;
// replace with a native menu once the hosts expose one.
export function PopUp({
  label,
  accessibilityLabel,
  icon,
  prefix,
  quiet = false,
  disabled = false,
  selected = false,
  above = false,
  open,
  onToggle,
  children,
}: {
  readonly label?: string;
  readonly accessibilityLabel: string;
  readonly icon?: string;
  readonly prefix?: string;
  readonly quiet?: boolean;
  readonly disabled?: boolean;
  // Whether the shown choice is in effect, as a chosen sender is and a retained one is not.
  readonly selected?: boolean;
  readonly above?: boolean;
  readonly open: boolean;
  readonly onToggle: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const motion = useMenuMotion(open, 'menu');
  return (
    <View style={styles.menuAnchor}>
      <Pressable
        accessibilityLabel={accessibilityLabel}
        accessibilityRole="button"
        accessibilityState={{ expanded: open, disabled, selected }}
        disabled={disabled}
        onPress={onToggle}
        style={[
          styles.popUp,
          label === undefined ? styles.iconPopUp : null,
          { backgroundColor: quiet ? colors.fillQuiet : 'transparent' },
        ]}>
        {icon === undefined ? null : (
          <SFSymbol
            name={icon}
            color={colors.textPrimary}
          />
        )}
        {prefix === undefined ? null : (
          <Text style={[styles.popUpText, { color: colors.textSecondary }]}>
            {prefix}
          </Text>
        )}
        {label === undefined ? null : (
          <>
            <Text
              numberOfLines={1}
              style={[styles.popUpText, { color: colors.textPrimary }]}>
              {label}
            </Text>
            <SFSymbol
              name="chevron.up.chevron.down"
              size={12}
              color={colors.textSecondary}
            />
          </>
        )}
      </Pressable>
      {motion.shown ? (
        <Animated.View
          accessibilityRole="menu"
          // A closing menu leaves VoiceOver and touch at once; only its picture fades.
          accessibilityElementsHidden={!open}
          pointerEvents={open ? 'auto' : 'none'}
          style={[
            motion.style,
            styles.menu,
            label === undefined ? styles.menuTrailing : null,
            above ? styles.menuAbove : styles.menuBelow,
            {
              backgroundColor: colors.surfaceContent,
              borderColor: colors.separator,
              boxShadow: colors.menuShadow,
              transformOrigin: `${above ? 'bottom' : 'top'} ${label === undefined ? 'right' : 'left'}`,
            },
          ]}>
          <Glass cornerRadius={radius.card} />
          {children}
        </Animated.View>
      ) : null}
    </View>
  );
}

export function MenuItem({
  label,
  accessibilityLabel,
  selected,
  disabled = false,
  destructive = false,
  onPress,
}: {
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly selected: boolean;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.menuItem,
        {
          backgroundColor: selected
            ? colors.accentSelectionSubtle
            : 'transparent',
        },
      ]}>
      <Text
        numberOfLines={1}
        style={[
          styles.menuItemText,
          {
            color: destructive ? colors.statusDestructive : colors.textPrimary,
          },
        ]}>
        {label}
      </Text>
      {selected ? (
        <SFSymbol
          name="checkmark"
          size={12}
          color={colors.textPrimary}
        />
      ) : null}
    </Pressable>
  );
}

// Presentation owns the menu; the editor supplies semantic commands and composes its other actions.
export function ComposerActions({
  disabled,
  onDiscard,
}: {
  readonly disabled: boolean;
  readonly onDiscard: () => void;
}) {
  const { t } = useLocalization();
  const [open, setOpen] = useState(false);
  return (
    <PopUp
      accessibilityLabel={t('drafts.actions')}
      icon="ellipsis"
      disabled={disabled}
      open={open}
      onToggle={() => {
        setOpen((current) => !current);
      }}>
      <MenuItem
        destructive
        disabled={disabled}
        label={t('drafts.discard')}
        selected={false}
        onPress={() => {
          setOpen(false);
          onDiscard();
        }}
      />
    </PopUp>
  );
}

export function FormatBar({
  active,
  kind,
  disabled,
  above = false,
  onBlock,
  onMark,
  children,
}: {
  readonly active: readonly Mark[];
  readonly kind: BlockKind;
  readonly disabled: boolean;
  readonly above?: boolean;
  readonly onBlock: (kind: BlockKind) => void;
  readonly onMark: (mark: Mark) => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [styleMenu, setStyleMenu] = useState(false);
  return (
    <View
      accessibilityLabel={t('drafts.formatting')}
      accessibilityRole="toolbar"
      style={[styles.formatBar, { borderColor: colors.separator }]}>
      <PopUp
        above={above}
        accessibilityLabel={t('drafts.textStyle')}
        disabled={disabled}
        icon="textformat"
        label={t(blockNames[kind])}
        open={styleMenu}
        onToggle={() => {
          setStyleMenu((current) => !current);
        }}>
        {textStyleKinds.map((value) => (
          <MenuItem
            key={value}
            disabled={disabled}
            label={t(blockNames[value])}
            selected={kind === value}
            onPress={() => {
              setStyleMenu(false);
              onBlock(value);
            }}
          />
        ))}
      </PopUp>
      <ScrollView
        horizontal
        keyboardShouldPersistTaps="always"
        style={styles.formatRail}
        contentContainerStyle={styles.formatRailContent}>
        <View style={[styles.divider, { backgroundColor: colors.separator }]} />
        {markControls.map(([mark, , name]) => (
          <ToolbarButton
            key={mark}
            disabled={disabled}
            icon={markIcons[mark]}
            label={t(name)}
            selected={active.includes(mark)}
            onPress={() => {
              onMark(mark);
            }}
          />
        ))}
        <View style={[styles.divider, { backgroundColor: colors.separator }]} />
        <ToolbarButton
          disabled={disabled}
          icon="list.bullet"
          label={t('drafts.blocks.bulleted')}
          selected={kind === 'bulleted'}
          onPress={() => {
            onBlock('bulleted');
          }}
        />
        <ToolbarButton
          disabled={disabled}
          icon="list.number"
          label={t('drafts.blocks.numbered')}
          selected={kind === 'numbered'}
          onPress={() => {
            onBlock('numbered');
          }}
        />
        {children}
      </ScrollView>
    </View>
  );
}
