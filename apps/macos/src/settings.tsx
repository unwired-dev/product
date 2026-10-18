import type { ReactNode } from 'react';

import { radius, spacing } from '@private-email/mail-core/theme';
import { Fragment, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { Glass, SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

// The Settings destinations this client supports; the others follow their owning issues.
export type SettingsDestination =
  | 'account'
  | 'mailboxes'
  | 'language'
  | 'privacy'
  | 'errorReporting';

// The sidebar's groups below the account item, in the design's order.
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

// A push button in a Settings row; `title` is its visible text when the label names its target.
export type SettingsButton = (
  label: string,
  action: () => Promise<void>,
  options?: Readonly<{ title?: string; tone?: 'destructive' | undefined }>,
) => ReactNode;

const styles = StyleSheet.create({
  window: { flex: 1, flexDirection: 'row' },
  sidebar: {
    width: 216,
    margin: spacing.s,
    marginRight: 0,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  sidebarList: { padding: spacing.s },
  account: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    minHeight: 44,
    paddingHorizontal: spacing.s,
    paddingVertical: 6,
    borderWidth: 1,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  sectionHeader: {
    ...textStyles.subheadline,
    fontWeight: '600',
    paddingHorizontal: spacing.s,
    paddingTop: 10,
    paddingBottom: spacing.xs,
  },
  item: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 28,
    paddingHorizontal: spacing.s,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  itemText: { flex: 1 },
  detail: { flex: 1 },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: 22,
    paddingHorizontal: spacing.xl,
    paddingBottom: spacing.xl,
  },
  content: {
    gap: spacing.s,
    paddingLeft: spacing.xl,
    paddingRight: 24,
    paddingBottom: spacing.xl,
    maxWidth: 680,
  },
  groupHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingTop: 10,
    paddingHorizontal: spacing.m,
  },
  cells: { marginTop: -StyleSheet.hairlineWidth },
  group: {
    overflow: 'hidden',
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    minHeight: 40,
    paddingHorizontal: spacing.m,
    paddingVertical: 10,
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
    paddingHorizontal: spacing.m,
    paddingVertical: 10,
  },
  separator: {
    position: 'absolute',
    top: 0,
    left: spacing.m,
    right: spacing.m,
    height: StyleSheet.hairlineWidth,
  },
  footer: { paddingHorizontal: spacing.m },
  monogram: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    paddingHorizontal: spacing.l,
    paddingVertical: 14,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  button: {
    minHeight: 28,
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
          size > 40 ? textStyles.title3Emphasized : textStyles.bodyEmphasized,
          { color: colors.brandOnDeep },
        ]}>
        {[...name][0]?.toLocaleUpperCase() ?? ''}
      </Text>
    </View>
  );
}

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
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.item,
        (selected || pressed) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
        { borderColor: focused ? colors.accentInk : 'transparent' },
      ]}>
      <SFSymbol
        name={icon}
        color={colors.accentInk}
      />
      <Text
        numberOfLines={1}
        style={[
          selected ? textStyles.bodyEmphasized : textStyles.body,
          styles.itemText,
          { color: colors.textPrimary },
        ]}>
        {label}
      </Text>
    </Pressable>
  );
}

// The Settings layout: the glass sidebar of destinations beside the selected destination's form.
export function SettingsWindow({
  account,
  destination,
  onDestination,
  accessory,
  onWelcome,
  children,
}: {
  // The Product Account the account item names.
  readonly account: string;
  readonly destination: SettingsDestination;
  readonly onDestination: (destination: SettingsDestination) => void;
  // Shown beside the destination's title, such as an activity indicator.
  readonly accessory?: ReactNode;
  readonly onWelcome?: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [accountFocused, setAccountFocused] = useState(false);
  const selected = destination === 'account';
  return (
    <View style={styles.window}>
      <View style={[styles.sidebar, { boxShadow: colors.largeGlassShadow }]}>
        <Glass cornerRadius={18} />
        <ScrollView contentContainerStyle={styles.sidebarList}>
          {onWelcome === undefined ? (
            <>
              <Pressable
                accessibilityLabel={t('settings.destinations.account')}
                accessibilityRole="button"
                accessibilityState={{ selected }}
                focusable
                onBlur={() => {
                  setAccountFocused(false);
                }}
                onFocus={() => {
                  setAccountFocused(true);
                }}
                onPress={() => {
                  onDestination('account');
                }}
                style={({ pressed }) => [
                  styles.account,
                  (selected || pressed) && {
                    backgroundColor: colors.accentSelectionSubtle,
                  },
                  {
                    borderColor: accountFocused
                      ? colors.accentInk
                      : 'transparent',
                  },
                ]}>
                <AccountMonogram
                  name={account}
                  size={32}
                />
                <View style={styles.itemText}>
                  <Text
                    numberOfLines={1}
                    style={[
                      textStyles.bodyEmphasized,
                      { color: colors.textPrimary },
                    ]}>
                    {account}
                  </Text>
                  <Text
                    numberOfLines={1}
                    style={[
                      textStyles.subheadline,
                      { color: colors.textSecondary },
                    ]}>
                    {t('settings.destinations.account')}
                  </Text>
                </View>
              </Pressable>
              {sections.map((section) => (
                <Fragment key={section.title}>
                  <Label
                    accessibilityRole="header"
                    style={[
                      styles.sectionHeader,
                      { color: colors.textSecondary },
                    ]}>
                    {t(`settings.sections.${section.title}`)}
                  </Label>
                  {section.items.map((item) => (
                    <SidebarItem
                      key={item.id}
                      icon={item.icon}
                      label={t(`settings.destinations.${item.id}`)}
                      selected={
                        destination === item.id ||
                        (destination === 'errorReporting' &&
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
      <ScrollView
        style={[styles.detail, { backgroundColor: colors.surfaceContent }]}>
        <View style={styles.titleRow}>
          <Label
            accessibilityRole="header"
            style={[
              textStyles.title3Emphasized,
              { color: colors.textPrimary },
            ]}>
            {t(
              `settings.destinations.${onWelcome === undefined ? destination : 'privacy'}`,
            )}
          </Label>
          {accessory}
        </View>
        <View style={styles.content}>{children}</View>
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
        size={48}
      />
      <View style={styles.rowText}>
        <Label
          style={[textStyles.title3Emphasized, { color: colors.textPrimary }]}>
          {name}
        </Label>
        <Label style={[textStyles.body, { color: colors.textSecondary }]}>
          {detail}
        </Label>
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
}: {
  readonly title?: string | undefined;
  // Beside the title, such as the On device marker.
  readonly accessory?: ReactNode;
  readonly footer?: string | undefined;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <>
      {title === undefined ? null : (
        <View style={styles.groupHeader}>
          <Label
            accessibilityRole="header"
            style={[
              textStyles.subheadline,
              { fontWeight: '600', color: colors.textSecondary },
            ]}>
            {title}
          </Label>
          {accessory}
        </View>
      )}
      {children === undefined || children === null ? null : (
        <View style={[styles.group, { backgroundColor: colors.fillQuiet }]}>
          {/* Each cell draws a hairline above itself; this hides the first one. */}
          <View style={styles.cells}>{children}</View>
        </View>
      )}
      {footer === undefined ? null : (
        <View style={styles.footer}>
          <Label
            style={[textStyles.subheadline, { color: colors.textSecondary }]}>
            {footer}
          </Label>
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
          color={colors.accentInk}
        />
      )}
      <View style={styles.rowText}>
        <Label style={[textStyles.body, { color: colors.textPrimary }]}>
          {title}
        </Label>
        {subtitle === undefined ? null : (
          <Label
            style={[
              textStyles.subheadline,
              {
                color:
                  subtitleTone === 'warning'
                    ? colors.statusWarning
                    : colors.textSecondary,
              },
            ]}>
            {subtitle}
          </Label>
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
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled: busy }}
      disabled={busy}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          alignSelf: 'flex-start',
          backgroundColor:
            tone === 'destructive' ? 'transparent' : colors.fillQuiet,
          borderWidth: 2,
          borderColor: focused ? colors.accentInk : 'transparent',
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
            textStyles.body,
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
