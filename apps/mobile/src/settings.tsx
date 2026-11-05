import type { ReactElement, ReactNode } from 'react';

import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { Fragment } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
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
import { ipadFrameSymbolSize, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

// Settings destinations this client supports; the others follow their owning issues.
export type SettingsDestination =
  | 'account'
  | 'mailboxes'
  | 'profiles'
  | 'notifications'
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
  { title: 'automation', items: [{ id: 'notifications', icon: 'bell' }] },
  {
    title: 'application',
    items: [
      { id: 'language', icon: 'translate' },
      { id: 'privacy', icon: 'hand.raised' },
    ],
  },
] as const;

// iPad uses a two-column workspace; iPhone pushes one destination over the list of them.
export const settingsColumns = Platform.OS === 'ios' && Platform.isPad;

// iPad scales the Mac recipe by 1.15, as its Inbox does; iPhone uses the iOS text styles.
const type = settingsColumns
  ? {
      title: typography.ipadList.body,
      detail: typography.ipadList.subheadline,
      page: typography.ipadList.title3Emphasized,
      account: typography.ipadList.title3Emphasized,
    }
  : {
      title: textStyles.body,
      detail: textStyles.subheadline,
      page: textStyles.headline,
      // The iPhone frames title the account cards at 20/25 semibold.
      account: textStyles.title3Emphasized,
    };

// UIKit draws these symbols larger than the iPad frames' artwork at the frames' size; these sizes
// match the frames' ink in the sidebar and in content rows. The frames' translate ink sits a point
// right of its slot's centre, and their at ink 1.5pt below its row's centre.
const itemSymbolSizes: Readonly<Partial<Record<string, number>>> = {
  translate: 11.5,
};
const itemSymbolOffsets: Readonly<Partial<Record<string, number>>> = {
  translate: 1,
};
const rowSymbolSizes: Readonly<Partial<Record<string, number>>> = {
  at: 15,
  photo: 13.8,
};
const rowSymbolOffsets: Readonly<Partial<Record<string, number>>> = {
  at: 1.5,
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
const rowPadding = settingsColumns ? 10 * ipadListScale : spacing.m;
const phoneButtonHeight = 36.4;
const rowInset = settingsColumns ? spacing.m * ipadListScale : spacing.l;
// iPad's row rules are the Mac recipe's point at 1.15×, as its frames draw them.
const rule = settingsColumns ? ipadListScale : StyleSheet.hairlineWidth;

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
  // The panel's top row: Close at its leading end, where Mailboxes has its sidebar toggle. The
  // frames give it a 32.2pt title bar 16.1pt below the panel's top.
  sidebarTop: {
    height: 48.3,
    paddingTop: 16.1,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 9,
  },
  close: {
    width: 32,
    height: 32,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 16,
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
  // Symbols centre in fixed slots, so a wide one such as translate keeps its label in line.
  itemIcon: { width: 18, alignItems: 'center' },
  rowIcon: { width: 20, alignItems: 'center' },
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
  // A 24pt symbol slot puts the destinations' titles on the frames' x68 axis.
  destinationIcon: { width: 24, alignItems: 'center' },
  // iPad's two-line rows are 61.3pt, as the frames draw them.
  rowText: { flex: 1, gap: settingsColumns ? 3.8 : 2 },
  // Trailing controls may take the row's padding, so a push button or the native picker keeps
  // iPad's 46pt row; on iPhone a 36.4pt push button centres in the 52pt row.
  trailing: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    alignItems: 'center',
    gap: spacing.s,
    flexShrink: 1,
    marginVertical: settingsColumns
      ? -rowPadding
      : (52 - phoneButtonHeight) / 2 - rowPadding,
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
  monogram: { alignItems: 'center', justifyContent: 'center' },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: settingsColumns ? 14 * ipadListScale : 14,
    paddingHorizontal: settingsColumns ? spacing.l * ipadListScale : spacing.l,
    paddingVertical: settingsColumns ? 14 * ipadListScale : spacing.m,
    borderRadius: settingsColumns ? radius.card : radius.insetGroup,
    borderCurve: 'continuous',
  },
  // Account & Devices' own card on iPhone, as its frame draws it.
  detailCard: {
    gap: 18.2,
    paddingHorizontal: 20.8,
    paddingVertical: 18.2,
    borderRadius: radius.settingsDetail,
  },
  // iPad draws the Mac's 28pt push button at 1.15×, iPhone's frames a 36.4pt one; hit slop keeps
  // the 44pt target.
  button: {
    minHeight: settingsColumns ? 28 * ipadListScale : phoneButtonHeight,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
});

const buttonSlop =
  (44 - (settingsColumns ? 28 * ipadListScale : phoneButtonHeight)) / 2;

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
      <Text
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
        numberOfLines={1}
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
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        pressed && { backgroundColor: colors.accentSelectionSubtle },
      ]}>
      <Hairline />
      <View style={styles.destinationIcon}>
        <SFSymbol
          name={icon}
          size={20}
          color={colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={1}
        style={[type.title, styles.grow, { color: colors.textPrimary }]}>
        {label}
      </Text>
      <SFSymbol
        name="chevron.right"
        size={14}
        color={colors.textSecondary}
      />
    </Pressable>
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
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const insets = useSafeAreaInsets();
  const header = usePaletteHeader();
  const content = (
    <ScrollView contentContainerStyle={styles.content}>{children}</ScrollView>
  );
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
            {navigation === undefined ? null : (
              <Pressable
                accessibilityLabel={t('settings.close')}
                accessibilityRole="button"
                disabled={navigation.disabled}
                hitSlop={6}
                onPress={() => {
                  navigation.onInbox();
                }}
                style={({ pressed }) => [
                  styles.close,
                  {
                    backgroundColor: pressed
                      ? colors.accentSelectionSubtle
                      : colors.fillQuiet,
                  },
                ]}>
                <SFSymbol
                  name="xmark"
                  size={14}
                  color={colors.textPrimary}
                />
              </Pressable>
            )}
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
                      numberOfLines={1}
                      style={[
                        type.title,
                        { fontWeight: '600', color: colors.textPrimary },
                      ]}>
                      {account}
                    </Text>
                    <Text
                      numberOfLines={1}
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
              <>
                <SidebarItem
                  icon="chevron.left"
                  label={t('errorReporting.backToWelcome')}
                  selected={false}
                  onPress={onWelcome}
                />
                <SidebarItem
                  icon="hand.raised"
                  label={t('settings.destinations.privacy')}
                  selected
                  onPress={() => undefined}
                />
              </>
            )}
          </ScrollView>
        </View>
        <View style={styles.grow}>
          <AccountHeader
            title={t(
              `settings.destinations.${onWelcome === undefined ? selected : 'privacy'}`,
            )}
            accessory={accessory}
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
        <Pressable
          accessibilityLabel={t('settings.destinations.account')}
          accessibilityRole="button"
          onPress={() => {
            onDestination('account');
          }}
          style={({ pressed }) => [
            styles.card,
            {
              backgroundColor: pressed
                ? colors.accentSelectionSubtle
                : colors.fillQuiet,
            },
          ]}>
          <AccountMonogram
            name={account}
            size={52}
          />
          <View style={styles.grow}>
            <Text
              numberOfLines={1}
              style={[type.account, { color: colors.textPrimary }]}>
              {account}
            </Text>
            <Text
              numberOfLines={1}
              style={[textStyles.footnote, { color: colors.textSecondary }]}>
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
        </Pressable>
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
          headerConfig={bar(t(`settings.destinations.${destination}`))}
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
            variant === 'navigation' && { borderRadius: radius.insetGroup },
            { backgroundColor: colors.fillQuiet },
          ]}>
          {/* Each cell draws a hairline above itself; this hides the first one. */}
          <View style={styles.cells}>{children}</View>
        </View>
      )}
      {footer === undefined ? null : (
        <View style={styles.footer}>
          <Text style={[type.detail, { color: colors.textSecondary }]}>
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
  return (
    <View style={[styles.separator, { backgroundColor: colors.separator }]} />
  );
}

// A row: an optional SF Symbol or icon view, the title and its subtitle, then its trailing controls.
export function SettingsRow({
  icon,
  title,
  titleTone,
  titleNumberOfLines,
  disabled = false,
  subtitle,
  subtitleTone,
  minHeight,
  children,
}: {
  readonly icon?: string | ReactElement;
  readonly title: string;
  readonly titleTone?: 'accent' | 'destructive';
  readonly titleNumberOfLines?: number;
  readonly disabled?: boolean;
  readonly subtitle?: string | undefined;
  // A subtitle reporting a problem takes the warning color.
  readonly subtitleTone?: 'warning' | undefined;
  // A row the frames draw taller than the group's other rows.
  readonly minHeight?: number | undefined;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={[styles.row, minHeight === undefined ? null : { minHeight }]}>
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
            color={colors.accentInk}
          />
        </View>
      ) : (
        icon
      )}
      <View style={[styles.rowText, disabled && { opacity: 0.4 }]}>
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
              type.detail,
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
      {children === undefined ? null : (
        <View style={styles.trailing}>{children}</View>
      )}
    </View>
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
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled: busy }}
      disabled={busy}
      hitSlop={buttonSlop}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          alignSelf: 'flex-start',
          backgroundColor:
            tone === 'destructive' ? 'transparent' : colors.fillQuiet,
          opacity: busy ? 0.4 : 1,
        },
        pressed &&
          tone !== 'destructive' && {
            backgroundColor: colors.accentSelectionSubtle,
          },
      ]}>
      {({ pressed }) => (
        <Text
          style={[
            type.title,
            {
              textDecorationLine:
                pressed && tone === 'destructive' ? 'underline' : 'none',
              color:
                tone === 'destructive'
                  ? colors.statusDestructive
                  : colors.textPrimary,
            },
          ]}>
          {title}
        </Text>
      )}
    </Pressable>
  );
}
