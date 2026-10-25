import type {
  BlockKind,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactNode } from 'react';
import type {
  NativeSyntheticEvent,
  StyleProp,
  TextStyle,
  ViewProps,
} from 'react-native';

import { spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef } from 'react';
import {
  processColor,
  requireNativeComponent,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  formatBar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  divider: { width: StyleSheet.hairlineWidth, height: 16, marginHorizontal: 2 },
  // AppKit's regular pop-up is 24pt tall and 49pt wider than its title, for insets and chevrons.
  popUp: { height: 24, flexShrink: 1, justifyContent: 'center' },
  pullDown: { width: 46 },
  fieldPopUp: { flex: 1 },
  popUpSizing: { opacity: 0, paddingHorizontal: 25 },
  // A titled pull-down also draws its symbol, about 20pt with its gap, before the title.
  symbolSizing: { paddingLeft: 45 },
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

// One item of a control's native menu; its key names the command, so a choice runs the latest
// callback for that key while the control is mounted, and nothing once the item is gone. An item
// without `run` is a heading, or opens the submenu of its `items`.
export type PopUpItem = Readonly<{
  key: string;
  title: string;
  accessibilityLabel?: string;
  // An SF Symbol beside the title.
  symbol?: string;
  checked?: boolean;
  disabled?: boolean;
  destructive?: boolean;
  run?: () => void;
  items?: readonly PopUpItem[];
}>;

type NativePopUpItem = Omit<PopUpItem, 'key' | 'run' | 'items'> & {
  readonly id: string;
  readonly items?: readonly NativePopUpItem[];
};

const nativeItems = (items: readonly PopUpItem[]): NativePopUpItem[] =>
  items.map(({ key, run: _run, items: submenu, ...item }) => ({
    ...item,
    id: key,
    ...(submenu === undefined ? {} : { items: nativeItems(submenu) }),
  }));

const allItems = (items: readonly PopUpItem[]): PopUpItem[] =>
  items.flatMap((item) => [item, ...allItems(item.items ?? [])]);

const NativePopUpButton = requireNativeComponent<
  ViewProps & {
    readonly items: readonly NativePopUpItem[];
    readonly text: string | undefined;
    readonly symbol: string | undefined;
    readonly label: string;
    readonly destructiveColor: ReturnType<typeof processColor>;
    readonly enabled: boolean;
    readonly onSelect: (event: NativeSyntheticEvent<{ id: string }>) => void;
  }
>('UnwiredPopUpButton');

// A pop-up button that AppKit draws, focuses and opens: a label shows the current choice; an icon
// makes it a pull-down button, titled by any label. A choice runs the latest item while the control
// is mounted.
export function PopUp({
  label,
  accessibilityLabel,
  icon,
  variant = 'compact',
  disabled = false,
  items,
}: {
  readonly label?: string;
  readonly accessibilityLabel: string;
  readonly icon?: string | undefined;
  readonly variant?: 'compact' | 'field';
  readonly disabled?: boolean;
  readonly items: readonly PopUpItem[];
}) {
  const colors = usePalette();
  const latest = useRef(items);
  useLayoutEffect(() => {
    latest.current = disabled ? [] : items;
    return () => {
      latest.current = [];
    };
  });
  return (
    <View
      style={[
        styles.popUp,
        label === undefined ? styles.pullDown : null,
        variant === 'field' ? styles.fieldPopUp : null,
      ]}>
      {/* The hidden label sizes the pop-up, which AppKit draws over it. */}
      {label === undefined ? null : (
        <Text
          numberOfLines={1}
          style={[
            textStyles.body,
            styles.popUpSizing,
            icon === undefined ? null : styles.symbolSizing,
          ]}>
          {label}
        </Text>
      )}
      {/* The accessibility props serve Testing Library; VoiceOver reads the AppKit pop-up. */}
      <NativePopUpButton
        accessible
        accessibilityLabel={accessibilityLabel}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
        accessibilityValue={label === undefined ? undefined : { text: label }}
        destructiveColor={processColor(colors.statusDestructive)}
        enabled={!disabled}
        items={nativeItems(items)}
        label={accessibilityLabel}
        onSelect={({ nativeEvent }) => {
          allItems(latest.current)
            .find(
              (item) => item.key === nativeEvent.id && item.disabled !== true,
            )
            ?.run?.();
        }}
        style={StyleSheet.absoluteFill}
        symbol={icon}
        text={label}
      />
    </View>
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
          destructive: true,
          disabled,
          run: onDiscard,
        },
      ]}
    />
  );
}

export function FormatBar({
  active,
  kind,
  disabled,
  onBlock,
  onMark,
  children,
}: {
  readonly active: readonly Mark[];
  readonly kind: BlockKind;
  readonly disabled: boolean;
  readonly onBlock: (kind: BlockKind) => void;
  readonly onMark: (mark: Mark) => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View
      accessibilityLabel={t('drafts.formatting')}
      accessibilityRole="toolbar"
      style={[styles.formatBar, { borderColor: colors.separator }]}>
      <PopUp
        accessibilityLabel={t('drafts.textStyle')}
        disabled={disabled}
        label={t(blockNames[kind])}
        items={textStyleKinds.map((value) => ({
          key: value,
          title: t(blockNames[value]),
          checked: kind === value,
          disabled,
          run: () => {
            onBlock(value);
          },
        }))}
      />
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
    </View>
  );
}
