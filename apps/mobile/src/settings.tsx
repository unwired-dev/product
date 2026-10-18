import type { ReactNode } from 'react';

import { radius, spacing, typography } from '@private-email/mail-core/theme';
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

import { AccountHeader } from './account-page.tsx';
import { BackNavigation } from './back-navigation.tsx';
import { Glass, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

// Settings destinations this client supports; the others follow their owning issues.
export type SettingsDestination =
  | 'account'
  | 'mailboxes'
  | 'language'
  | 'privacy';

// The groups below the account item, in the design's order.
const sections = [
  { title: 'accounts', items: [{ id: 'mailboxes', icon: 'at' }] },
  {
    title: 'application',
    items: [
      { id: 'language', icon: 'globe' },
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
    }
  : {
      title: textStyles.body,
      detail: textStyles.subheadline,
      page: textStyles.headline,
    };

// A push button in a Settings row; `title` is its visible text when the label names its target.
export type SettingsButton = (
  label: string,
  action: () => Promise<void>,
  options?: Readonly<{ title?: string; tone?: 'destructive' | undefined }>,
) => ReactNode;

const groupRadius = settingsColumns ? radius.card : radius.settingsDetail;

const styles = StyleSheet.create({
  page: { flex: 1 },
  columns: { flex: 1, flexDirection: 'row' },
  sidebar: {
    width: 248,
    marginLeft: spacing.s,
    marginBottom: spacing.s,
    borderRadius: 21,
    borderCurve: 'continuous',
  },
  sidebarList: { padding: 9 },
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
    minHeight: 44,
    paddingHorizontal: 9,
    borderRadius: 7,
    borderCurve: 'continuous',
  },
  grow: { flex: 1 },
  content: {
    gap: settingsColumns ? spacing.s : 10,
    paddingHorizontal: settingsColumns ? 28 : spacing.l,
    paddingTop: spacing.s,
    paddingBottom: spacing.xl,
  },
  groupHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: spacing.m,
    paddingHorizontal: settingsColumns ? 14 : spacing.l,
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
    gap: spacing.m,
    minHeight: 52,
    paddingHorizontal: settingsColumns ? 14 : spacing.l,
    paddingVertical: spacing.m,
  },
  rowText: { flex: 1, gap: 2 },
  trailing: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'flex-end',
    alignItems: 'center',
    gap: spacing.s,
    flexShrink: 1,
  },
  block: {
    gap: spacing.s,
    paddingHorizontal: settingsColumns ? 14 : spacing.l,
    paddingVertical: spacing.m,
  },
  separator: {
    position: 'absolute',
    top: 0,
    left: settingsColumns ? 14 : spacing.l,
    right: settingsColumns ? 14 : spacing.l,
    height: StyleSheet.hairlineWidth,
  },
  footer: { paddingHorizontal: settingsColumns ? 14 : spacing.l },
  monogram: { alignItems: 'center', justifyContent: 'center' },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.l,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.m,
    borderRadius: settingsColumns ? radius.card : radius.insetGroup,
    borderCurve: 'continuous',
  },
  button: {
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
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
      <SFSymbol
        name={icon}
        size={18}
        color={colors.accentInk}
      />
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
      <SFSymbol
        name={icon}
        size={20}
        color={colors.accentInk}
      />
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
// list of destinations, or one destination pushed over it with a way back.
export function SettingsWorkspace({
  account,
  destination,
  onDestination,
  accessory,
  children,
}: {
  // The Product Account the account item names.
  readonly account: string;
  readonly destination: SettingsDestination | undefined;
  readonly onDestination: (
    destination: SettingsDestination | undefined,
  ) => void;
  // Shown in the header, such as an activity indicator and the way back to the Inbox.
  readonly accessory?: ReactNode;
  // The selected destination's groups.
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const insets = useSafeAreaInsets();
  const content = (
    <ScrollView contentContainerStyle={styles.content}>{children}</ScrollView>
  );
  if (settingsColumns) {
    const selected = destination ?? 'account';
    return (
      <View style={[styles.columns, { paddingTop: insets.top }]}>
        <View style={[styles.sidebar, { boxShadow: colors.largeGlassShadow }]}>
          <Glass cornerRadius={21} />
          <ScrollView contentContainerStyle={styles.sidebarList}>
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
                    selected={selected === item.id}
                    onPress={() => {
                      onDestination(item.id);
                    }}
                  />
                ))}
              </Fragment>
            ))}
          </ScrollView>
        </View>
        <View style={styles.grow}>
          <AccountHeader
            title={t(`settings.destinations.${selected}`)}
            accessory={accessory}
          />
          {content}
        </View>
      </View>
    );
  }
  if (destination !== undefined) {
    return (
      <BackNavigation
        testID="settings-back-navigation"
        onBack={() => {
          onDestination(undefined);
        }}>
        <AccountHeader
          title={t(`settings.destinations.${destination}`)}
          onBack={() => {
            onDestination(undefined);
          }}
          accessory={accessory}
        />
        {content}
      </BackNavigation>
    );
  }
  return (
    <View style={styles.page}>
      <AccountHeader
        title={t('settings.title')}
        accessory={accessory}
      />
      <ScrollView contentContainerStyle={styles.content}>
        {children}
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
              style={[type.page, { color: colors.textPrimary }]}>
              {account}
            </Text>
            <Text
              numberOfLines={1}
              style={[textStyles.footnote, { color: colors.textSecondary }]}>
              {t('settings.destinations.account')}
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
    <View style={[styles.card, { backgroundColor: colors.fillQuiet }]}>
      <AccountMonogram
        name={name}
        size={settingsColumns ? 55 : 62}
      />
      <View style={styles.rowText}>
        <Text style={[type.page, { color: colors.textPrimary }]}>{name}</Text>
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

// A row: an optional icon, the title and its subtitle, then its trailing controls.
export function SettingsRow({
  icon,
  title,
  subtitle,
  subtitleTone,
  children,
}: {
  readonly icon?: string;
  readonly title: string;
  readonly subtitle?: string | undefined;
  // A subtitle reporting a problem takes the warning color.
  readonly subtitleTone?: 'warning' | undefined;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View style={styles.row}>
      <Hairline />
      {icon === undefined ? null : (
        <SFSymbol
          name={icon}
          size={20}
          color={colors.accentInk}
        />
      )}
      <View style={styles.rowText}>
        <Text style={[type.title, { color: colors.textPrimary }]}>{title}</Text>
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
        busy={busy}
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
