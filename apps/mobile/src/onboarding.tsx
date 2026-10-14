import type { ReactNode } from 'react';

import { radius, spacing } from '@private-email/mail-core/theme';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const ipad = Platform.OS === 'ios' && Platform.isPad;

const styles = StyleSheet.create({
  page: { flex: 1 },
  welcome: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingHorizontal: ipad ? 96 : 24,
    paddingVertical: spacing.l,
  },
  welcomeContent: { maxWidth: 520, gap: 14 },
  seal: { width: 18, height: 18, borderRadius: 9 },
  headline: { fontSize: 40, lineHeight: 46, fontWeight: '700' },
  lede: { ...textStyles.body, opacity: 0.8 },
  points: { gap: 14, marginTop: 10, marginBottom: ipad ? 28 : 0 },
  point: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  pointText: { ...textStyles.subheadline, opacity: 0.85, flexShrink: 1 },
  footer: {
    paddingHorizontal: spacing.l,
    paddingBottom: spacing.l,
    gap: spacing.m,
  },
  split: {
    flex: 1,
    flexDirection: 'row',
    gap: spacing.xl,
    padding: spacing.xl,
  },
  brandPanel: {
    width: '37%',
    justifyContent: 'flex-end',
    padding: 40,
    gap: spacing.s,
    borderRadius: radius.window,
    borderCurve: 'continuous',
  },
  sealSmall: { width: 14, height: 14, borderRadius: 7 },
  wordmark: { fontSize: 22, lineHeight: 26 },
  tagline: { ...textStyles.footnote, opacity: 0.85 },
  form: { flexGrow: 1, justifyContent: 'center', alignItems: 'center' },
  formContent: { width: '100%', maxWidth: 340, gap: spacing.m },
  compactForm: { flexGrow: 1, paddingHorizontal: 24, paddingTop: 40, gap: 10 },
  back: {
    width: 44,
    height: 44,
    marginLeft: spacing.l,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 22,
  },
  title: { ...textStyles.largeTitle },
  regularTitle: { fontSize: 22, lineHeight: 26 },
  description: { ...textStyles.body },
  regularDescription: { ...textStyles.subheadline },
  finePrint: { ...textStyles.footnote, textAlign: 'center' },
  action: {
    minHeight: 52,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.l,
    borderRadius: 26,
    borderCurve: 'continuous',
  },
  regularAction: { minHeight: 44, borderRadius: radius.control },
  actionLabel: { ...textStyles.headline },
  providers: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  provider: {
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.m,
  },
  tile: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 9,
    borderCurve: 'continuous',
  },
  tileLetter: { ...textStyles.headline },
  providerText: { flex: 1, gap: 1 },
  providerName: { ...textStyles.body },
  providerDetail: { ...textStyles.footnote },
  card: {
    gap: spacing.m,
    padding: 28,
    borderRadius: radius.alertTouch,
    borderCurve: 'continuous',
  },
  cardHeader: { alignItems: 'center', gap: spacing.m },
  iconTile: {
    width: 56,
    height: 56,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 14,
    borderCurve: 'continuous',
  },
  cardTitle: { ...textStyles.headline, textAlign: 'center' },
  cardDescription: { ...textStyles.subheadline, textAlign: 'center' },
});

// The brand moment before signing in: deep graphite with the cinnabar seal and its one action.
export function Welcome({ onContinue }: { readonly onContinue: () => void }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const insets = useSafeAreaInsets();
  const ink = { color: colors.brandOnDeep };
  const points = [
    { icon: 'lock.fill', text: t('onboarding.welcome.assistance') },
    { icon: 'arrow.clockwise', text: t('onboarding.welcome.privateSync') },
  ];
  const action = (
    <OnboardingAction
      fill="brand"
      label={t('onboarding.welcome.continue')}
      onPress={onContinue}
    />
  );
  return (
    <View
      style={[
        styles.page,
        {
          backgroundColor: colors.brandDeep,
          paddingTop: insets.top,
          paddingBottom: insets.bottom,
        },
      ]}>
      <ScrollView contentContainerStyle={styles.welcome}>
        <View style={styles.welcomeContent}>
          <View style={[styles.seal, { backgroundColor: colors.brandSeal }]} />
          <Text
            accessibilityRole="header"
            style={[styles.headline, ink]}>
            {t('onboarding.welcome.title')}
          </Text>
          <Text style={[styles.lede, ink]}>
            {t('onboarding.welcome.description')}
          </Text>
          <View style={styles.points}>
            {points.map(({ icon, text }) => (
              <View
                key={icon}
                style={styles.point}>
                <SFSymbol
                  name={icon}
                  color={colors.brandOnDeep}
                />
                <Text style={[styles.pointText, ink]}>{text}</Text>
              </View>
            ))}
          </View>
          {ipad ? (
            <View style={{ alignSelf: 'flex-start', minWidth: 160 }}>
              {action}
            </View>
          ) : null}
        </View>
      </ScrollView>
      {ipad ? null : <View style={styles.footer}>{action}</View>}
    </View>
  );
}

// Signing in: iPad keeps the brand panel beside the form, iPhone a single column whose sign-in
// actions sit at the bottom. `onBack` returns to Welcome where it came from.
export function SignIn({
  title,
  description,
  onBack,
  actions,
  children,
}: {
  readonly title: string;
  readonly description: string;
  readonly onBack: (() => void) | undefined;
  // The sign-in actions and their fine print.
  readonly actions: ReactNode;
  // Anything the page keeps below them, such as the language choice.
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const insets = useSafeAreaInsets();
  const heading = (
    <>
      <Text
        accessibilityRole="header"
        style={[
          ipad ? styles.regularTitle : styles.title,
          { color: colors.textPrimary },
        ]}>
        {title}
      </Text>
      <Text
        style={[
          ipad ? styles.regularDescription : styles.description,
          { color: colors.textSecondary },
        ]}>
        {description}
      </Text>
    </>
  );
  if (ipad) {
    return (
      <View
        style={[
          styles.split,
          {
            backgroundColor: colors.surfaceContent,
            paddingTop: insets.top + spacing.xl,
            paddingBottom: insets.bottom + spacing.xl,
          },
        ]}>
        <View
          style={[styles.brandPanel, { backgroundColor: colors.brandDeep }]}>
          <View
            style={[styles.sealSmall, { backgroundColor: colors.brandSeal }]}
          />
          <Text style={[styles.wordmark, { color: colors.brandOnDeep }]}>
            {t('onboarding.brand.name')}
          </Text>
          <Text style={[styles.tagline, { color: colors.brandOnDeep }]}>
            {t('onboarding.brand.tagline')}
          </Text>
        </View>
        <ScrollView contentContainerStyle={styles.form}>
          <View style={styles.formContent}>
            {heading}
            <View style={{ height: spacing.l }} />
            {actions}
            {children}
          </View>
        </ScrollView>
      </View>
    );
  }
  return (
    <View
      style={[
        styles.page,
        {
          backgroundColor: colors.surfaceContent,
          paddingTop: insets.top + spacing.s,
          paddingBottom: insets.bottom,
        },
      ]}>
      {onBack === undefined ? null : (
        <Pressable
          accessibilityLabel={t('onboarding.back')}
          accessibilityRole="button"
          onPress={onBack}
          style={[styles.back, { backgroundColor: colors.fillQuiet }]}>
          <SFSymbol
            name="chevron.left"
            color={colors.textPrimary}
          />
        </Pressable>
      )}
      <ScrollView contentContainerStyle={styles.compactForm}>
        {heading}
        {children}
      </ScrollView>
      <View style={styles.footer}>{actions}</View>
    </View>
  );
}

// The fine print under the sign-in actions.
export function FinePrint({ children }: { readonly children: string }) {
  const colors = usePalette();
  return (
    <Text style={[styles.finePrint, { color: colors.textSecondary }]}>
      {children}
    </Text>
  );
}

// A full-width onboarding action: Welcome's brand Continue, Sign in with Apple's black, or quiet.
export function OnboardingAction({
  label,
  onPress,
  fill,
  disabled = false,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly fill: 'brand' | 'apple' | 'quiet';
  readonly disabled?: boolean;
}) {
  const colors = usePalette();
  const fills = {
    brand: [colors.brandSeal, colors.brandOnSeal],
    apple: [colors.appleButton, colors.appleOnButton],
    quiet: [colors.fillQuiet, colors.textPrimary],
  } as const;
  const [background, ink] = fills[fill];
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.action,
        ipad && styles.regularAction,
        { backgroundColor: background, opacity: disabled ? 0.4 : 1 },
      ]}>
      <Text style={[styles.actionLabel, { color: ink }]}>{label}</Text>
    </Pressable>
  );
}

// An inset group of mailbox providers, each a row that opens its own setup.
export function ProviderList({ children }: { readonly children: ReactNode }) {
  const colors = usePalette();
  return (
    <View style={[styles.providers, { backgroundColor: colors.fillQuiet }]}>
      {children}
    </View>
  );
}

export function ProviderRow({
  letter,
  name,
  detail,
  onPress,
  disabled,
  last = false,
}: {
  // The provider's initial on its tile, as the design draws it.
  readonly letter: string;
  readonly name: string;
  readonly detail: string;
  readonly onPress: () => void;
  readonly disabled: boolean;
  readonly last?: boolean;
}) {
  const colors = usePalette();
  return (
    <Pressable
      accessibilityHint={detail}
      accessibilityLabel={name}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.provider,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
          borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth,
          borderBottomColor: colors.separator,
        },
      ]}>
      <View style={[styles.tile, { backgroundColor: colors.surfaceContent }]}>
        <Text style={[styles.tileLetter, { color: colors.textPrimary }]}>
          {letter}
        </Text>
      </View>
      <View style={styles.providerText}>
        <Text style={[styles.providerName, { color: colors.textPrimary }]}>
          {name}
        </Text>
        <Text style={[styles.providerDetail, { color: colors.textSecondary }]}>
          {detail}
        </Text>
      </View>
      <SFSymbol
        name="chevron.right"
        size={12}
        color={colors.textSecondary}
      />
    </Pressable>
  );
}

// An account or device-trust step as an alert-style card: an icon tile, a centered title and
// description, then the step's fields and actions.
export function TrustCard({
  icon,
  title,
  description,
  children,
}: {
  readonly icon: string;
  readonly title: string;
  readonly description: string | undefined;
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  return (
    <View
      style={[
        styles.card,
        {
          backgroundColor: colors.surfaceContent,
          boxShadow: colors.menuShadow,
        },
      ]}>
      <View style={styles.cardHeader}>
        <View style={[styles.iconTile, { backgroundColor: colors.fillQuiet }]}>
          <SFSymbol
            name={icon}
            size={24}
            color={colors.textPrimary}
          />
        </View>
        <Text
          accessibilityRole="header"
          style={[styles.cardTitle, { color: colors.textPrimary }]}>
          {title}
        </Text>
        {description === undefined ? null : (
          <Text
            style={[styles.cardDescription, { color: colors.textSecondary }]}>
            {description}
          </Text>
        )}
      </View>
      {children}
    </View>
  );
}
