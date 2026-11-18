import type { MenuSection } from '@private-email/mail-core/context-menu';
import type {
  BlockKind,
  Link,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactElement, ReactNode, RefObject } from 'react';
import type {
  Insets,
  StyleProp,
  TextInputInstance,
  TextStyle,
  ViewStyle,
} from 'react-native';

import {
  BottomSheet,
  Group,
  Host,
  HStack,
  Popover,
  RNHostView,
  Spacer,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  contentShape,
  controlSize,
  accessibilityLabel as spokenLabel,
  disabled as inactive,
  font,
  foregroundStyle,
  frame,
  labelStyle,
  onAppear,
  padding,
  presentationDetents,
  shapes,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { canGenerate } from '@private-email/mail-core/assistance';
import { vettedHref } from '@private-email/mail-core/link-inspection';
import { isLinkText } from '@private-email/mail-core/semantic-document';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  Keyboard,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import {
  GlassPanel,
  MenuButton,
  ScaledToolbar,
  scaledToolbar,
  SFSymbol,
  ToolbarButton,
  useOutcomeAnnouncement,
} from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailAssistanceLifetime } from './mail-assistance-lifetime.ts';
import { textStyles, useLargeText, usePalette } from './theme.ts';

const phone = Platform.OS === 'ios' && !Platform.isPad;
// iPad's rules are the Mac recipe's point at 1.15×, as its frames draw them.
const rule = phone ? StyleSheet.hairlineWidth : ipadListScale;
// The From pop-up shows a 33.6pt capsule on iPhone and a 32.2pt one on iPad within its 44pt
// target, as the Compose frames draw it.
const quietHeight = phone ? 33.6 : 28 * ipadListScale;
const quietSlop = (44 - quietHeight) / 2;
// The Format panel's 40pt style choices reach 44pt through the row's 4pt inset.
const formatStyleSlop = { top: 2, bottom: 2 };
// The frames show every format bar section in full from 522pt, as the 531pt landscape inline
// composer does; the 442pt portrait one folds them.
const fullFormatBar = 522;
const overflowSlop = {
  left: (44 - scaledToolbar.width) / 2,
  right: (44 - scaledToolbar.width) / 2,
};

const styles = StyleSheet.create({
  // iPad draws the Mac Link Editor popover at the iPad list scale.
  linkPopover: {
    width: 340 * ipadListScale,
    gap: 10 * ipadListScale,
    padding: 14 * ipadListScale,
  },
  linkField: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s * ipadListScale,
  },
  linkLabel: { ...typography.ipadList.body, width: 36 * ipadListScale },
  linkInput: {
    ...typography.ipadList.body,
    flex: 1,
    height: 26 * ipadListScale,
    paddingHorizontal: spacing.s * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  linkPopoverHint: typography.ipadList.subheadline,
  linkActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
  },
  linkSheet: { gap: 14, padding: spacing.l, paddingTop: 10 },
  linkSheetHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  linkSheetTitle: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  linkGroup: { borderRadius: radius.insetGroup, borderCurve: 'continuous' },
  linkRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 48,
    paddingHorizontal: spacing.l,
  },
  linkRowLabel: { ...textStyles.body, width: 48 },
  linkRowInput: { ...textStyles.body, flex: 1, padding: 0 },
  linkSeparator: { height: StyleSheet.hairlineWidth, marginLeft: spacing.l },
  linkSheetHint: { ...textStyles.footnote, paddingHorizontal: spacing.l },
  // The "Generate a Draft" frames' insets.
  generate: {
    gap: spacing.m,
    paddingHorizontal: spacing.l,
    paddingVertical: 14,
  },
  // iPad draws the "Generate a Draft" popover at the frame's width.
  generatePopover: { width: 420 },
  generateHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  generateTitle: { ...textStyles.headline, flex: 1 },
  generatePrompt: { ...textStyles.subheadline, minHeight: 44, padding: 0 },
  generateActions: { flexDirection: 'row', justifyContent: 'flex-end' },
  // The iPad frames' Mac recipe at 1.15: Text style 18.4pt from the leading edge and the scaled
  // toolbar's 36.8pt glyph boxes 18.4pt from the trailing one, 41.4pt apart, each keeping its 44pt
  // target. The bar is 43.7pt with its rules; a docked reply's is 41.4pt. Its 44pt controls
  // overhang it, above the body beneath, so the rules don't clip their targets.
  formatBar: {
    zIndex: 1,
    height: 38 * ipadListScale,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.l * ipadListScale,
    borderTopWidth: rule,
    borderBottomWidth: rule,
  },
  formatRail: { flex: 1 },
  formatTarget: { height: 44 },
  formatRailContent: {
    flexDirection: 'row',
    alignItems: 'center',
    flexGrow: 1,
    gap: spacing.xs * ipadListScale,
  },
  // The narrow bar's frame sets its buttons side by side.
  narrowRail: { gap: 0 },
  overflow: {
    width: scaledToolbar.width,
    minHeight: 44,
    alignItems: 'center',
  },
  // 18.4pt tall, 4.6pt from the glyph boxes beside it.
  divider: {
    width: rule,
    height: 16 * ipadListScale,
  },
  // The Text style pull-down's label: its symbol, the style and the pop-up chevrons.
  textStyle: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6 * ipadListScale,
    minHeight: 44,
    paddingLeft: spacing.s * ipadListScale,
    paddingRight: 6 * ipadListScale,
  },
  formatPanel: { margin: spacing.s, marginTop: 0 },
  formatContent: { padding: spacing.l, gap: spacing.m },
  formatHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
  },
  formatTitle: { ...textStyles.title3Emphasized, flex: 1 },
  formatClose: { borderRadius: radius.insetGroup },
  formatRow: {
    flexDirection: 'row',
    gap: spacing.s,
  },
  // The frames' 40pt style choices, 2pt apart within the row's 4pt inset.
  formatStyles: {
    flexDirection: 'row',
    gap: 2,
    padding: spacing.xs,
    borderRadius: radius.insetGroup,
  },
  formatStyle: { minHeight: 40, borderRadius: 18 },
  formatGroup: {
    flex: 1,
    flexDirection: 'row',
    borderRadius: radius.insetGroup,
    overflow: 'hidden',
  },
  formatGlyph: { fontSize: 17, lineHeight: 20 },
  formatChoice: {
    flex: 1,
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.insetGroup - spacing.xs,
  },
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
  quietPopUp: { minHeight: quietHeight, marginVertical: quietSlop },
  phoneQuietPopUp: { borderRadius: 7.2 },
  iconPopUp: {
    width: 44,
    justifyContent: 'center',
    paddingLeft: 0,
    paddingRight: 0,
  },
  // The pop-up stays within its row: at the accessibility text sizes its choice wraps beside a
  // whole prefix.
  popUpButton: { flexShrink: 1, maxWidth: '100%' },
  popUpText: { ...textStyles.subheadline, flexShrink: 1 },
  popUpPrefix: { flexShrink: 0 },
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

export const kindStyles: Record<BlockKind, TextStyle> = {
  paragraph: {},
  heading1: { fontSize: 26, lineHeight: 34, fontWeight: '700' },
  heading2: { fontSize: 22, lineHeight: 30, fontWeight: '700' },
  heading3: { fontSize: 19, lineHeight: 28, fontWeight: '600' },
  bulleted: {},
  numbered: {},
  quote: { fontStyle: 'italic' },
  code: { fontFamily: 'Menlo' },
};

const decorations = {
  underline: 'underline',
  strikethrough: 'line-through',
  both: 'underline line-through',
} as const;

// Linked text shows underlined, as the Link Editor frames draw it.
export const markStyle = (
  marks: readonly Mark[] = [],
  linked = false,
): TextStyle => {
  const underline = linked || marks.includes('underline');
  const strikethrough = marks.includes('strikethrough');
  let decoration: (typeof decorations)[keyof typeof decorations] | undefined =
    undefined;
  if (underline && strikethrough) {
    decoration = decorations.both;
  } else if (underline) {
    decoration = decorations.underline;
  } else if (strikethrough) {
    decoration = decorations.strikethrough;
  }
  return {
    ...(marks.includes('bold') ? { fontWeight: '700' } : {}),
    ...(marks.includes('italic') ? { fontStyle: 'italic' } : {}),
    ...(marks.includes('code') ? { fontFamily: 'Menlo' } : {}),
    ...(decoration === undefined ? {} : { textDecorationLine: decoration }),
  };
};

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
export const markIcons: Readonly<Record<Mark, string>> = {
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
// The iPhone Format panel's rows: text styles, marks, then lists, quotes and code blocks. Its text
// styles name the heading levels by their role, each shown in its own type.
const headings = [
  [
    'heading1',
    'drafts.formatStyles.title',
    { fontSize: 19, fontWeight: '700' },
  ],
  [
    'heading2',
    'drafts.formatStyles.heading',
    { fontSize: 16, fontWeight: '600' },
  ],
  [
    'heading3',
    'drafts.formatStyles.subheading',
    { fontSize: 13, fontWeight: '600' },
  ],
  ['paragraph', 'drafts.blocks.body', { fontSize: 15 }],
] as const;
const markGroups = {
  marks: markControls.slice(0, 4),
  code: markControls.slice(4),
};
const blockGroups = {
  lists: blockControls.slice(3, 5),
  text: blockControls.slice(5),
};

// A pop-up button whose system menu opens on tap and lists its items.
export function PopUp({
  label,
  accessibilityLabel,
  icon,
  prefix,
  quiet = false,
  disabled = false,
  selected = false,
  items,
}: {
  readonly label?: string;
  readonly accessibilityLabel: string;
  readonly icon?: string;
  readonly prefix?: string;
  readonly quiet?: boolean;
  readonly disabled?: boolean;
  // Whether the shown choice is in effect, as a chosen sender is and a retained one is not.
  readonly selected?: boolean;
  readonly items: MenuSection['items'];
}) {
  const colors = usePalette();
  const large = useLargeText();
  return (
    <MenuButton
      accessibilityLabel={accessibilityLabel}
      accessibilityState={{ selected }}
      disabled={disabled}
      sections={[{ items }]}
      style={styles.popUpButton}>
      <View
        style={[
          styles.popUp,
          quiet && styles.quietPopUp,
          phone && quiet && styles.phoneQuietPopUp,
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
          <Text
            style={[
              styles.popUpText,
              styles.popUpPrefix,
              { color: colors.textSecondary },
            ]}>
            {prefix}
          </Text>
        )}
        {label === undefined ? null : (
          <>
            <Text
              numberOfLines={large ? undefined : 1}
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
      </View>
    </MenuButton>
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
  return (
    <PopUp
      accessibilityLabel={t('drafts.actions')}
      icon="ellipsis"
      disabled={disabled}
      items={[
        {
          key: 'discard',
          title: t('drafts.discard'),
          symbol: 'trash',
          destructive: true,
          run: onDiscard,
        },
      ]}
    />
  );
}

// A format bar section's `ellipsis` menu, holding the items a narrow bar cannot show.
export function OverflowMenu({
  accessibilityLabel,
  disabled,
  sections,
}: {
  readonly accessibilityLabel: string;
  readonly disabled: boolean;
  readonly sections: readonly MenuSection[];
}) {
  const colors = usePalette();
  return (
    <MenuButton
      accessibilityLabel={accessibilityLabel}
      disabled={disabled}
      hitSlop={overflowSlop}
      sections={sections}
      style={styles.overflow}>
      <SFSymbol
        name="ellipsis"
        size={scaledToolbar.symbol}
        color={colors.textPrimary}
      />
    </MenuButton>
  );
}

// The iPad format bar. Narrower than the frames' full bar, each section that cannot show all its
// items ends with an overflow menu, and `children` receives the items the lists menu holds.
export function FormatBar({
  active,
  kind,
  disabled,
  onBlock,
  onMark,
  style,
  children,
}: {
  readonly active: readonly Mark[];
  readonly kind: BlockKind;
  readonly disabled: boolean;
  readonly onBlock: (kind: BlockKind) => void;
  readonly onMark: (mark: Mark) => void;
  readonly style?: StyleProp<ViewStyle>;
  readonly children: (lists: MenuSection['items'] | undefined) => ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [width, setWidth] = useState<number>();
  const narrow = width !== undefined && width < fullFormatBar;
  const numbered = {
    disabled,
    icon: 'list.number',
    label: t('drafts.blocks.numbered'),
    selected: kind === 'numbered',
    onPress: () => {
      onBlock('numbered');
    },
  };
  return (
    <View
      accessibilityLabel={t('drafts.formatting')}
      accessibilityRole="toolbar"
      onLayout={({ nativeEvent }) => {
        setWidth(nativeEvent.layout.width);
      }}
      style={[styles.formatBar, { borderColor: colors.separator }, style]}>
      {/* The system menu marks the current style with its leading checkmark. */}
      <MenuButton
        accessibilityLabel={t('drafts.textStyle')}
        disabled={disabled}
        style={styles.formatTarget}
        sections={[
          {
            items: textStyleKinds.map((value) => ({
              key: value,
              title: t(blockNames[value]),
              symbol: '',
              checked: kind === value,
              run: () => {
                onBlock(value);
              },
            })),
          },
        ]}>
        <View style={styles.textStyle}>
          <SFSymbol
            name="textformat"
            color={colors.textPrimary}
          />
          {/* The format bar keeps its size at every text size, as UIKit toolbars do. */}
          <Text
            maxFontSizeMultiplier={1}
            numberOfLines={1}
            style={[styles.popUpText, { color: colors.textPrimary }]}>
            {t(blockNames[kind])}
          </Text>
          <SFSymbol
            name="chevron.up.chevron.down"
            size={12}
            color={colors.textSecondary}
          />
        </View>
      </MenuButton>
      <ScrollView
        horizontal
        keyboardShouldPersistTaps="always"
        style={[styles.formatRail, styles.formatTarget]}
        contentContainerStyle={[
          styles.formatRailContent,
          narrow && styles.narrowRail,
        ]}>
        <ScaledToolbar value>
          <View
            style={[styles.divider, { backgroundColor: colors.separator }]}
          />
          {markControls
            .slice(0, narrow ? 2 : undefined)
            .map(([mark, , name]) => (
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
          {narrow ? (
            <OverflowMenu
              accessibilityLabel={t('drafts.moreFormatting')}
              disabled={disabled}
              sections={[
                {
                  items: markControls.slice(2).map(([mark, , name]) => ({
                    key: mark,
                    title: t(name),
                    symbol: markIcons[mark],
                    checked: active.includes(mark),
                    run: () => {
                      onMark(mark);
                    },
                  })),
                },
              ]}
            />
          ) : null}
          <View
            style={[styles.divider, { backgroundColor: colors.separator }]}
          />
          <ToolbarButton
            disabled={disabled}
            icon="list.bullet"
            label={t('drafts.blocks.bulleted')}
            selected={kind === 'bulleted'}
            onPress={() => {
              onBlock('bulleted');
            }}
          />
          {narrow ? null : <ToolbarButton {...numbered} />}
          {children(
            narrow
              ? [
                  {
                    key: 'numbered',
                    title: numbered.label,
                    symbol: numbered.icon,
                    checked: numbered.selected,
                    run: numbered.onPress,
                  },
                ]
              : undefined,
          )}
        </ScaledToolbar>
      </ScrollView>
    </View>
  );
}

// One choice in the Format panel, filled while it applies at the selection.
function FormatChoice({
  name,
  selected,
  disabled,
  onPress,
  style,
  hitSlop,
  children,
}: {
  readonly name: string;
  readonly selected: boolean;
  readonly disabled: boolean;
  readonly onPress: () => void;
  readonly style?: StyleProp<ViewStyle>;
  readonly hitSlop?: Insets;
  readonly children: (color: string) => ReactNode;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityLabel={name}
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      disabled={disabled}
      hitSlop={hitSlop}
      onPress={onPress}
      style={[
        styles.formatChoice,
        style,
        selected && { backgroundColor: colors.accentFill },
        disabled && { opacity: 0.4 },
      ]}>
      {children(selected ? colors.accentOnFill : colors.textPrimary)}
    </Pressable>
  );
}

// The iPhone Format panel, which replaces the keyboard: Undo and Redo, text styles, marks, the
// Link Editor and the remaining block kinds, as the format bar offers them.
export function FormatPanel({
  open,
  active,
  kind,
  link,
  linkEditor,
  undo,
  redo,
  disabled,
  onUndo,
  onRedo,
  onBlock,
  onMark,
  onLink,
  onClose,
  onHide,
}: {
  readonly open: boolean;
  readonly active: readonly Mark[];
  readonly kind: BlockKind;
  readonly link: Link | undefined;
  readonly linkEditor: LinkEditorState;
  // Whether there is an edit to undo or redo.
  readonly undo: boolean;
  readonly redo: boolean;
  readonly disabled: boolean;
  readonly onUndo: () => void;
  readonly onRedo: () => void;
  readonly onBlock: (kind: BlockKind) => void;
  readonly onMark: (mark: Mark) => void;
  readonly onLink: (link: Link, text: string, href?: string) => void;
  // Closes the panel and resumes typing; `onHide` only closes it.
  readonly onClose: () => void;
  readonly onHide: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  // Typing in the Link Editor shows the keyboard too, and its sheet lives in this panel.
  const linking = linkEditor.shown;
  // Tapping into the body again brings the keyboard back in place of the panel.
  useEffect(() => {
    if (!open || linking) {
      return;
    }
    const shown = Keyboard.addListener('keyboardWillShow', onHide);
    return () => {
      shown.remove();
    };
  }, [linking, onHide, open]);
  const insets = useSafeAreaInsets();
  const rowFill = { backgroundColor: colors.fillQuiet };
  return (
    <GlassPanel
      open={open}
      // The panel takes the keyboard's place, 8pt from the screen's bottom edge.
      style={[styles.formatPanel, { marginBottom: spacing.s - insets.bottom }]}
      cornerRadius={radius.formatPanel}>
      <View
        accessibilityLabel={t('drafts.formatting')}
        accessibilityRole="toolbar"
        style={styles.formatContent}>
        <View style={styles.formatHeader}>
          <Text
            accessibilityRole="header"
            style={[styles.formatTitle, { color: colors.textPrimary }]}>
            {t('drafts.format')}
          </Text>
          <ToolbarButton
            disabled={disabled || !undo}
            icon="arrow.uturn.backward"
            label={t('drafts.undo')}
            onPress={onUndo}
          />
          <ToolbarButton
            disabled={disabled || !redo}
            icon="arrow.clockwise"
            label={t('drafts.redo')}
            onPress={onRedo}
          />
          <View style={[styles.formatClose, rowFill]}>
            <ToolbarButton
              disabled={disabled}
              icon="xmark"
              label={t('drafts.closeFormat')}
              onPress={onClose}
            />
          </View>
        </View>
        <View style={[styles.formatStyles, rowFill]}>
          {headings.map(([value, label, type]) => {
            const name = t(label);
            return (
              <FormatChoice
                key={value}
                disabled={disabled}
                name={name}
                selected={kind === value}
                style={styles.formatStyle}
                hitSlop={formatStyleSlop}
                onPress={() => {
                  onBlock(value);
                }}>
                {(color) => (
                  <Text
                    numberOfLines={1}
                    style={[type, { color }]}>
                    {name}
                  </Text>
                )}
              </FormatChoice>
            );
          })}
        </View>
        <View style={styles.formatRow}>
          {Object.entries(markGroups).map(([key, group]) => (
            <View
              key={key}
              style={[styles.formatGroup, rowFill]}>
              {group.map(([mark, , name]) => (
                <FormatChoice
                  key={mark}
                  disabled={disabled}
                  name={t(name)}
                  selected={active.includes(mark)}
                  onPress={() => {
                    onMark(mark);
                  }}>
                  {(color) =>
                    mark === 'code' ? (
                      <Text style={[styles.formatGlyph, { color }]}>
                        {'</>'}
                      </Text>
                    ) : (
                      <SFSymbol
                        name={markIcons[mark]}
                        // The frame draws Bold's mark 13×16pt.
                        size={23}
                        color={color}
                      />
                    )
                  }
                </FormatChoice>
              ))}
              {/* The Link control follows Code, as in the iPhone Format frame. */}
              {key === 'code' ? (
                <View style={styles.formatChoice}>
                  <LinkEditor
                    state={linkEditor}
                    disabled={disabled}
                    link={link}
                    popover={false}
                    onChange={onLink}
                  />
                </View>
              ) : null}
            </View>
          ))}
        </View>
        <View style={styles.formatRow}>
          {/* Lists, quotes and code blocks follow the three headings. */}
          {Object.entries(blockGroups).map(([key, group]) => (
            <View
              key={key}
              style={[styles.formatGroup, rowFill]}>
              {group.map(([value, glyph, name]) => (
                <FormatChoice
                  key={value}
                  disabled={disabled}
                  name={t(name)}
                  selected={kind === value}
                  onPress={() => {
                    onBlock(value);
                  }}>
                  {(color) =>
                    value === 'bulleted' || value === 'numbered' ? (
                      <SFSymbol
                        name={
                          value === 'bulleted' ? 'list.bullet' : 'list.number'
                        }
                        // The frame draws the bulleted list 16×11pt.
                        size={16}
                        color={color}
                      />
                    ) : (
                      <Text style={[styles.formatGlyph, { color }]}>
                        {glyph}
                      </Text>
                    )
                  }
                </FormatChoice>
              ))}
            </View>
          ))}
        </View>
      </View>
    </GlassPanel>
  );
}

// The Link Editor's link and edits. The composer keeps them above its layouts, so a resize between
// the iPad popover and the iPhone sheet re-presents the editor as it was.
export function useLinkEditor() {
  const [editing, setEditing] = useState<Link>();
  const [shown, setShown] = useState(false);
  const [text, setText] = useState('');
  const [destination, setDestination] = useState('');
  // Whether to say why the destination cannot be applied, once Return or leaving Link checked it.
  const [checked, setChecked] = useState(false);
  return {
    editing,
    setEditing,
    shown,
    setShown,
    text,
    setText,
    destination,
    setDestination,
    checked,
    setChecked,
  };
}
export type LinkEditorState = ReturnType<typeof useLinkEditor>;

// The format bar's Link control and the Link Editor it opens for the link at the caret, or to
// add one to selected unlinked text: a popover below the control on iPad, a sheet on iPhone. It
// is unavailable otherwise. A `renderMenu` takes the control's place as one of its items, and the popover
// opens from that menu.
export function LinkEditor({
  state,
  link,
  disabled,
  popover,
  renderMenu,
  onChange,
}: {
  readonly state: LinkEditorState;
  readonly link: Link | undefined;
  readonly disabled: boolean;
  readonly popover: boolean;
  readonly renderMenu?: (item: MenuSection['items'][number]) => ReactElement;
  readonly onChange: (link: Link, text: string, href?: string) => void;
}) {
  const { t } = useLocalization();
  const {
    editing,
    setEditing,
    shown,
    setShown: show,
    text,
    setText,
    destination,
    setDestination,
    checked,
    setChecked,
  } = state;
  const destinationInput = useRef<TextInputInstance>(null);
  // An empty Link is the editor's starting state, not an invalid destination.
  const check = () => {
    setChecked(destination.trim() !== '');
  };
  const href = vettedHref(destination);
  const applicable = href !== undefined && isLinkText(text);
  const invalid = checked && destination.trim() !== '' && href === undefined;
  // VoiceOver hears the reason when it appears, since iOS ignores live regions and the alert role.
  useOutcomeAnnouncement(
    shown && invalid ? t('drafts.link.invalid') : undefined,
    false,
  );
  const finish = (next: string, nextHref?: string) => {
    show(false);
    if (editing !== undefined) {
      onChange(editing, next, nextHref);
    }
  };
  const apply = () => {
    check();
    if (applicable) {
      finish(text, href);
    }
  };
  const remove = () => {
    if (editing !== undefined) {
      finish(editing.text);
    }
  };
  const colors = usePalette();
  // Native presenters retain their content; layout is not a signal that it appeared again.
  const focusDestination = () => {
    if (shown && editing?.href === '') {
      destinationInput.current?.focus();
    }
  };
  // oxlint-disable-next-line react/refs, react-hooks-js/refs -- Expo onAppear only stores this callback; SwiftUI invokes it after presentation, never during render.
  const appearance = onAppear(focusDestination);
  const label = t(link?.href === '' ? 'drafts.link.add' : 'drafts.link.edit');
  const open = () => {
    if (link !== undefined) {
      setEditing(link);
      setText(link.text);
      setDestination(link.href);
      setChecked(false);
      show(true);
    }
  };
  const trigger =
    renderMenu === undefined ? (
      <SwiftUIButton
        label={label}
        modifiers={[
          labelStyle('iconOnly'),
          buttonStyle('plain'),
          font({ size: popover ? scaledToolbar.symbol : 20 }),
          foregroundStyle(colors.textPrimary),
          frame({ minWidth: 44, minHeight: 44 }),
          inactive(disabled || link === undefined),
        ]}
        systemImage="link"
        onPress={open}
      />
    ) : (
      <RNHostView matchContents>
        {renderMenu({
          key: 'link',
          title: label,
          symbol: 'link',
          disabled: disabled || link === undefined,
          run: open,
        })}
      </RNHostView>
    );
  const fields = {
    destinationInput,
    text,
    destination,
    applicable,
    adding: editing?.href === '',
    invalid,
    onCheck: check,
    onText: setText,
    onDestination: setDestination,
    onApply: apply,
    onRemove: remove,
  };
  return popover ? (
    <Host matchContents>
      <Popover
        arrowEdge="top"
        isPresented={shown}
        onIsPresentedChange={show}>
        <Popover.Trigger>{trigger}</Popover.Trigger>
        <Popover.Content>
          <Group modifiers={[appearance]}>
            <RNHostView matchContents>
              <LinkPopover {...fields} />
            </RNHostView>
          </Group>
        </Popover.Content>
      </Popover>
    </Host>
  ) : (
    <>
      <Host matchContents>{trigger}</Host>
      <Host matchContents>
        <BottomSheet
          isPresented={shown}
          onIsPresentedChange={show}>
          <Group modifiers={[presentationDetents(['medium']), appearance]}>
            <RNHostView>
              <LinkSheet
                {...fields}
                onClose={() => {
                  show(false);
                }}
              />
            </RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
  );
}

type LinkFields = Readonly<{
  destinationInput: RefObject<TextInputInstance | null>;
  text: string;
  destination: string;
  applicable: boolean;
  // A new link: titled Add Link, with nothing to remove.
  adding: boolean;
  // Return or leaving Link found a destination it cannot apply.
  invalid: boolean;
  onCheck: () => void;
  onText: (text: string) => void;
  onDestination: (destination: string) => void;
  onApply: () => void;
  onRemove: () => void;
}>;

// iPad "Link Editor" frame.
function LinkPopover({
  destinationInput,
  text,
  destination,
  applicable,
  adding,
  invalid,
  onCheck,
  onText,
  onDestination,
  onApply,
  onRemove,
}: LinkFields) {
  const { t } = useLocalization();
  const colors = usePalette();
  const field = (url: boolean) => {
    const label = t(url ? 'drafts.link.destination' : 'drafts.link.text');
    return (
      <View style={styles.linkField}>
        <Text style={[styles.linkLabel, { color: colors.textSecondary }]}>
          {label}
        </Text>
        <TextInput
          accessibilityLabel={label}
          autoCapitalize={url ? 'none' : 'sentences'}
          autoCorrect={!url}
          keyboardType={url ? 'url' : 'default'}
          onBlur={url ? onCheck : undefined}
          onChangeText={url ? onDestination : onText}
          onSubmitEditing={onApply}
          placeholder={url ? t('drafts.link.placeholder') : undefined}
          placeholderTextColor={colors.textSecondary}
          ref={url ? destinationInput : undefined}
          style={[
            styles.linkInput,
            { backgroundColor: colors.fillQuiet, color: colors.textPrimary },
          ]}
          value={url ? destination : text}
        />
      </View>
    );
  };
  return (
    <View style={styles.linkPopover}>
      {field(false)}
      {field(true)}
      <Text
        style={[
          styles.linkPopoverHint,
          { color: invalid ? colors.statusDestructive : colors.textSecondary },
        ]}>
        {t(invalid ? 'drafts.link.invalid' : 'drafts.link.hint')}
      </Text>
      <View style={styles.linkActions}>
        {adding ? null : (
          <Host matchContents>
            <SwiftUIButton
              label={t('drafts.link.remove')}
              modifiers={[buttonStyle('bordered')]}
              // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
              role="destructive"
              onPress={onRemove}
            />
          </Host>
        )}
        <Host matchContents>
          <SwiftUIButton
            label={t('drafts.link.apply')}
            modifiers={[
              buttonStyle('borderedProminent'),
              tint(colors.accentFill),
              inactive(!applicable),
            ]}
            onPress={onApply}
          />
        </Host>
      </View>
    </View>
  );
}

// iPhone "Sheet · Edit Link" frame.
function LinkSheet({
  destinationInput,
  text,
  destination,
  applicable,
  adding,
  invalid,
  onCheck,
  onText,
  onDestination,
  onApply,
  onRemove,
  onClose,
}: LinkFields & { readonly onClose: () => void }) {
  const { t } = useLocalization();
  const colors = usePalette();
  const row = (url: boolean) => {
    const label = t(url ? 'drafts.link.destination' : 'drafts.link.text');
    return (
      <View style={styles.linkRow}>
        <Text style={[styles.linkRowLabel, { color: colors.textPrimary }]}>
          {label}
        </Text>
        <TextInput
          accessibilityLabel={label}
          autoCapitalize={url ? 'none' : 'sentences'}
          autoCorrect={!url}
          keyboardType={url ? 'url' : 'default'}
          onBlur={url ? onCheck : undefined}
          onChangeText={url ? onDestination : onText}
          onSubmitEditing={onApply}
          placeholder={url ? t('drafts.link.placeholder') : undefined}
          placeholderTextColor={colors.textSecondary}
          ref={url ? destinationInput : undefined}
          style={[styles.linkRowInput, { color: colors.textPrimary }]}
          value={url ? destination : text}
        />
      </View>
    );
  };
  return (
    <View style={styles.linkSheet}>
      <View style={styles.linkSheetHeader}>
        <Host matchContents>
          <SwiftUIButton
            label={t('drafts.close')}
            systemImage="xmark"
            onPress={onClose}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('glass'),
              buttonBorderShape('circle'),
              controlSize('large'),
            ]}
          />
        </Host>
        <Text
          accessibilityRole="header"
          style={[styles.linkSheetTitle, { color: colors.textPrimary }]}>
          {t(adding ? 'drafts.link.add' : 'drafts.link.edit')}
        </Text>
        <Host matchContents>
          <SwiftUIButton
            label={t('drafts.link.apply')}
            systemImage="checkmark"
            onPress={onApply}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('glassProminent'),
              buttonBorderShape('circle'),
              controlSize('large'),
              tint(colors.accentFill),
              inactive(!applicable),
            ]}
          />
        </Host>
      </View>
      <View
        style={[styles.linkGroup, { backgroundColor: colors.surfaceContent }]}>
        {row(false)}
        <View
          style={[styles.linkSeparator, { backgroundColor: colors.separator }]}
        />
        {row(true)}
      </View>
      <Text
        style={[
          styles.linkSheetHint,
          { color: invalid ? colors.statusDestructive : colors.textSecondary },
        ]}>
        {t(invalid ? 'drafts.link.invalid' : 'drafts.link.hint')}
      </Text>
      {adding ? null : (
        <View
          style={[
            styles.linkGroup,
            { backgroundColor: colors.surfaceContent },
          ]}>
          <Host matchContents={{ vertical: true }}>
            <SwiftUIButton
              // oxlint-disable-next-line jsx-a11y/aria-role -- SwiftUI button role, not ARIA.
              role="destructive"
              onPress={onRemove}>
              <HStack
                modifiers={[
                  padding({ horizontal: spacing.l }),
                  frame({ minHeight: 48 }),
                  contentShape(shapes.rectangle()),
                ]}>
                <SwiftUIText>{t('drafts.link.remove')}</SwiftUIText>
                <Spacer />
              </HStack>
            </SwiftUIButton>
          </Host>
        </View>
      )}
    </View>
  );
}

// Generate a Draft's open prompt. The composer keeps it above its layouts, so a resize between the
// iPad popover and the iPhone sheet re-presents it as it was. It belongs to its owner, the Mail
// Profile it was opened in, and closes once that changes or Mail Assistance becomes unavailable.
export function useGeneratePrompt(owner: string | undefined) {
  const [state, setState] = useState({
    owner,
    shown: false,
    opening: 0,
    prompt: '',
  });
  if (state.owner !== owner) {
    setState({ owner, shown: false, opening: state.opening + 1, prompt: '' });
  }
  return {
    shown: state.shown,
    opening: state.opening,
    prompt: state.prompt,
    // Each opening is a new prompt.
    open: () => {
      setState((current) =>
        // A queued menu choice cannot open a prompt after its owner or opening retired.
        owner !== undefined &&
        current.owner === owner &&
        current.opening === state.opening
          ? { ...current, shown: true, opening: current.opening + 1 }
          : current,
      );
    },
    close: () => {
      setState((current) => ({ ...current, shown: false, prompt: '' }));
    },
    setPrompt: (prompt: string) => {
      setState((current) => ({ ...current, prompt }));
    },
  };
}
export type GeneratePromptState = ReturnType<typeof useGeneratePrompt>;

// Generate a Draft's prompt, opened from Writing tools: a popover below the trigger on iPad, a
// sheet on iPhone. Only the shown opening may close or generate, and every dismissal retires it,
// so already-queued input cannot generate a closed prompt.
export function GeneratePrompt({
  state,
  popover,
  disabled,
  trigger,
  onGenerate,
}: {
  readonly state: GeneratePromptState;
  readonly popover: boolean;
  readonly disabled: boolean;
  readonly trigger: ReactElement;
  readonly onGenerate: (prompt: string) => void;
}) {
  const { shown, opening, prompt } = state;
  const active = useRef<number | undefined>(undefined);
  useLayoutEffect(() => {
    active.current = shown ? opening : undefined;
    return () => {
      active.current = undefined;
    };
  }, [shown, opening]);
  const close = (at: number) => {
    if (active.current === at) {
      active.current = undefined;
      state.close();
    }
  };
  const dismiss = (next: boolean) => {
    if (!next) {
      close(opening);
    }
  };
  const fields = (
    <GenerateFields
      key={opening}
      popover={popover}
      disabled={disabled || !shown}
      prompt={prompt}
      onPrompt={(text) => {
        if (active.current === opening) {
          state.setPrompt(text);
        }
      }}
      onClose={() => {
        close(opening);
      }}
      onGenerate={(text) => {
        if (active.current === opening) {
          close(opening);
          onGenerate(text);
        }
      }}
    />
  );
  return popover ? (
    <Host matchContents>
      <Popover
        arrowEdge="top"
        isPresented={shown}
        onIsPresentedChange={dismiss}>
        <Popover.Trigger>
          <RNHostView matchContents>{trigger}</RNHostView>
        </Popover.Trigger>
        <Popover.Content>
          <RNHostView matchContents>{fields}</RNHostView>
        </Popover.Content>
      </Popover>
    </Host>
  ) : (
    <>
      {trigger}
      <Host matchContents>
        <BottomSheet
          isPresented={shown}
          onIsPresentedChange={dismiss}>
          <Group modifiers={[presentationDetents(['medium'])]}>
            <RNHostView>{fields}</RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
  );
}

// "Generate a Draft" frames. The prompt is never kept.
function GenerateFields({
  popover,
  disabled,
  prompt,
  onPrompt,
  onClose,
  onGenerate,
}: {
  readonly popover: boolean;
  readonly disabled: boolean;
  readonly prompt: string;
  readonly onPrompt: (prompt: string) => void;
  readonly onClose: () => void;
  readonly onGenerate: (prompt: string) => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const input = useRef<TextInputInstance>(null);
  useLayoutEffect(() => {
    if (disabled) {
      input.current?.blur();
    }
  }, [disabled]);
  const generable = !disabled && canGenerate(prompt);
  const generate = () => {
    if (generable) {
      onGenerate(prompt);
    }
  };
  useMailAssistanceLifetime(onClose);
  return (
    <View style={[styles.generate, popover && styles.generatePopover]}>
      <View style={styles.generateHeader}>
        <SFSymbol
          name="sparkles"
          size={15}
          color={colors.textPrimary}
        />
        <Text
          accessibilityRole="header"
          style={[styles.generateTitle, { color: colors.textPrimary }]}>
          {t('assistance.generatePromptTitle')}
        </Text>
        <Host matchContents>
          <SwiftUIButton
            label={t('assistance.closeGenerate')}
            systemImage="xmark"
            onPress={onClose}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('bordered'),
              buttonBorderShape('circle'),
            ]}
          />
        </Host>
      </View>
      <TextInput
        multiline
        submitBehavior="submit"
        accessibilityLabel={t('assistance.generatePromptLabel')}
        // oxlint-disable-next-line jsx-a11y/no-autofocus -- The person opened Generate a Draft to type a prompt.
        autoFocus={!disabled}
        editable={!disabled}
        onChangeText={onPrompt}
        onSubmitEditing={generate}
        placeholder={t('assistance.generatePrompt')}
        placeholderTextColor={colors.textSecondary}
        ref={input}
        style={[styles.generatePrompt, { color: colors.textPrimary }]}
        value={prompt}
      />
      <View style={styles.generateActions}>
        <Host matchContents>
          <SwiftUIButton
            label={t('assistance.generateAction')}
            onPress={generate}
            modifiers={[
              buttonStyle('borderedProminent'),
              buttonBorderShape('capsule'),
              tint(colors.accentFill),
              inactive(!generable),
              spokenLabel(t('assistance.generateActionLabel')),
            ]}
          />
        </Host>
      </View>
    </View>
  );
}
