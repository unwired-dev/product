import type {
  BlockKind,
  Link,
  Mark,
} from '@private-email/mail-core/semantic-document';
import type { ReactNode, RefObject } from 'react';
import type { StyleProp, TextStyle } from 'react-native';

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
import { vettedHref } from '@private-email/mail-core/link-inspection';
import { isLinkText } from '@private-email/mail-core/semantic-document';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { useRef, useState } from 'react';
import {
  Animated,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { Glass, SFSymbol, ToolbarButton, useMenuMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

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

// The format bar's Link control and the Link Editor it opens for the link at the caret, or to
// add one to selected unlinked text: a popover below the control on iPad, a sheet on iPhone. It
// is unavailable otherwise.
export function LinkEditor({
  link,
  disabled,
  popover,
  onChange,
  onShown,
}: {
  readonly link: Link | undefined;
  readonly disabled: boolean;
  readonly popover: boolean;
  readonly onChange: (link: Link, text: string, href?: string) => void;
  // Reports when the editor opens and closes, for a parent that must stay while it is shown.
  readonly onShown?: (shown: boolean) => void;
}) {
  const { t } = useLocalization();
  const [editing, setEditing] = useState<Link>();
  const [shown, setShown] = useState(false);
  const show = (next: boolean) => {
    setShown(next);
    onShown?.(next);
  };
  const [text, setText] = useState('');
  const [destination, setDestination] = useState('');
  const destinationInput = useRef<TextInput>(null);
  // Whether to say why the destination cannot be applied, once Return or leaving Link checked it.
  const [checked, setChecked] = useState(false);
  const href = vettedHref(destination);
  const applicable = href !== undefined && isLinkText(text);
  const finish = (next: string, nextHref?: string) => {
    show(false);
    if (editing !== undefined) {
      onChange(editing, next, nextHref);
    }
  };
  const apply = () => {
    setChecked(true);
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
  const trigger = (
    <SwiftUIButton
      label={t(link?.href === '' ? 'drafts.link.add' : 'drafts.link.edit')}
      modifiers={[
        labelStyle('iconOnly'),
        buttonStyle('plain'),
        font({ size: 20 }),
        foregroundStyle(colors.textPrimary),
        frame({ minWidth: 44, minHeight: 44 }),
        inactive(disabled || link === undefined),
      ]}
      systemImage="link"
      onPress={() => {
        if (link !== undefined) {
          setEditing(link);
          setText(link.text);
          setDestination(link.href);
          setChecked(false);
          show(true);
        }
      }}
    />
  );
  const fields = {
    destinationInput,
    text,
    destination,
    applicable,
    adding: editing?.href === '',
    invalid: checked && href === undefined,
    onCheck: () => {
      setChecked(true);
    },
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
  destinationInput: RefObject<TextInput | null>;
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
