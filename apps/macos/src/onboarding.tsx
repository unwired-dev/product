import type { ReactNode } from 'react';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useMemo } from 'react';
import {
  AccessibilityInfo,
  Animated,
  Easing,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  page: { flex: 1 },
  welcome: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingHorizontal: 160,
    paddingVertical: 40,
  },
  welcomeContent: { maxWidth: 520 },
  seal: { width: 18, height: 18, borderRadius: 9, marginBottom: 24 },
  headline: { fontSize: 52, lineHeight: 58, fontWeight: '400' },
  lede: { fontSize: 15, lineHeight: 20, marginTop: spacing.xl, opacity: 0.8 },
  status: { fontSize: 15, lineHeight: 20, opacity: 0.8 },
  points: { gap: 14, marginTop: 36, marginBottom: 28 },
  point: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  pointText: { fontSize: 15, lineHeight: 16, opacity: 0.85 },
  continue: { alignSelf: 'flex-start', minWidth: 160 },
  split: { flex: 1, flexDirection: 'row' },
  brandPanel: {
    width: 480,
    justifyContent: 'flex-end',
    paddingHorizontal: 64,
    paddingBottom: 124,
  },
  sealSmall: { width: 14, height: 14, borderRadius: 7, marginBottom: 12 },
  wordmark: { fontSize: 22, lineHeight: 26 },
  tagline: { ...textStyles.body, marginTop: spacing.s, opacity: 0.85 },
  form: { flexGrow: 1, justifyContent: 'center', alignItems: 'center' },
  formContent: { width: '100%', maxWidth: 320, gap: spacing.m },
  title: { fontSize: 22, lineHeight: 26 },
  description: { ...textStyles.body },
  finePrint: { ...textStyles.subheadline, marginTop: spacing.m },
  action: {
    minHeight: 40,
    flexDirection: 'row',
    gap: spacing.s,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  appleAction: { borderRadius: 8 },
  brandAction: { minHeight: 36 },
  actionLabel: { ...textStyles.bodyEmphasized },
  appleLabel: { fontSize: 15, lineHeight: 16, fontWeight: '600' },
  providers: {
    overflow: 'hidden',
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  provider: {
    minHeight: 52,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingHorizontal: 14,
    paddingVertical: 10,
  },
  tile: {
    width: 28,
    height: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.row,
    borderCurve: 'continuous',
  },
  tileLetter: { ...textStyles.bodyEmphasized },
  providerText: { flex: 1, gap: 1 },
  providerName: { ...textStyles.bodyEmphasized },
  providerDetail: { ...textStyles.subheadline },
  card: {
    gap: spacing.m,
    padding: 28,
    borderRadius: radius.alertMac,
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
  cardTitle: { ...textStyles.title3Emphasized, textAlign: 'center' },
  cardDescription: { ...textStyles.body, textAlign: 'center' },
});

// CSS ease-in-out and ease-out, as the mobile host's Restoring animation uses.
const easeInOut = Easing.bezier(0.42, 0, 0.58, 1);
const easeOut = Easing.bezier(0, 0, 0.58, 1);

// Launch shows this until it has read the saved account, then Welcome, setup or the Inbox (#1070).
// The seal breathes and the status arrives after a moment, so a quick launch shows only the seal.
export function Restoring() {
  const colors = usePalette();
  const { t } = useLocalization();
  const seal = useMemo(() => new Animated.Value(1), []);
  const status = useMemo(() => new Animated.Value(0), []);
  useEffect(() => {
    let current = true;
    const breathing = Animated.loop(
      Animated.sequence(
        [0.35, 1].map((toValue) =>
          Animated.timing(seal, {
            toValue,
            duration: 800,
            easing: easeInOut,
            useNativeDriver: true,
          }),
        ),
      ),
    );
    const arriving = Animated.timing(status, {
      toValue: 1,
      duration: 200,
      delay: 600,
      easing: easeOut,
      useNativeDriver: true,
    });
    arriving.start();
    const breathe = async () => {
      if (!(await AccessibilityInfo.isReduceMotionEnabled()) && current) {
        breathing.start();
      }
    };
    void breathe();
    return () => {
      current = false;
      breathing.stop();
      arriving.stop();
    };
  }, [seal, status]);
  return (
    <View
      accessible
      accessibilityRole="progressbar"
      accessibilityLabel={t('onboarding.restoring')}
      style={[
        styles.page,
        styles.welcome,
        { backgroundColor: colors.brandDeep },
      ]}>
      <View style={styles.welcomeContent}>
        <Animated.View
          style={[
            styles.seal,
            { backgroundColor: colors.brandSeal, opacity: seal },
          ]}
        />
        <Animated.View style={{ opacity: status }}>
          <Label style={[styles.status, { color: colors.brandOnDeep }]}>
            {t('onboarding.restoring')}
          </Label>
        </Animated.View>
      </View>
    </View>
  );
}

// The brand moment before signing in: deep graphite with the cinnabar seal and its one action.
export function Welcome({
  onContinue,
  onPrivacy,
}: {
  readonly onContinue: () => void;
  readonly onPrivacy?: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const ink = { color: colors.brandOnDeep };
  const points = [
    { icon: 'lock.fill', text: t('onboarding.welcome.assistance') },
    { icon: 'arrow.clockwise', text: t('onboarding.welcome.privateSync') },
  ];
  return (
    <ScrollView
      contentContainerStyle={styles.welcome}
      style={[styles.page, { backgroundColor: colors.brandDeep }]}>
      <View style={styles.welcomeContent}>
        <View style={[styles.seal, { backgroundColor: colors.brandSeal }]} />
        <Label
          accessibilityRole="header"
          style={[styles.headline, ink]}>
          {t('onboarding.welcome.title')}
        </Label>
        <Label style={[styles.lede, ink]}>
          {t('onboarding.welcome.description')}
        </Label>
        <View style={styles.points}>
          {points.map(({ icon, text }) => (
            <View
              key={icon}
              style={styles.point}>
              <SFSymbol
                name={icon}
                size={13}
                color={colors.brandOnDeep}
              />
              <Label style={[styles.pointText, ink]}>{text}</Label>
            </View>
          ))}
        </View>
        <View style={styles.continue}>
          <OnboardingAction
            fill="brand"
            label={t('onboarding.welcome.continue')}
            onPress={onContinue}
          />
        </View>
        {onPrivacy === undefined ? null : (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel={t('settings.destinations.privacy')}
            onPress={onPrivacy}
            focusable
            style={[
              styles.continue,
              {
                minHeight: 44,
                justifyContent: 'center',
                alignItems: 'center',
              },
            ]}>
            <Text style={[textStyles.body, ink]}>
              {t('settings.destinations.privacy')}
            </Text>
          </Pressable>
        )}
      </View>
    </ScrollView>
  );
}

// Signing in, with the brand panel beside the form.
export function SignIn({
  title,
  description,
  actions,
  children,
}: {
  readonly title: string;
  readonly description: string;
  // The sign-in actions and their fine print.
  readonly actions: ReactNode;
  // Anything the page keeps below them, such as the language choice.
  readonly children?: ReactNode;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <View style={[styles.split, { backgroundColor: colors.surfaceContent }]}>
      <View style={[styles.brandPanel, { backgroundColor: colors.brandDeep }]}>
        <View
          style={[styles.sealSmall, { backgroundColor: colors.brandSeal }]}
        />
        <Label style={[styles.wordmark, { color: colors.brandOnDeep }]}>
          {t('onboarding.brand.name')}
        </Label>
        <Label style={[styles.tagline, { color: colors.brandOnDeep }]}>
          {t('onboarding.brand.tagline')}
        </Label>
      </View>
      <ScrollView contentContainerStyle={styles.form}>
        <View style={styles.formContent}>
          <Label
            accessibilityRole="header"
            style={[styles.title, { color: colors.textPrimary }]}>
            {title}
          </Label>
          <Label style={[styles.description, { color: colors.textSecondary }]}>
            {description}
          </Label>
          <View style={{ height: spacing.l }} />
          {actions}
          {children}
        </View>
      </ScrollView>
    </View>
  );
}

// The fine print under the sign-in actions.
export function FinePrint({ children }: { readonly children: string }) {
  const colors = usePalette();
  return (
    <Label style={[styles.finePrint, { color: colors.textSecondary }]}>
      {children}
    </Label>
  );
}

// An onboarding action: Welcome's brand Continue, Sign in with Apple's black, or quiet.
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
    brand: [
      colors.brandSeal,
      colors.brandOnSeal,
      styles.brandAction,
      styles.actionLabel,
    ],
    apple: [
      colors.appleButton,
      colors.appleOnButton,
      styles.appleAction,
      styles.appleLabel,
    ],
    quiet: [colors.fillQuiet, colors.textPrimary, undefined, textStyles.body],
  } as const;
  const [background, ink, shape, type] = fills[fill];
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      focusable
      onPress={onPress}
      style={[
        styles.action,
        shape,
        { backgroundColor: background, opacity: disabled ? 0.4 : 1 },
      ]}>
      {fill === 'apple' ? (
        <SFSymbol
          name="apple.logo"
          color={ink}
        />
      ) : null}
      <Text style={[type, { color: ink }]}>{label}</Text>
    </Pressable>
  );
}

// A group of mailbox providers, each a row that opens its own setup.
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
      focusable
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
        size={11}
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
        <Label
          accessibilityRole="header"
          style={[styles.cardTitle, { color: colors.textPrimary }]}>
          {title}
        </Label>
        {description === undefined ? null : (
          <Label
            style={[styles.cardDescription, { color: colors.textSecondary }]}>
            {description}
          </Label>
        )}
      </View>
      {children}
    </View>
  );
}
