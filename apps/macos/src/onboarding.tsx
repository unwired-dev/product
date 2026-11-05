import type { ReactNode } from 'react';
import type { ViewProps } from 'react-native';

import { palette, radius, spacing } from '@private-email/mail-core/theme';
import { useEffect, useMemo, useState } from 'react';
import {
  Animated,
  Easing,
  Pressable,
  requireNativeComponent,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import {
  Button,
  ModalBackground,
  SFSymbol,
  useReducedMotion,
} from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  page: { flex: 1 },
  // The frame's 420pt block, from the seal to Continue, sits 20pt below the window's centre; the
  // top padding also balances Privacy & Data (44pt) hanging below it.
  welcome: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingHorizontal: 160,
    paddingTop: 124,
    paddingBottom: 40,
  },
  welcomeContent: { maxWidth: 520 },
  seal: { width: 18, height: 18, borderRadius: 9, marginBottom: 24 },
  headline: {
    fontSize: 52,
    lineHeight: 58,
    fontWeight: '400',
    letterSpacing: -1.04,
  },
  // The frame's 520pt lede in its untracked SF Pro: AppKit tracks 15pt text tighter, so tracking
  // restores the frame's widths, and 500pt keeps its line breaks.
  lede: {
    maxWidth: 500,
    fontSize: 15,
    lineHeight: 20,
    letterSpacing: 0.23,
    marginTop: spacing.xl,
    opacity: 0.78,
  },
  status: { fontSize: 15, lineHeight: 20, opacity: 0.78 },
  // Launch progress takes the headline's place; Welcome's content stays laid out beneath it.
  restoringStatus: { position: 'absolute', top: 0, left: 0, right: 0 },
  hidden: { opacity: 0 },
  privacy: {
    minHeight: 44,
    justifyContent: 'center',
    alignItems: 'center',
    outlineWidth: 2,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  points: { marginTop: 36, marginBottom: 28 },
  // A 20pt line and 14pt below it, as each of the frame's 34pt rows.
  point: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    paddingBottom: 14,
  },
  // The frame's symbols are 70% of the label's ink.
  pointIcon: { opacity: 0.7 },
  // AppKit tracks 15pt SF Pro tighter than the frame's untracked labels; this restores their
  // measured widths.
  pointText: {
    fontSize: 15,
    lineHeight: 20,
    letterSpacing: 0.22,
    opacity: 0.85,
  },
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
  // The form keeps the frame's place, 200pt into its pane and 250pt down; anything the page adds
  // follows below it.
  form: { flexGrow: 1, paddingLeft: 200, paddingTop: 250, paddingBottom: 40 },
  formContent: { width: 341, gap: spacing.m },
  formActions: { width: 320, gap: spacing.m },
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
    outlineWidth: 2,
  },
  apple: { height: 40 },
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
  providerFocus: {
    borderWidth: 2,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
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

// While launch reads the saved account, the seal breathes and the status arrives after a moment, so
// a quick launch shows only the seal. Reduce Motion keeps the seal still, following changes.
function useRestoringMotion(restoring: boolean) {
  const seal = useMemo(() => new Animated.Value(1), []);
  const status = useMemo(() => new Animated.Value(0), []);
  const reduced = useReducedMotion();
  useEffect(() => {
    if (!restoring) {
      return undefined;
    }
    const arriving = Animated.timing(status, {
      toValue: 1,
      duration: 200,
      delay: 600,
      easing: easeOut,
      useNativeDriver: true,
    });
    arriving.start();
    return () => {
      arriving.stop();
    };
  }, [restoring, status]);
  useEffect(() => {
    if (!restoring || reduced) {
      return undefined;
    }
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
    breathing.start();
    return () => {
      breathing.stop();
      seal.setValue(1);
    };
  }, [restoring, reduced, seal]);
  return { seal, status };
}

// Launch shows this until it has read the saved account, then Welcome, setup or the Inbox (#1070).
// It lays out as Welcome, so the seal stays in place when Welcome follows.
export function Restoring() {
  return (
    <Welcome
      restoring
      onContinue={() => undefined}
      // Welcome always offers Privacy & Data, which shapes its layout.
      onPrivacy={() => undefined}
    />
  );
}

// The brand moment before signing in: deep graphite with the cinnabar seal and its one action.
export function Welcome({
  onContinue,
  onPrivacy,
  restoring = false,
}: {
  readonly onContinue: () => void;
  readonly onPrivacy?: () => void;
  // Launch progress: only the seal and its status show, where the seal and headline will be.
  readonly restoring?: boolean;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const motion = useRestoringMotion(restoring);
  const [privacyFocused, setPrivacyFocused] = useState(false);
  const ink = { color: colors.brandOnDeep };
  const concealed = restoring ? styles.hidden : undefined;
  // Each symbol takes its own width, as in the frame. tray.2 is wider than the 1.25× cap on a
  // symbol's size, so at 13pt its ink is the frame's 14.4pt.
  const points = [
    {
      icon: 'lock.fill',
      size: 13,
      width: 12.2,
      text: t('onboarding.welcome.assistance'),
    },
    {
      icon: 'tray.2',
      size: 13,
      width: 18,
      text: t('onboarding.welcome.mailProfiles'),
    },
    {
      icon: 'arrow.clockwise',
      size: 13,
      width: 13.4,
      text: t('onboarding.welcome.privateSync'),
    },
  ];
  return (
    <ScrollView
      {...(restoring && {
        accessible: true,
        accessibilityRole: 'progressbar',
        accessibilityLabel: t('onboarding.restoring'),
        pointerEvents: 'none',
      })}
      contentContainerStyle={styles.welcome}
      scrollEnabled={!restoring}
      style={[styles.page, { backgroundColor: colors.brandDeep }]}>
      <View style={styles.welcomeContent}>
        <Animated.View
          style={[
            styles.seal,
            { backgroundColor: colors.brandSeal, opacity: motion.seal },
          ]}
        />
        <View>
          <ModalBackground
            accessibilityElementsHidden={restoring}
            style={concealed}>
            <Label
              accessibilityRole="header"
              style={[styles.headline, ink]}>
              {t('onboarding.welcome.title')}
            </Label>
            <Label style={[styles.lede, ink]}>
              {t('onboarding.welcome.description')}
            </Label>
            <View style={styles.points}>
              {points.map(({ icon, size, width, text }) => (
                <View
                  key={icon}
                  style={styles.point}>
                  {/* A plain view takes the opacity once; the native symbol view would apply it
                      twice. */}
                  <View style={styles.pointIcon}>
                    <SFSymbol
                      name={icon}
                      size={size}
                      color={colors.brandOnDeep}
                      style={{ width, height: 20 }}
                    />
                  </View>
                  <Label style={[styles.pointText, ink]}>{text}</Label>
                </View>
              ))}
            </View>
            <View style={styles.continue}>
              <Button
                disabled={restoring}
                fill="brand"
                label={t('onboarding.welcome.continue')}
                onPress={onContinue}
              />
            </View>
            {onPrivacy === undefined ? null : (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={t('settings.destinations.privacy')}
                disabled={restoring}
                enableFocusRing={false}
                onBlur={() => {
                  setPrivacyFocused(false);
                }}
                onFocus={() => {
                  setPrivacyFocused(true);
                }}
                onPress={onPrivacy}
                focusable={!restoring}
                style={({ pressed }) => [
                  styles.continue,
                  styles.privacy,
                  // On the deep page the focus ring takes the page's ink, as the Outbox toast's does,
                  // and the pressed fill the Dark value, the page being deep in both appearances.
                  {
                    outlineColor: privacyFocused
                      ? colors.brandOnDeep
                      : 'transparent',
                  },
                  pressed && {
                    backgroundColor: palette.dark.accentSelectionSubtle,
                  },
                ]}>
                <Text style={[textStyles.body, ink]}>
                  {t('settings.destinations.privacy')}
                </Text>
              </Pressable>
            )}
          </ModalBackground>
          {restoring ? (
            <Animated.View
              style={[styles.restoringStatus, { opacity: motion.status }]}>
              <Text style={[styles.status, ink]}>
                {t('onboarding.restoring')}
              </Text>
            </Animated.View>
          ) : null}
        </View>
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
          <View style={styles.formActions}>{actions}</View>
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

// A sign-in action, as tall as the Sign in with Apple button beside it.
export function OnboardingAction({
  label,
  onPress,
  disabled = false,
}: {
  readonly label: string;
  readonly onPress: () => void;
  readonly disabled?: boolean;
}) {
  const colors = usePalette();
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      enableFocusRing={false}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.action,
        {
          borderWidth: 1,
          borderColor: colors.separator,
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : colors.fillQuiet,
          opacity: disabled ? 0.4 : 1,
          outlineColor: focused && !disabled ? colors.accentInk : 'transparent',
        },
      ]}>
      <Text style={[textStyles.body, { color: colors.textPrimary }]}>
        {label}
      </Text>
    </Pressable>
  );
}

const NativeAppleIDButton = requireNativeComponent<
  ViewProps & { readonly enabled: boolean; readonly onPress: () => void }
>('UnwiredAppleIDButton');

// The system Sign in with Apple button, which draws its own title, appearance and accessibility.
export function SignInWithApple({
  onPress,
  disabled,
}: {
  readonly onPress: () => void;
  readonly disabled: boolean;
}) {
  return (
    <NativeAppleIDButton
      enabled={!disabled}
      onPress={onPress}
      style={styles.apple}
      testID="sign-in-with-apple"
    />
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
  const [focused, setFocused] = useState(false);
  return (
    <Pressable
      accessibilityHint={detail}
      accessibilityLabel={name}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      enableFocusRing={false}
      focusable
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
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
      {/* The 2pt accent/ink focus ring, drawn over the row so its layout holds. */}
      {focused ? (
        <View
          pointerEvents="none"
          style={[
            StyleSheet.absoluteFill,
            styles.providerFocus,
            { borderColor: colors.accentInk },
          ]}
        />
      ) : null}
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
