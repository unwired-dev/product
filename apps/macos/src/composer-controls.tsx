import type {
  BlockKind,
  Link,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactNode } from 'react';
import type { ColorValue, NativeSyntheticEvent, ViewProps } from 'react-native';

import { vettedHref } from '@private-email/mail-core/link-inspection';
import { isLinkText } from '@private-email/mail-core/semantic-document';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef, useState } from 'react';
import {
  processColor,
  requireNativeComponent,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  Button,
  Popover,
  ToolbarButton,
  useOutcomeAnnouncement,
} from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  // The "Link Editor" popover frame.
  linkPopover: { width: 340, gap: 10, padding: 14 },
  linkField: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  linkLabel: { ...textStyles.body, width: 36 },
  linkInput: {
    ...textStyles.body,
    flex: 1,
    height: 26,
    paddingHorizontal: spacing.s,
    borderRadius: radius.control,
  },
  linkActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
  },
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
const markControls: ReadonlyArray<readonly [Mark, MarkName]> = [
  ['bold', 'drafts.marks.bold'],
  ['italic', 'drafts.marks.italic'],
  ['underline', 'drafts.marks.underline'],
  ['strikethrough', 'drafts.marks.strikethrough'],
  ['code', 'drafts.marks.code'],
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
// without `run` is a heading, or opens the submenu of its `items` or of its `sections`, groups of
// items set apart by separators.
export type PopUpItem = Readonly<{
  key: string;
  title: string;
  accessibilityLabel?: string;
  // An SF Symbol beside the title, in its own color when given.
  symbol?: string;
  symbolColor?: ColorValue;
  checked?: boolean;
  disabled?: boolean;
  destructive?: boolean;
  run?: () => void;
  items?: readonly PopUpItem[];
  sections?: ReadonlyArray<Readonly<{ items: readonly PopUpItem[] }>>;
}>;

type NativePopUpItem = Omit<
  PopUpItem,
  'key' | 'run' | 'symbolColor' | 'items' | 'sections'
> & {
  readonly id: string;
  readonly symbolColor?: ReturnType<typeof processColor>;
  readonly items?: readonly NativePopUpItem[];
  readonly sections?: ReadonlyArray<{ readonly items: NativePopUpItem[] }>;
};

const nativeItems = (items: readonly PopUpItem[]): NativePopUpItem[] =>
  items.map(
    ({ key, run: _run, symbolColor, items: submenu, sections, ...item }) => ({
      ...item,
      id: key,
      ...(symbolColor === undefined
        ? {}
        : { symbolColor: processColor(symbolColor) }),
      ...(submenu === undefined ? {} : { items: nativeItems(submenu) }),
      ...(sections === undefined
        ? {}
        : {
            sections: sections.map((section) => ({
              items: nativeItems(section.items),
            })),
          }),
    }),
  );

const enabledItems = (items: readonly PopUpItem[]): PopUpItem[] =>
  items.flatMap((item) =>
    item.disabled === true
      ? []
      : [
          item,
          ...enabledItems([
            ...(item.items ?? []),
            ...(item.sections ?? []).flatMap((section) => section.items),
          ]),
        ],
  );

const NativePopUpButton = requireNativeComponent<
  ViewProps & {
    readonly sections: ReadonlyArray<{ readonly items: NativePopUpItem[] }>;
    readonly text: string | undefined;
    readonly symbol: string | undefined;
    readonly pullsDown: boolean;
    readonly label: string;
    readonly destructiveColor: ReturnType<typeof processColor>;
    readonly enabled: boolean;
    readonly onSelect: (event: NativeSyntheticEvent<{ id: string }>) => void;
  }
>('UnwiredPopUpButton');

// AppKit draws, focuses and opens the control. Icon controls default to pull-downs; a selected
// choice can retain its icon as a pop-up. A choice runs the latest item while mounted.
export function PopUp({
  label,
  accessibilityLabel,
  icon,
  pullsDown,
  variant = 'compact',
  disabled = false,
  items,
  sections,
}: {
  readonly label?: string;
  readonly accessibilityLabel: string;
  readonly icon?: string | undefined;
  readonly pullsDown?: boolean;
  readonly variant?: 'compact' | 'field';
  readonly disabled?: boolean;
  readonly items?: readonly PopUpItem[];
  // Groups of items set apart by separators, in place of `items`.
  readonly sections?: ReadonlyArray<Readonly<{ items: readonly PopUpItem[] }>>;
}) {
  const colors = usePalette();
  const groups = sections ?? [{ items: items ?? [] }];
  const shown = groups.flatMap((section) => section.items);
  const latest = useRef(shown);
  useLayoutEffect(() => {
    latest.current = disabled ? [] : shown;
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
        pullsDown={pullsDown ?? icon !== undefined}
        sections={groups.map((section) => ({
          items: nativeItems(section.items),
        }))}
        label={accessibilityLabel}
        onSelect={({ nativeEvent }) => {
          enabledItems(latest.current)
            .find((item) => item.key === nativeEvent.id)
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
      {markControls.map(([mark, name]) => (
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

// The format bar's Link control and the Link Editor popover it opens below itself for the link
// at the caret, or to add one to selected unlinked text. It is unavailable otherwise.
export function LinkEditor({
  link,
  disabled,
  onChange,
}: {
  readonly link: Link | undefined;
  readonly disabled: boolean;
  readonly onChange: (link: Link, text: string, href?: string) => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const [editing, setEditing] = useState<Link>();
  const [shown, setShown] = useState(false);
  const [text, setText] = useState('');
  const [destination, setDestination] = useState('');
  // Whether to say why the destination cannot be applied, once Return or leaving Link checked it.
  const [checked, setChecked] = useState(false);
  // An empty Link is the editor's starting state, not an invalid destination.
  const check = () => {
    setChecked(destination.trim() !== '');
  };
  const href = vettedHref(destination);
  const applicable = href !== undefined && isLinkText(text);
  const adding = editing?.href === '';
  const finish = (next: string, nextHref?: string) => {
    setShown(false);
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
  const field = (url: boolean) => {
    const label = t(url ? 'drafts.link.destination' : 'drafts.link.text');
    return (
      <View style={styles.linkField}>
        <Text style={[styles.linkLabel, { color: colors.textSecondary }]}>
          {label}
        </Text>
        <TextInput
          accessibilityLabel={label}
          autoCorrect={!url}
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- User-opened Add Link must focus Link when the popover gains its native window, after layout.
          autoFocus={url && adding}
          onBlur={url ? check : undefined}
          onChangeText={url ? setDestination : setText}
          onSubmitEditing={apply}
          placeholder={url ? t('drafts.link.placeholder') : undefined}
          placeholderTextColor={colors.textSecondary}
          style={[
            styles.linkInput,
            { backgroundColor: colors.fillQuiet, color: colors.textPrimary },
          ]}
          value={url ? destination : text}
        />
      </View>
    );
  };
  const invalid = checked && destination.trim() !== '' && href === undefined;
  // VoiceOver hears the reason when it appears, since macOS ignores live regions.
  useOutcomeAnnouncement(
    shown && invalid ? t('drafts.link.invalid') : undefined,
    false,
  );
  return (
    <View>
      <ToolbarButton
        disabled={disabled || link === undefined}
        icon="link"
        label={t(link?.href === '' ? 'drafts.link.add' : 'drafts.link.edit')}
        onPress={() => {
          if (link !== undefined) {
            setEditing(link);
            setText(link.text);
            setDestination(link.href);
            setChecked(false);
            setShown(true);
          }
        }}
      />
      <Popover
        below
        shown={shown}
        onClose={() => {
          setShown(false);
        }}>
        <View style={styles.linkPopover}>
          {field(false)}
          {field(true)}
          <Label
            style={[
              textStyles.subheadline,
              {
                color: invalid
                  ? colors.statusDestructive
                  : colors.textSecondary,
              },
            ]}>
            {t(invalid ? 'drafts.link.invalid' : 'drafts.link.hint')}
          </Label>
          <View style={styles.linkActions}>
            {adding ? null : (
              <Button
                destructive
                label={t('drafts.link.remove')}
                onPress={() => {
                  if (editing !== undefined) {
                    finish(editing.text);
                  }
                }}
              />
            )}
            <Button
              disabled={!applicable}
              fill="accent"
              label={t('drafts.link.apply')}
              onPress={apply}
            />
          </View>
        </View>
      </Popover>
    </View>
  );
}
