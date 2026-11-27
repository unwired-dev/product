import type { ReactElement, ReactNode, RefObject } from 'react';
import type { ScrollViewInstance, StyleProp, ViewStyle } from 'react-native';

import {
  Host,
  RNHostView,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  accessibilityLabel as spokenLabel,
  background,
  buttonBorderShape,
  buttonStyle,
  contentShape,
  controlSize,
  disabled as inactive,
  font,
  foregroundStyle,
  frame,
  labelStyle,
  padding,
  shapes,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { createContext, Fragment, use, useRef, useState } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  ScreenStack,
  ScreenStackHeaderCenterView,
  ScreenStackHeaderRightView,
  ScreenStackItem,
} from 'react-native-screens';

import { AccountHeader } from './account-page.tsx';
import { usePaletteHeader } from './command-palette.tsx';
import { ipadFrameSymbolSize, MenuButton, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, useLargeText, usePalette } from './theme.ts';

// Settings destinations this client supports; the others follow their owning issues.
// The Settings content's scroll view, which a request scrolls to what it reveals.
export const SettingsScroll = createContext<
  RefObject<ScrollViewInstance | null> | undefined
>(undefined);

// Whether a row draws its own hairline; an action row draws it outside its button.
const RowHairline = createContext(true);

export type SettingsDestination =
  | 'account'
  | 'mailboxes'
  | 'profiles'
  | 'signatures'
  | 'notifications'
  | 'blockedSenders'
  | 'reading'
  | 'appearance'
  | 'language'
  | 'privacy'
  | 'errorReporting';

// The groups below the account item, in the design's order.
const sections = [
  {
    title: 'accounts',
    items: [
      { id: 'mailboxes', icon: 'at' },
      { id: 'profiles', icon: 'person.crop.rectangle.stack' },
    ],
  },
  { title: 'mail', items: [{ id: 'reading', icon: 'text.book.closed' }] },
  { title: 'composing', items: [{ id: 'signatures', icon: 'signature' }] },
  {
    title: 'automation',
    items: [
      { id: 'notifications', icon: 'bell' },
      { id: 'blockedSenders', icon: 'hand.raised.slash' },
    ],
  },
  {
    title: 'application',
    items: [
      { id: 'appearance', icon: 'paintbrush' },
      { id: 'language', icon: 'translate' },
      { id: 'privacy', icon: 'hand.raised' },
    ],
  },
] as const;

// iPad uses a two-column workspace; iPhone pushes one destination over the list of them.
export const settingsColumns = Platform.OS === 'ios' && Platform.isPad;

// iPad scales the Mac recipe by 1.15, as its Inbox does; iPhone uses the iOS text styles, with
// Footnote subtitles in its rows.
const type = settingsColumns
  ? {
      title: typography.ipadList.body,
      detail: typography.ipadList.subheadline,
      subtitle: typography.ipadList.subheadline,
      page: typography.ipadList.title3Emphasized,
      account: typography.ipadList.title3Emphasized,
    }
  : {
      title: textStyles.body,
      detail: textStyles.subheadline,
      subtitle: textStyles.footnote,
      page: textStyles.headline,
      // The iPhone frames title the account cards at 20/25 semibold.
      account: textStyles.title3Emphasized,
    };

// UIKit draws these symbols larger than the iPad frames' artwork at the frames' size; these sizes
// come closest to the frames' ink in the sidebar and in content rows; no regular-weight symbol
// configuration matches both of a frame's dimensions. The Dark and Light frames' translate ink
// sits 1.5pt and 2.5pt right of its slot's centre, and their at ink about 1pt below its row's
// centre.
const itemSymbolSizes: Readonly<Partial<Record<string, number>>> = {
  translate: 11.25,
};
const itemSymbolOffsets: Readonly<Partial<Record<string, number>>> = {
  translate: 2,
};
const rowSymbolSizes: Readonly<Partial<Record<string, number>>> = {
  at: 11.5,
  photo: 13.8,
};
// At the large symbol scale, at draws 15×15pt ink, the closest to the frames' 16×15pt and
// 16×14pt of any regular-weight configuration.
const rowSymbolScales: Readonly<
  Partial<Record<string, 'small' | 'medium' | 'large'>>
> = {
  at: 'large',
};
const rowSymbolOffsets: Readonly<Partial<Record<string, number>>> = {
  at: 0.75,
};

// A push button in a Settings row; `title` is its visible text when the label names its target.
export type SettingsButton = (
  label: string,
  action: () => Promise<void>,
  options?: Readonly<{
    title?: string;
    tone?: 'destructive' | undefined;
    disabled?: boolean;
  }>,
) => ReactNode;

const groupRadius = settingsColumns ? radius.card : radius.settingsDetail;

// iPad rows follow the frames' Mac recipe at 1.15×: 46pt single-line and 61.3pt two-line rows.
// iPhone's Settings Row pads 13pt, so a 36pt push button makes a 62pt row.
const rowPadding = settingsColumns ? 10 * ipadListScale : 13;
// iPhone's frames draw a row with a switch at least 56pt tall.
export const switchRowHeight = settingsColumns ? undefined : 56;
const rowInset = settingsColumns ? spacing.m * ipadListScale : spacing.l;
// iPad's row rules are the Mac recipe's point at 1.15×, as its frames draw them.
const rule = settingsColumns ? ipadListScale : StyleSheet.hairlineWidth;

// iPad draws the Mac's 28pt push button at 1.15×, iPhone's frames a 36pt one; the clear slop
// around it keeps the 44pt target without moving the layout.
const pushButtonHeight = settingsColumns ? 28 * ipadListScale : 36;
const pushButtonSlop = (44 - pushButtonHeight) / 2;
// Stacked push buttons keep their 44pt hit areas apart.
const pushButtonGap = Math.max(spacing.s, 2 * pushButtonSlop);

const styles = StyleSheet.create({
  page: { flex: 1 },
  columns: { flex: 1, flexDirection: 'row' },
  // The floating sidebar panel the iPad frames draw, beneath the status bar.
  sidebar: {
    width: 248,
    marginLeft: spacing.s,
    marginTop: spacing.s,
    marginBottom: spacing.s,
    borderRadius: 21,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
  },
  sidebarList: { padding: 9, paddingTop: 0 },
  // The panel's top row: the 44pt glass Back button 6.9pt below the panel's top and 4.6pt above
  // the first item, as the frames place it.
  sidebarTop: {
    height: 55.5,
    paddingTop: 6.9,
    flexDirection: 'row',
    paddingHorizontal: 9.2,
  },
  account: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 51,
    paddingHorizontal: 9,
    paddingVertical: 7,
    borderRadius: 9,
    borderCurve: 'continuous',
  },
  sectionHeader: {
    ...typography.ipadList.subheadline,
    fontWeight: '600',
    paddingHorizontal: 9,
    paddingTop: spacing.m,
    paddingBottom: spacing.xs,
  },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 28 * ipadListScale,
    paddingHorizontal: 9,
    borderRadius: 7,
    borderCurve: 'continuous',
  },
  grow: { flex: 1 },
  // A hosted multiline label needs an intrinsic flex basis so Yoga measures its wrapped height.
  wrappingLabel: { flexGrow: 1, flexShrink: 1 },
  // Symbols centre in fixed slots, so a wide one such as translate keeps its label in line.
  itemIcon: { width: 18, alignItems: 'center' },
  rowIcon: { width: settingsColumns ? 20 : 24, alignItems: 'center' },
  // iPad's cards start 28pt beside the sidebar and end 32pt from the window's edge.
  content: {
    gap: settingsColumns ? spacing.s : 10,
    paddingLeft: settingsColumns ? 28 : spacing.l,
    paddingRight: settingsColumns ? 32 : spacing.l,
    paddingTop: spacing.s,
    paddingBottom: spacing.xl,
  },
  groupHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: spacing.m,
    paddingHorizontal: rowInset,
  },
  actionRowDisabled: { opacity: 0.9 },
  cells: { marginTop: -StyleSheet.hairlineWidth },
  group: {
    overflow: 'hidden',
    borderRadius: groupRadius,
    borderCurve: 'continuous',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: settingsColumns ? rowPadding : spacing.m,
    minHeight: settingsColumns ? 40 * ipadListScale : 52,
    paddingHorizontal: rowInset,
    paddingVertical: rowPadding,
  },
  // At accessibility text sizes a row stacks its symbol, text, value and controls, as UIKit's list
  // cells do, so the title keeps the row's width.
  rowStacked: { flexDirection: 'column', alignItems: 'stretch' },
  rowTextStacked: { flex: 0 },
  // Stacked controls keep their own height beneath the text.
  trailingStacked: { justifyContent: 'flex-start', marginVertical: 0 },
  // A 24pt symbol slot puts the destinations' titles on the frames' x68 axis.
  destinationIcon: { width: 24, alignItems: 'center' },
  // iPad's two-line rows are 61.3pt, as the frames draw them.
  rowText: { flex: 1, gap: settingsColumns ? 3.8 : 2 },
  // On iPad trailing controls take the row's padding, so a push button or the native picker keeps
  // its 46pt row.
  trailing: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    alignItems: 'center',
    columnGap: spacing.s,
    // Wrapped push buttons keep their hit areas apart.
    rowGap: pushButtonGap,
    flexShrink: 1,
    marginVertical: settingsColumns ? -rowPadding : 0,
  },
  block: {
    gap: spacing.s,
    paddingHorizontal: rowInset,
    paddingVertical: spacing.m,
  },
  // iPad's thicker rule ends where a hairline would, so the rows keep their places and the group
  // still hides the first.
  separator: {
    position: 'absolute',
    top: StyleSheet.hairlineWidth - rule,
    left: rowInset,
    right: rowInset,
    height: rule,
  },
  footer: { paddingHorizontal: rowInset },
  // Yoga's pixel rounding can leave a wrapped footer a hair shorter than its lines, and iOS then
  // draws only the first as one clipped line. A slack off the pixel grid rounds the text's frame up
  // a pixel, and the matching margin keeps the footer's own height.
  footerText: { paddingBottom: 0.1, marginBottom: -0.1 },
  monogram: { alignItems: 'center', justifyContent: 'center' },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: settingsColumns ? 14 * ipadListScale : 14,
    paddingHorizontal: settingsColumns ? spacing.l * ipadListScale : spacing.l,
    paddingVertical: settingsColumns ? 14 * ipadListScale : spacing.m,
    borderRadius: settingsColumns ? radius.card : radius.mailboxGroup,
    borderCurve: 'continuous',
  },
  // Account & Devices' own card on iPhone, as its frame draws it.
  detailCard: {
    gap: 18.2,
    paddingHorizontal: 20.8,
    paddingVertical: 18.2,
    borderRadius: radius.settingsDetail,
  },
  // On iPhone the pop-up's 44pt target reaches into the row's padding, keeping the row 52pt.
  popUpTarget: { marginVertical: settingsColumns ? 0 : -spacing.m },
  popUpStacked: { marginVertical: 0, flexShrink: 1 },
  popUpLabelWrap: { flexShrink: 1 },
  popUp: {
    minHeight: 44,
    flexDirection: 'row',
    alignItems: 'center',
    gap: settingsColumns ? spacing.xs : spacing.m,
  },
  popUpLabel: settingsColumns ? typography.ipadList.body : textStyles.body,
  popUpOpaque: { opacity: 1 },
  popUpDisabled: { opacity: 0.4 },
  popUpChevrons: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  pushButton: { alignSelf: 'flex-start' },
  // Beside a busy indicator the button shrinks to the room left.
  pushButtonWrapping: { width: '100%', flexShrink: 1 },
  pushButtonColumn: { gap: pushButtonGap },
  // The row's wrapping controls drop a child's negative top margin; a column keeps it.
  pushButtonHost: { marginVertical: -pushButtonSlop },
});

// The Mail Profile and account monogram: the first letter on brand graphite.
function AccountMonogram({
  name,
  size,
}: {
  readonly name: string;
  readonly size: number;
}) {
  const colors = usePalette();
  return (
    <View
      accessibilityElementsHidden
      importantForAccessibility="no-hide-descendants"
      style={[
        styles.monogram,
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: colors.brandMonogram,
        },
      ]}>
      {/* The letter keeps the circle's size, which does not grow with the text. */}
      <Text
        allowFontScaling={false}
        style={[
          size > 40 ? type.page : type.title,
          { fontWeight: '600', color: colors.brandOnDeep },
        ]}>
        {[...name][0]?.toLocaleUpperCase() ?? ''}
      </Text>
    </View>
  );
}

// An iPad sidebar item: selection shows as fill and weight.
function SidebarItem({
  icon,
  label,
  selected,
  onPress,
}: {
  readonly icon: string;
  readonly label: string;
  readonly selected: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const large = useLargeText();
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.item,
        (selected || pressed) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
      ]}>
      <View style={[styles.itemIcon, { left: itemSymbolOffsets[icon] }]}>
        <SFSymbol
          name={icon}
          size={itemSymbolSizes[icon] ?? ipadFrameSymbolSize}
          color={colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          type.title,
          styles.grow,
          selected && { fontWeight: '600' },
          { color: colors.textPrimary },
        ]}>
        {label}
      </Text>
    </Pressable>
  );
}

// The iPad sidebar's glass Back: to Welcome before sign-in, otherwise to mail.
function SidebarBack({
  navigation,
  onWelcome,
}: {
  readonly navigation:
    | Readonly<{ onInbox: () => void; disabled: boolean }>
    | undefined;
  readonly onWelcome: (() => void) | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const back =
    onWelcome === undefined
      ? navigation && {
          label: t('settings.backToMail'),
          onPress: navigation.onInbox,
          disabled: navigation.disabled,
        }
      : {
          label: t('errorReporting.backToWelcome'),
          onPress: onWelcome,
          disabled: false,
        };
  if (back === undefined) {
    return null;
  }
  return (
    <Host matchContents>
      <SwiftUIButton
        label={back.label}
        systemImage="chevron.left"
        onPress={() => {
          back.onPress();
        }}
        modifiers={[
          labelStyle('iconOnly'),
          buttonStyle('glass'),
          buttonBorderShape('circle'),
          controlSize('large'),
          tint(colors.textPrimary),
          inactive(back.disabled),
        ]}
      />
    </Host>
  );
}

// An iPhone row that pushes its destination.
function DestinationRow({
  icon,
  label,
  onPress,
}: {
  readonly icon: string;
  readonly label: string;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const large = useLargeText();
  return (
    <SettingsActionRow
      label={label}
      disabled={false}
      ignoreSafeArea="container"
      onPress={onPress}>
      <View style={styles.row}>
        <View style={styles.destinationIcon}>
          <SFSymbol
            name={icon}
            size={20}
            color={colors.accentInk}
          />
        </View>
        <Text
          numberOfLines={large ? 0 : 1}
          style={[
            type.title,
            large ? styles.wrappingLabel : styles.grow,
            { color: colors.textPrimary },
          ]}>
          {label}
        </Text>
        <SFSymbol
          name="chevron.right"
          size={14}
          color={colors.textSecondary}
        />
      </View>
    </SettingsActionRow>
  );
}

// Settings: on iPad a glass sidebar of destinations beside the selected one's form; on iPhone the
// list of destinations, or one destination pushed over it in the system navigation bar.
export function SettingsWorkspace({
  account,
  privateSync = false,
  destination,
  onDestination,
  navigation,
  accessory,
  onWelcome,
  children,
  detail,
  edit,
}: {
  // The Product Account the account item names.
  readonly account: string;
  // Whether Private Sync is on, which the iPhone account item says.
  readonly privateSync?: boolean;
  readonly destination: SettingsDestination | undefined;
  readonly onDestination: (
    destination: SettingsDestination | undefined,
  ) => void;
  readonly navigation?: Readonly<{
    // Closes the iPhone list over what Settings covered; setup has nothing beneath it.
    onBack: (() => void) | undefined;
    onInbox: () => void;
    disabled: boolean;
  }>;
  // Shown in the header, such as an activity indicator and the way back to the Inbox.
  readonly accessory?: ReactNode;
  readonly onWelcome?: () => void;
  // The selected destination's groups.
  readonly children: ReactNode;
  readonly detail?: ReactNode;
  // The destination is a system list, which scrolls itself and whose edit mode Edit switches.
  readonly edit?:
    | Readonly<{ editing: boolean; onEdit: (editing: boolean) => void }>
    | undefined;
}) {
  const colors = usePalette();
  // Names wrap at accessibility text sizes rather than truncate.
  const lines = useLargeText() ? 0 : 1;
  const { t } = useLocalization();
  const insets = useSafeAreaInsets();
  const header = usePaletteHeader();
  const scroll = useRef<ScrollViewInstance>(null);
  const content =
    edit === undefined ? (
      // A control beside a field, such as the signature's Bold, acts on the first tap.
      <ScrollView
        ref={scroll}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled">
        <SettingsScroll value={scroll}>{children}</SettingsScroll>
      </ScrollView>
    ) : (
      <View style={styles.page}>{children}</View>
    );
  const editLabel = (editing: boolean) =>
    t(editing ? 'common.done' : 'settings.edit');
  if (settingsColumns) {
    const selected = destination ?? 'account';
    return (
      <View style={[styles.columns, { paddingTop: insets.top }]}>
        <View
          style={[
            styles.sidebar,
            {
              backgroundColor: colors.surfacePanel,
              borderColor: colors.separator,
              boxShadow: colors.largeGlassShadow,
            },
          ]}>
          <View style={styles.sidebarTop}>
            <SidebarBack
              navigation={navigation}
              onWelcome={onWelcome}
            />
          </View>
          <ScrollView contentContainerStyle={styles.sidebarList}>
            {onWelcome === undefined ? (
              <>
                <Pressable
                  accessibilityLabel={t('settings.destinations.account')}
                  accessibilityRole="button"
                  accessibilityState={{ selected: selected === 'account' }}
                  onPress={() => {
                    onDestination('account');
                  }}
                  style={({ pressed }) => [
                    styles.account,
                    (selected === 'account' || pressed) && {
                      backgroundColor: colors.accentSelectionSubtle,
                    },
                  ]}>
                  <AccountMonogram
                    name={account}
                    size={37}
                  />
                  <View style={styles.grow}>
                    <Text
                      numberOfLines={lines}
                      style={[
                        type.title,
                        { fontWeight: '600', color: colors.textPrimary },
                      ]}>
                      {account}
                    </Text>
                    <Text
                      numberOfLines={lines}
                      style={[type.detail, { color: colors.textSecondary }]}>
                      {t('settings.destinations.account')}
                    </Text>
                  </View>
                </Pressable>
                {sections.map((section) => (
                  <Fragment key={section.title}>
                    <Text
                      accessibilityRole="header"
                      style={[
                        styles.sectionHeader,
                        { color: colors.textSecondary },
                      ]}>
                      {t(`settings.sections.${section.title}`)}
                    </Text>
                    {section.items.map((item) => (
                      <SidebarItem
                        key={item.id}
                        icon={item.icon}
                        label={t(`settings.destinations.${item.id}`)}
                        selected={
                          selected === item.id ||
                          (selected === 'errorReporting' &&
                            item.id === 'privacy')
                        }
                        onPress={() => {
                          onDestination(item.id);
                        }}
                      />
                    ))}
                  </Fragment>
                ))}
              </>
            ) : (
              <SidebarItem
                icon="hand.raised"
                label={t('settings.destinations.privacy')}
                selected
                onPress={() => undefined}
              />
            )}
          </ScrollView>
        </View>
        <View style={styles.grow}>
          <AccountHeader
            title={t(
              `settings.destinations.${onWelcome === undefined ? selected : 'privacy'}`,
            )}
            accessory={
              <>
                {accessory}
                {edit === undefined ? null : (
                  <Host matchContents>
                    <SwiftUIButton
                      label={editLabel(edit.editing)}
                      modifiers={[
                        buttonStyle('borderless'),
                        tint(colors.textPrimary),
                      ]}
                      onPress={() => {
                        edit.onEdit(!edit.editing);
                      }}
                    />
                  </Host>
                )}
              </>
            }
          />
          {content}
        </View>
      </View>
    );
  }
  // The welcome screen's Privacy page is pushed by its own stack, which shows its bar.
  if (onWelcome !== undefined) {
    return content;
  }
  // UIKit owns the bar controls; only the list's React title opens the palette.
  const bar = (title: string, titleView?: ReactNode) => ({
    title,
    backgroundColor: colors.surfaceContent,
    color: colors.textPrimary,
    titleColor: colors.textPrimary,
    hideShadow: true,
    backButtonDisplayMode: 'minimal' as const,
    headerRightBarButtonItems:
      navigation === undefined
        ? undefined
        : [
            {
              type: 'button' as const,
              icon: { type: 'sfSymbol' as const, name: 'tray' },
              accessibilityLabel: t('registration.openInbox'),
              onPress: navigation.onInbox,
              disabled: navigation.disabled,
            },
          ],
    children: (
      <>
        {titleView}
        <ScreenStackHeaderRightView hidesSharedBackground>
          {accessory}
        </ScreenStackHeaderRightView>
      </>
    ),
  });
  const list = (
    <View style={styles.page}>
      <ScrollView contentContainerStyle={styles.content}>
        {/* `children` are the shown destination's groups once one is pushed. */}
        {destination === undefined ? children : null}
        {/* The card stands alone, so it draws no hairline. */}
        <RowHairline value={false}>
          <SettingsActionRow
            label={t('settings.destinations.account')}
            disabled={false}
            ignoreSafeArea="container"
            onPress={() => {
              onDestination('account');
            }}>
            <View style={[styles.card, { backgroundColor: colors.fillQuiet }]}>
              <AccountMonogram
                name={account}
                size={52}
              />
              <View style={styles.wrappingLabel}>
                <Text
                  numberOfLines={lines}
                  style={[type.account, { color: colors.textPrimary }]}>
                  {account}
                </Text>
                <Text
                  numberOfLines={lines}
                  style={[
                    textStyles.footnote,
                    { color: colors.textSecondary },
                  ]}>
                  {privateSync
                    ? t('settings.accountPrivateSync')
                    : t('settings.destinations.account')}
                </Text>
              </View>
              <SFSymbol
                name="chevron.right"
                size={14}
                color={colors.textSecondary}
              />
            </View>
          </SettingsActionRow>
        </RowHairline>
        {sections.map((section) => (
          <SettingsGroup
            key={section.title}
            variant="navigation">
            {section.items.map((item) => (
              <DestinationRow
                key={item.id}
                icon={item.icon}
                label={t(`settings.destinations.${item.id}`)}
                onPress={() => {
                  onDestination(item.id);
                }}
              />
            ))}
          </SettingsGroup>
        ))}
      </ScrollView>
    </View>
  );
  // The list stays beneath its pushed destination, and Error Reporting is pushed over Privacy.
  return (
    <ScreenStack style={styles.page}>
      <ScreenStackItem
        screenId="settings-list"
        activityState={2}
        freezeOnBlur={false}
        headerConfig={{
          ...bar(
            t('settings.title'),
            <ScreenStackHeaderCenterView>
              <View {...header.swipe}>
                <Text
                  accessibilityRole="header"
                  numberOfLines={1}
                  // As UIKit draws bar titles, the title keeps its size in the fixed bar.
                  allowFontScaling={false}
                  style={[textStyles.headline, { color: colors.textPrimary }]}
                  {...header.action}>
                  {t('settings.title')}
                </Text>
              </View>
            </ScreenStackHeaderCenterView>,
          ),
          headerLeftBarButtonItems:
            navigation?.onBack === undefined
              ? undefined
              : [
                  {
                    type: 'button',
                    icon: { type: 'sfSymbol', name: 'chevron.left' },
                    accessibilityLabel: t('settings.back'),
                    onPress: navigation.onBack,
                    disabled: navigation.disabled,
                  },
                ],
        }}>
        <View
          style={styles.page}
          accessibilityElementsHidden={destination !== undefined}
          importantForAccessibility={
            destination === undefined ? 'auto' : 'no-hide-descendants'
          }>
          {list}
        </View>
      </ScreenStackItem>
      {destination === undefined ? null : (
        <ScreenStackItem
          screenId="settings-destination"
          testID="settings-destination"
          activityState={2}
          freezeOnBlur={false}
          headerConfig={{
            ...bar(t(`settings.destinations.${destination}`)),
            // An editable list's frames give its bar Edit alone.
            ...(edit === undefined
              ? {}
              : {
                  headerRightBarButtonItems: [
                    {
                      type: 'button' as const,
                      title: editLabel(edit.editing),
                      variant: edit.editing ? 'done' : 'plain',
                      onPress: () => {
                        edit.onEdit(!edit.editing);
                      },
                    },
                  ],
                }),
          }}
          gestureEnabled
          onDismissed={() => {
            onDestination(undefined);
          }}>
          <View
            style={styles.page}
            accessibilityElementsHidden={detail !== undefined}
            importantForAccessibility={
              detail === undefined ? 'auto' : 'no-hide-descendants'
            }>
            {content}
          </View>
        </ScreenStackItem>
      )}
      {detail === undefined ? null : (
        <ScreenStackItem
          screenId="error-reporting"
          testID="error-reporting-detail"
          activityState={2}
          headerConfig={bar(t('errorReporting.title'))}
          gestureEnabled
          onDismissed={({ nativeEvent: { dismissCount } }) => {
            onDestination(dismissCount > 1 ? undefined : 'privacy');
          }}>
          <ScrollView contentContainerStyle={styles.content}>
            {detail}
          </ScrollView>
        </ScreenStackItem>
      )}
    </ScreenStack>
  );
}

// The account's monogram, name and sign-in, above the Account & Devices groups.
export function AccountCard({
  name,
  detail,
}: {
  readonly name: string;
  readonly detail: string;
}) {
  const colors = usePalette();
  return (
    <View
      style={[
        styles.card,
        !settingsColumns && styles.detailCard,
        { backgroundColor: colors.fillQuiet },
      ]}>
      <AccountMonogram
        name={name}
        size={settingsColumns ? 48 * ipadListScale : 62.4}
      />
      <View style={styles.rowText}>
        <Text style={[type.account, { color: colors.textPrimary }]}>
          {name}
        </Text>
        <Text style={[type.detail, { color: colors.textSecondary }]}>
          {detail}
        </Text>
      </View>
    </View>
  );
}

// A row that runs one action: the system button, with the row as its label and its spoken name.
// The button dims the row while it is disabled, to half strength; the frames draw a disabled row
// at 45%, so the row adds 90%. The hairline stays outside the button, at full strength.
export function SettingsActionRow({
  label,
  disabled,
  onPress,
  children,
  ...hostProps
}: {
  readonly label: string;
  readonly disabled: boolean;
  readonly onPress: () => void;
  readonly children: ReactElement;
  // The destination list already applies this inset. A second would move a scrolling label.
  readonly ignoreSafeArea?: 'container';
}) {
  // A text size changed while Settings is open keeps the hosted row's old height; a fresh host
  // measures the row again.
  const { fontScale } = useWindowDimensions();
  return (
    <View>
      <Hairline />
      <Host
        {...hostProps}
        key={fontScale}
        matchContents={{ vertical: true }}>
        <SwiftUIButton
          onPress={onPress}
          modifiers={[
            buttonStyle('plain'),
            inactive(disabled),
            spokenLabel(label),
          ]}>
          <RNHostView
            boundedByHost
            matchContents={{ vertical: true }}>
            <RowHairline value={false}>
              <View
                accessibilityElementsHidden
                style={disabled && styles.actionRowDisabled}>
                {children}
              </View>
            </RowHairline>
          </RNHostView>
        </SwiftUIButton>
      </Host>
    </View>
  );
}

// A titled group of rows with hairlines between them and an optional explanation below.
export function SettingsGroup({
  title,
  accessory,
  footer,
  children,
  variant = 'content',
}: {
  readonly title?: string | undefined;
  // Beside the title, such as the On device marker.
  readonly accessory?: ReactNode;
  readonly footer?: string | undefined;
  readonly children?: ReactNode;
  readonly variant?: 'content' | 'navigation';
}) {
  const colors = usePalette();
  return (
    <>
      {title === undefined ? null : (
        <View style={styles.groupHeader}>
          <Text
            accessibilityRole="header"
            style={[
              type.detail,
              { fontWeight: '600', color: colors.textSecondary },
            ]}>
            {title}
          </Text>
          {accessory}
        </View>
      )}
      {children === undefined || children === null ? null : (
        <View
          style={[
            styles.group,
            variant === 'navigation' && { borderRadius: radius.mailboxGroup },
            { backgroundColor: colors.fillQuiet },
          ]}>
          {/* Each cell draws a hairline above itself; this hides the first one. */}
          <View style={styles.cells}>{children}</View>
        </View>
      )}
      {footer === undefined ? null : (
        <View style={styles.footer}>
          <Text
            style={[
              type.detail,
              styles.footerText,
              { color: colors.textSecondary },
            ]}>
            {footer}
          </Text>
        </View>
      )}
    </>
  );
}

// The hairline above a group cell; the group hides the first one.
function Hairline() {
  const colors = usePalette();
  if (!use(RowHairline)) {
    return null;
  }
  return (
    <View style={[styles.separator, { backgroundColor: colors.separator }]} />
  );
}

// Push buttons beside other controls keep their own width; elsewhere a push button takes its
// column's width so a long title wraps.
const InlinePushButtons = createContext(false);

// A row: an optional SF Symbol or icon view, the title and its subtitle, then its trailing controls.
export function SettingsRow({
  icon,
  iconTone,
  title,
  titleTone,
  titleNumberOfLines,
  disabled = false,
  subtitle,
  subtitleTone,
  minHeight,
  value,
  accessibilityLabel,
  accessibilityAction,
  children,
}: {
  readonly icon?: string | ReactElement | undefined;
  // A symbol that names a thing rather than an action takes the text color.
  readonly iconTone?: 'primary' | undefined;
  readonly title: string;
  readonly titleTone?: 'accent' | 'destructive' | undefined;
  readonly titleNumberOfLines?: number;
  readonly disabled?: boolean;
  readonly subtitle?: string | undefined;
  // A subtitle reporting a problem takes the warning color.
  readonly subtitleTone?: 'warning' | undefined;
  // A row the frames draw taller than the group's other rows.
  readonly minHeight?: number | undefined;
  // A status at the trailing edge, before any controls.
  readonly value?: string | undefined;
  // Read as one element in place of the title, subtitle and value; trailing controls stay apart.
  readonly accessibilityLabel?: string | undefined;
  // That element's action, which repeats a trailing control's.
  readonly accessibilityAction?:
    | Readonly<{ label: string; onActivate: () => void }>
    | undefined;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  const large = useLargeText();
  return (
    <View
      style={[
        styles.row,
        large && styles.rowStacked,
        minHeight === undefined ? null : { minHeight },
      ]}>
      <Hairline />
      {typeof icon === 'string' ? (
        <View
          style={[
            styles.rowIcon,
            settingsColumns && { top: rowSymbolOffsets[icon] },
          ]}>
          <SFSymbol
            name={icon}
            size={
              settingsColumns
                ? (rowSymbolSizes[icon] ?? 16 * ipadListScale)
                : 20
            }
            scale={settingsColumns ? rowSymbolScales[icon] : undefined}
            color={
              iconTone === 'primary' ? colors.textPrimary : colors.accentInk
            }
          />
        </View>
      ) : (
        icon
      )}
      <View
        accessible={accessibilityLabel !== undefined}
        accessibilityLabel={accessibilityLabel}
        accessibilityActions={
          accessibilityAction === undefined
            ? undefined
            : [{ name: 'activate', label: accessibilityAction.label }]
        }
        onAccessibilityAction={accessibilityAction?.onActivate}
        style={[
          styles.rowText,
          large && styles.rowTextStacked,
          disabled && { opacity: 0.4 },
        ]}>
        <Text
          numberOfLines={titleNumberOfLines}
          style={[
            type.title,
            {
              color:
                titleTone === undefined
                  ? colors.textPrimary
                  : {
                      accent: colors.accentInk,
                      destructive: colors.statusDestructive,
                    }[titleTone],
            },
          ]}>
          {title}
        </Text>
        {subtitle === undefined ? null : (
          <Text
            style={[
              type.subtitle,
              {
                color:
                  subtitleTone === 'warning'
                    ? colors.statusWarning
                    : colors.textSecondary,
              },
            ]}>
            {subtitle}
          </Text>
        )}
      </View>
      {value === undefined ? null : (
        <Text
          accessibilityElementsHidden={accessibilityLabel !== undefined}
          style={[type.title, { color: colors.textSecondary }]}>
          {value}
        </Text>
      )}
      {children === undefined ? null : (
        <View style={[styles.trailing, large && styles.trailingStacked]}>
          <InlinePushButtons value={!large}>{children}</InlinePushButtons>
        </View>
      )}
    </View>
  );
}

// The iPhone Settings Row pop-up's up-down chevrons in a 22pt circle, 12pt after its value;
// iPad frames that draw the circle use the Mac's 16pt one at 1.15×.
export function PopUpChevrons({
  scaled = false,
}: {
  readonly scaled?: boolean;
}) {
  const colors = usePalette();
  const size = scaled ? 16 * ipadListScale : 22;
  return (
    <View
      style={[
        styles.popUpChevrons,
        {
          width: size,
          height: size,
          borderRadius: size / 2,
          backgroundColor: colors.fillControl,
        },
      ]}>
      <SFSymbol
        name="chevron.up.chevron.down"
        size={scaled ? 10 * ipadListScale : 13}
        color={colors.textPrimary}
      />
    </View>
  );
}

// A Settings Row's choices in one native pop-up that checks the selected one: its title and
// chevrons at the row's trailing edge, iPhone's in the circle. A disabled pop-up keeps its choice,
// dimmed.
export function PopUpChoice<Choice extends string>({
  label,
  selected,
  choices,
  title,
  disabled = false,
  onChoose,
}: {
  // Names the setting for the pop-up's accessibility label.
  readonly label: string;
  readonly selected: Choice;
  readonly choices: readonly Choice[];
  readonly title: (choice: Choice) => string;
  readonly disabled?: boolean;
  readonly onChoose: (choice: Choice) => void;
}) {
  const colors = usePalette();
  const large = useLargeText();
  // iPad's secondary value dims, like iPhone's, to the row title's gray.
  const color =
    settingsColumns && !disabled ? colors.textSecondary : colors.textPrimary;
  return (
    <MenuButton
      accessibilityLabel={`${label}: ${title(selected)}`}
      disabled={disabled}
      sections={[
        {
          items: choices.map((choice) => ({
            key: choice,
            title: title(choice),
            symbol: '',
            checked: choice === selected,
            run: () => {
              onChoose(choice);
            },
          })),
        },
      ]}
      // The content dims, as the row dims its title, once: not the native button too.
      style={[
        styles.popUpTarget,
        large && styles.popUpStacked,
        disabled && styles.popUpOpaque,
      ]}>
      <View style={[styles.popUp, disabled && styles.popUpDisabled]}>
        <Text
          numberOfLines={large ? 0 : 1}
          style={[
            styles.popUpLabel,
            large && styles.popUpLabelWrap,
            { color },
          ]}>
          {title(selected)}
        </Text>
        {settingsColumns ? (
          <SFSymbol
            name="chevron.up.chevron.down"
            size={12}
            color={color}
          />
        ) : (
          <PopUpChevrons />
        )}
      </View>
    </MenuButton>
  );
}

// A group cell whose content stacks: explanations, fields and their buttons.
export function SettingsBlock({ children }: { readonly children: ReactNode }) {
  return (
    <View style={styles.block}>
      <Hairline />
      {children}
    </View>
  );
}

// Push buttons one above another in a block, their hit areas apart.
export function PushButtonColumn({
  children,
}: {
  readonly children: ReactNode;
}) {
  return <View style={styles.pushButtonColumn}>{children}</View>;
}

// Settings push buttons; while registration is busy they are disabled.
export function settingsButton(busy: boolean): SettingsButton {
  return function SettingsPushButton(label, action, options) {
    return (
      <PushButton
        key={label}
        busy={busy || options?.disabled === true}
        label={label}
        title={options?.title ?? label}
        tone={options?.tone}
        onPress={() => {
          void action();
        }}
      />
    );
  };
}

// Push buttons side by side; larger text, or buttons wider than the room, stack them.
export function PushButtonRow({
  style,
  buttons,
  children,
}: {
  readonly style: StyleProp<ViewStyle>;
  // What the buttons show: a change, like a new text size, measures them again side by side.
  readonly buttons: string;
  readonly children: ReactNode;
}) {
  const large = useLargeText();
  const { fontScale } = useWindowDimensions();
  const [room, setRoom] = useState(Infinity);
  const [measured, setMeasured] = useState({ fontScale, buttons, needed: 0 });
  const stacked =
    large ||
    (measured.fontScale === fontScale &&
      measured.buttons === buttons &&
      measured.needed >= room);
  return (
    <View
      style={stacked ? styles.pushButtonColumn : null}
      onLayout={(event) => {
        setRoom(event.nativeEvent.layout.width);
      }}>
      <InlinePushButtons value={!stacked}>
        {stacked ? (
          children
        ) : (
          // Sized by its buttons, so its width is the room they need.
          <View
            style={[styles.pushButton, style]}
            onLayout={(event) => {
              setMeasured({
                fontScale,
                buttons,
                needed: event.nativeEvent.layout.width,
              });
            }}>
            {children}
          </View>
        )}
      </InlinePushButtons>
    </View>
  );
}

// A system button drawn as the frames' push button: a primary label on the quiet fill with the
// control corners, or a destructive label without a fill, aligned with the row's text. The
// bordered style would draw a darker capsule.
function PushButton({
  busy,
  label,
  title,
  tone,
  onPress,
}: {
  readonly busy: boolean;
  readonly label: string;
  readonly title: string;
  readonly tone: 'destructive' | undefined;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const wrapping = !use(InlinePushButtons);
  const shape = shapes.roundedRectangle({
    cornerRadius: settingsColumns
      ? radius.control * ipadListScale
      : radius.control,
  });
  const side = settingsColumns ? spacing.m * ipadListScale : 14;
  return (
    <View style={wrapping ? styles.pushButtonWrapping : styles.pushButton}>
      <Host
        key={wrapping ? 'wrapping' : 'ideal'}
        matchContents={wrapping ? { vertical: true } : true}
        style={styles.pushButtonHost}>
        <SwiftUIButton
          role={tone ?? 'default'}
          onPress={onPress}
          modifiers={[
            buttonStyle('plain'),
            inactive(busy),
            spokenLabel(label),
            ...(wrapping
              ? [frame({ maxWidth: Infinity, alignment: 'leading' })]
              : []),
          ]}>
          <SwiftUIText
            modifiers={[
              font({ textStyle: settingsColumns ? 'subheadline' : 'body' }),
              foregroundStyle(
                tone === 'destructive'
                  ? colors.statusDestructive
                  : colors.textPrimary,
              ),
              padding({
                horizontal: tone === 'destructive' ? 0 : side,
                vertical: 6,
              }),
              frame({ minHeight: pushButtonHeight }),
              ...(tone === 'destructive'
                ? []
                : [background(colors.fillQuiet, shape)]),
              padding({ vertical: pushButtonSlop }),
              contentShape(shapes.rectangle()),
            ]}>
            {title}
          </SwiftUIText>
        </SwiftUIButton>
      </Host>
    </View>
  );
}
