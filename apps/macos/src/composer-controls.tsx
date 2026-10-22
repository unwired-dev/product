import type {
  BlockKind,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactNode } from 'react';
import type { StyleProp, TextStyle, TurboModule } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef } from 'react';
import {
  findNodeHandle,
  Pressable,
  processColor,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  View,
} from 'react-native';

import { SFSymbol, ToolbarButton } from './design.tsx';
import { useLocalization } from './localization.ts';
import { isMenuChoice } from './native-menu.ts';
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
  popUp: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    minHeight: 28,
    paddingLeft: 10,
    paddingRight: spacing.s,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  iconPopUp: {
    width: 32,
    justifyContent: 'center',
    paddingLeft: 0,
    paddingRight: 0,
  },
  popUpText: { ...textStyles.body, flexShrink: 1 },
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
// callback for that key while the control is mounted, and nothing once the item is gone.
type PopUpItem = Readonly<{
  key: string;
  title: string;
  accessibilityLabel?: string;
  checked?: boolean;
  disabled?: boolean;
  destructive?: boolean;
  run: () => void;
}>;

interface NativeMenu extends TurboModule {
  readonly show: (
    anchor: number,
    sections: ReadonlyArray<{
      readonly items: ReadonlyArray<
        Omit<PopUpItem, 'key' | 'run'> & { id: string }
      >;
    }>,
    destructiveColor: ReturnType<typeof processColor>,
  ) => Promise<unknown>;
}

// A pop-up control whose AppKit menu, dropped below it, owns presentation, keyboard and
// dismissal.
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
  readonly items: readonly PopUpItem[];
}) {
  const colors = usePalette();
  const anchor = useRef<View>(null);
  const latest = useRef(items);
  useLayoutEffect(() => {
    latest.current = disabled ? [] : items;
    return () => {
      latest.current = [];
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
      [
        {
          items: items.map(({ key, run: _run, ...item }) => ({
            ...item,
            id: key,
          })),
        },
      ],
      processColor(colors.statusDestructive),
    );
    if (isMenuChoice(chosen)) {
      latest.current
        .find((item) => item.key === chosen && item.disabled !== true)
        ?.run();
    }
  };
  return (
    <Pressable
      ref={anchor}
      collapsable={false}
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected }}
      disabled={disabled}
      onPress={() => {
        void show();
      }}
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
        icon="textformat"
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
