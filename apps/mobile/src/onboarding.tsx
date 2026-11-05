import type { ReactNode } from 'react';

import {
  ipadListScale,
  palette,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { useState } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import Animated, { css } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Glass, SFSymbol, useReducedMotion } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const ipad = Platform.OS === 'ios' && Platform.isPad;
const phone = Platform.OS === 'ios' && !Platform.isPad;
// The frames' 17.25/23 Title 3 is set without the system font's own -0.43pt tracking at that size.
const ipadTitle3 = { fontSize: 17.25, lineHeight: 23, letterSpacing: 0.43 };
// The benefits' SF Symbols are as wide as the frames draw them, at 18.4pt on iPad and 18pt on
// iPhone, so each label follows its own symbol.
const symbolWidths: Readonly<Record<string, number>> = ipad
  ? { 'lock.fill': 14.03, 'tray.2': 20.7, 'arrow.clockwise': 15.41 }
  : { 'lock.fill': 13.725, 'tray.2': 20.25, 'arrow.clockwise': 15.075 };
// The frames' symbols draw smaller than UIKit's at their size: 14.5pt matches the iPhone frames'
// ink, and on iPad each symbol takes the size whose ink best matches its own artwork. The iPad
// tray's ink sits a point higher in its line than UIKit centres it.
const ipadPointSymbolSizes: Readonly<Partial<Record<string, number>>> = ipad
  ? { 'lock.fill': 14.5, 'tray.2': 14.4, 'arrow.clockwise': 14.25 }
  : {};
const ipadPointSymbolOffsets: Readonly<Partial<Record<string, number>>> = ipad
  ? { 'tray.2': -1 }
  : {};

const styles = StyleSheet.create({
  page: { flex: 1 },
  welcome: {
    flexGrow: 1,
    justifyContent: 'center',
    paddingHorizontal: ipad ? 140 : 24,
    paddingVertical: spacing.l,
  },
  // The iPad frames set Welcome's content 13.5pt below the centre of the safe area.
  ipadWelcome: { paddingTop: spacing.l + 2 * 13.5 },
  welcomeContent: { maxWidth: ipad ? 598 : 520, gap: 14 },
  ipadWelcomeContent: { gap: 0 },
  seal: { width: 18, height: 18, borderRadius: 9 },
  ipadSeal: {
    width: 20.7,
    height: 20.7,
    borderRadius: 10.35,
    marginBottom: 27.6,
  },
  headline: { fontSize: 40, lineHeight: 46, fontWeight: '700' },
  // The frames' -1.196pt tracking is set without the system font's own 0.25pt at that size. Its
  // ink sits 2pt higher in the line than the frames', so it moves down without moving the rest.
  ipadHeadline: {
    top: 2,
    fontSize: 59.8,
    lineHeight: 66.7,
    fontWeight: '400',
    letterSpacing: -1.196 - 0.25,
  },
  lede: { ...textStyles.body, opacity: 0.8 },
  ipadLede: {
    ...ipadTitle3,
    marginTop: 23,
    opacity: 0.78,
  },
  ipadStatus: { fontSize: 17.25, lineHeight: 23, opacity: 0.78 },
  // Launch progress takes the headline's place; Welcome's content stays laid out beneath it.
  status: { position: 'absolute', top: 0, left: 0, right: 0 },
  hidden: { opacity: 0 },
  // The frames' 10pt spacer sits between two of the content's 14pt gaps.
  points: { gap: 14, marginTop: 10 + 14, marginBottom: ipad ? 28 : 0 },
  point: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  pointText: { ...textStyles.subheadline, opacity: 0.85, flexShrink: 1 },
  // Each iPad benefit takes a 39.1pt slot: its 23pt line and 16.1pt below, then 32.2pt to Continue.
  // Its label follows the symbol's own width 13.8pt on.
  ipadPoints: { gap: 16.1, marginTop: 41.4, marginBottom: 16.1 + 32.2 },
  ipadPoint: { gap: spacing.m * ipadListScale },
  pointIcon: { alignItems: 'center' },
  ipadPointText: ipadTitle3,
  // iPad's Privacy & Data hangs below Continue, outside the frames' content.
  ipadPrivacy: { position: 'absolute', top: '100%', left: 0, right: 0 },
  footer: {
    paddingHorizontal: spacing.l,
    paddingBottom: spacing.l,
    gap: spacing.m,
  },
  // The iPhone frames end Welcome's Continue 24pt and Sign In's fine print 36pt above the home
  // indicator.
  welcomeFooter: { paddingBottom: 24 },
  signInFooter: { paddingBottom: 36 },
  split: {
    flex: 1,
    flexDirection: 'row',
    gap: spacing.xl,
    padding: spacing.l,
  },
  brandPanel: {
    width: 460,
    maxWidth: '40%',
    justifyContent: 'flex-end',
    paddingHorizontal: 64,
    paddingBottom: 124,
    gap: spacing.s,
    borderRadius: radius.brandPanel,
    borderCurve: 'continuous',
  },
  sealSmall: {
    width: 14,
    height: 14,
    borderRadius: 7,
    marginBottom: spacing.xs,
  },
  wordmark: { fontSize: 22, lineHeight: 26 },
  tagline: { ...typography.macos.body, opacity: 0.7 },
  // The frames set the form 2pt right of and 13pt above the centre of the column beside the panel.
  form: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingLeft: 2 * 2,
    paddingBottom: 2 * 13,
  },
  formContent: {
    width: '100%',
    maxWidth: 392,
    gap: spacing.m * ipadListScale,
  },
  // The iPhone frames start the heading 36pt below Back.
  compactForm: { flexGrow: 1, paddingHorizontal: 24, paddingTop: 36, gap: 10 },
  back: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 22,
  },
  // The iPhone frames set Back 4pt above the page's top padding, without moving the heading.
  backInset: {
    marginLeft: spacing.l,
    marginTop: -spacing.xs,
    marginBottom: spacing.xs,
  },
  title: { ...textStyles.largeTitle },
  regularTitle: { fontSize: 25.3, lineHeight: 29.9 },
  description: { ...textStyles.body },
  regularDescription: { ...typography.ipadList.body },
  finePrint: { ...textStyles.footnote, textAlign: 'center' },
  // iPad's fine print sits left under the 368pt actions, 41.4pt below them.
  regularFinePrint: {
    ...typography.ipadList.subheadline,
    maxWidth: 368,
    marginTop: 2 * spacing.m * ipadListScale,
  },
  action: {
    minHeight: 52,
    flexDirection: 'row',
    gap: spacing.s,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.l,
    borderRadius: 26,
    borderCurve: 'continuous',
  },
  // iPad's actions are the Mac recipe at 1.15×: Welcome's 41.4pt Continue and 46pt sign-in
  // actions 368pt wide, Sign in with Apple with its own rounder corners.
  regularAction: {
    minHeight: 36 * ipadListScale,
    borderRadius: radius.control * ipadListScale,
  },
  regularAppleAction: { borderRadius: 8 * ipadListScale },
  quietAction: { borderWidth: 1 },
  regularQuietAction: { borderWidth: ipadListScale },
  privacy: {
    minHeight: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  regularSignInAction: { minHeight: 46, maxWidth: 368 },
  actionLabel: { ...textStyles.headline },
  ipadActionLabel: { ...typography.ipadList.body },
  ipadAppleLabel: { ...typography.ipadList.title3Emphasized },
  providers: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  // iPad's providers sit in the setup sheet as the Mac's bordered list at 1.15×.
  ipadProviders: {
    borderRadius: radius.card * ipadListScale,
    borderWidth: ipadListScale,
  },
  provider: {
    minHeight: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.m,
  },
  ipadProvider: {
    minHeight: 0,
    gap: spacing.m * ipadListScale,
    paddingHorizontal: 14 * ipadListScale,
    paddingVertical: 10 * ipadListScale,
  },
  tile: {
    width: 36,
    height: 36,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 9,
    borderCurve: 'continuous',
  },
  outlinedTile: { borderWidth: 1 },
  ipadTile: {
    width: 28 * ipadListScale,
    height: 28 * ipadListScale,
    borderRadius: radius.row * ipadListScale,
  },
  tileLetter: { ...textStyles.headline },
  providerText: { flex: 1, gap: 1 },
  providerName: { ...textStyles.body },
  providerDetail: { ...textStyles.footnote },
  ipadProviderName: { ...typography.ipadList.body, fontWeight: '600' },
  ipadProviderDetail: { ...typography.ipadList.subheadline },
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
  // The brand card follows the iPhone Recovery Key frame: content 24pt from the window's edges,
  // 8pt inside the card's own 16pt inset, with 14pt gaps and a 16pt tile.
  brandCard: { gap: 14, paddingHorizontal: spacing.s, paddingVertical: 24 },
  brandCardHeader: { alignItems: 'flex-start', gap: 14 },
  brandIconTile: { borderRadius: 16 },
  cardTitle: { ...textStyles.headline, textAlign: 'center' },
  cardDescription: { ...textStyles.subheadline, textAlign: 'center' },
  brandTitle: { ...textStyles.largeTitle, textAlign: 'left' },
  brandDescription: { ...textStyles.body, textAlign: 'left' },
});

// iPhone sets Welcome's content 14pt below the safe area's centre, whatever its footer holds.
const welcomeScroll = (footer: number) =>
  ipad
    ? [styles.welcome, styles.ipadWelcome]
    : [styles.welcome, { paddingTop: spacing.l + footer + 2 * 14 }];
const assistance = phone
  ? 'onboarding.welcome.assistancePhone'
  : 'onboarding.welcome.assistance';

// While launch reads the saved account, the seal breathes and the status arrives after a moment, so
// a quick launch shows only the seal.
const motion = css.create({
  breathing: {
    animationName: { '50%': { opacity: 0.35 } },
    animationDuration: '1600ms',
    animationIterationCount: 'infinite',
    animationTimingFunction: 'ease-in-out',
  },
  arriving: {
    opacity: 0,
    animationName: { to: { opacity: 1 } },
    animationDuration: '200ms',
    animationDelay: '600ms',
    animationFillMode: 'forwards',
    animationTimingFunction: 'ease-out',
  },
});

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
  const insets = useSafeAreaInsets();
  const reduced = useReducedMotion();
  // iPhone's footer height, which Welcome's content offsets.
  const [footer, setFooter] = useState(0);
  const breathing = restoring && !reduced;
  const ink = { color: colors.brandOnDeep };
  // Welcome's own content keeps its place while launch progress shows, unseen and unreachable.
  const hidden = restoring
    ? ({
        accessibilityElementsHidden: true,
        importantForAccessibility: 'no-hide-descendants',
      } as const)
    : undefined;
  const concealed = restoring ? styles.hidden : undefined;
  const points = [
    {
      icon: 'lock.fill',
      text: t(assistance),
    },
    { icon: 'tray.2', text: t('onboarding.welcome.mailProfiles') },
    { icon: 'arrow.clockwise', text: t('onboarding.welcome.privateSync') },
  ];
  const privacy =
    onPrivacy === undefined ? null : (
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={t('settings.destinations.privacy')}
        disabled={restoring}
        focusable={!restoring}
        onPress={onPrivacy}
        // The page is deep in both appearances, so the pressed fill takes the Dark value.
        style={({ pressed }) => [
          styles.privacy,
          pressed && { backgroundColor: palette.dark.accentSelectionSubtle },
        ]}>
        <Text style={[textStyles.subheadline, ink]}>
          {t('settings.destinations.privacy')}
        </Text>
      </Pressable>
    );
  const action = (
    <>
      {ipad ? null : privacy}
      <OnboardingAction
        disabled={restoring}
        fill="brand"
        label={t('onboarding.welcome.continue')}
        onPress={onContinue}
      />
      {ipad ? <View style={styles.ipadPrivacy}>{privacy}</View> : null}
    </>
  );
  return (
    <View
      {...(restoring && {
        accessible: true,
        accessibilityRole: 'progressbar',
        accessibilityLabel: t('onboarding.restoring'),
        pointerEvents: 'none',
      })}
      style={[
        styles.page,
        {
          backgroundColor: colors.brandDeep,
          paddingTop: insets.top,
          paddingBottom: insets.bottom,
        },
      ]}>
      <ScrollView
        contentContainerStyle={welcomeScroll(footer)}
        scrollEnabled={!restoring}>
        <View
          style={[styles.welcomeContent, ipad && styles.ipadWelcomeContent]}>
          {/* A detached CSS animation can retain native opacity; replace only the seal. */}
          <Animated.View
            key={breathing ? 'breathing' : 'still'}
            style={[
              styles.seal,
              ipad && styles.ipadSeal,
              { backgroundColor: colors.brandSeal },
              breathing && motion.breathing,
            ]}
          />
          <View>
            <Text
              accessibilityRole="header"
              {...hidden}
              style={[
                styles.headline,
                ipad && styles.ipadHeadline,
                ink,
                concealed,
              ]}>
              {t('onboarding.welcome.title')}
            </Text>
            {restoring ? (
              <Animated.View style={[styles.status, motion.arriving]}>
                <Text style={[styles.lede, ipad && styles.ipadStatus, ink]}>
                  {t('onboarding.restoring')}
                </Text>
              </Animated.View>
            ) : null}
          </View>
          <Text
            {...hidden}
            style={[styles.lede, ipad && styles.ipadLede, ink, concealed]}>
            {t('onboarding.welcome.description')}
          </Text>
          <View
            {...hidden}
            style={[styles.points, ipad && styles.ipadPoints, concealed]}>
            {points.map(({ icon, text }) => (
              <View
                key={icon}
                style={[styles.point, ipad && styles.ipadPoint]}>
                <View
                  style={[
                    styles.pointIcon,
                    {
                      width: symbolWidths[icon],
                      top: ipadPointSymbolOffsets[icon],
                    },
                  ]}>
                  <SFSymbol
                    name={icon}
                    size={ipadPointSymbolSizes[icon] ?? 14.5}
                    color={`${colors.brandOnDeep}B3`}
                  />
                </View>
                <Text
                  style={[styles.pointText, ipad && styles.ipadPointText, ink]}>
                  {text}
                </Text>
              </View>
            ))}
          </View>
          {ipad ? (
            <View
              {...hidden}
              style={[{ alignSelf: 'flex-start', minWidth: 184 }, concealed]}>
              {action}
            </View>
          ) : null}
        </View>
      </ScrollView>
      {ipad ? null : (
        <View
          {...hidden}
          onLayout={({ nativeEvent }) => {
            setFooter(nativeEvent.layout.height);
          }}
          style={[styles.footer, styles.welcomeFooter, concealed]}>
          {action}
        </View>
      )}
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
  // The height of iPad's additions below the sign-in form.
  const [below, setBelow] = useState(0);
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
            paddingTop: insets.top + spacing.l,
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
            {/* Mirrors the additions below, so the frames' sign-in form stays centred. */}
            <View style={{ height: below }} />
            {heading}
            <View style={{ height: spacing.l * ipadListScale }} />
            {actions}
            <View
              style={styles.formContent}
              onLayout={({ nativeEvent }) => {
                setBelow(nativeEvent.layout.height);
              }}>
              {children}
            </View>
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
      {/* Back: a glass circle with the native glass press. */}
      {onBack === undefined ? null : (
        <Glass
          cornerRadius={22}
          interactive
          style={[
            styles.back,
            styles.backInset,
            { boxShadow: colors.smallGlassShadow },
          ]}>
          <Pressable
            accessibilityLabel={t('onboarding.back')}
            accessibilityRole="button"
            onPress={onBack}
            style={styles.back}>
            <SFSymbol
              name="chevron.left"
              color={colors.textPrimary}
            />
          </Pressable>
        </Glass>
      )}
      <ScrollView contentContainerStyle={styles.compactForm}>
        {heading}
        {children}
      </ScrollView>
      <View style={[styles.footer, styles.signInFooter]}>{actions}</View>
    </View>
  );
}

// The fine print under the sign-in actions.
export function FinePrint({ children }: { readonly children: string }) {
  const colors = usePalette();
  return (
    <Text
      style={[
        ipad ? styles.regularFinePrint : styles.finePrint,
        { color: colors.textSecondary },
      ]}>
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
    // iPhone's secondary action is outlined, with no fill.
    quiet: [ipad ? colors.fillQuiet : 'transparent', colors.textPrimary],
  } as const;
  const [background, ink] = fills[fill];
  // Pressed, the Brand and Apple fills show at 80% (CC) and the quiet fill takes the selection tint.
  const pressedFill =
    fill === 'quiet' ? colors.accentSelectionSubtle : `${background}CC`;
  return (
    <Pressable
      accessibilityLabel={label}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      focusable={!disabled}
      // iPad's 41.4pt Continue keeps a 44pt target.
      hitSlop={ipad && fill === 'brand' ? (44 - 36 * ipadListScale) / 2 : 0}
      onPress={onPress}
      style={({ pressed }) => [
        styles.action,
        ipad && styles.regularAction,
        ipad && fill !== 'brand' && styles.regularSignInAction,
        ipad && fill === 'apple' && styles.regularAppleAction,
        fill === 'quiet' && [
          ipad ? styles.regularQuietAction : styles.quietAction,
          { borderColor: colors.separator },
        ],
        {
          backgroundColor: pressed ? pressedFill : background,
          opacity: disabled ? 0.4 : 1,
        },
      ]}>
      {fill === 'apple' ? (
        <SFSymbol
          name="apple.logo"
          color={ink}
        />
      ) : null}
      <Text
        style={[
          styles.actionLabel,
          ipad &&
            (fill === 'apple' ? styles.ipadAppleLabel : styles.ipadActionLabel),
          ipad && fill === 'brand' && { fontWeight: '600' },
          { color: ink },
        ]}>
        {label}
      </Text>
    </Pressable>
  );
}

// An inset group of mailbox providers, each a row that opens its own setup.
export function ProviderList({ children }: { readonly children: ReactNode }) {
  const colors = usePalette();
  return (
    <View
      style={[
        styles.providers,
        ipad
          ? [
              styles.ipadProviders,
              {
                backgroundColor: colors.surfaceContent,
                borderColor: colors.separator,
              },
            ]
          : { backgroundColor: colors.fillQuiet },
      ]}>
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
        ipad && styles.ipadProvider,
        {
          backgroundColor: pressed
            ? colors.accentSelectionSubtle
            : 'transparent',
          borderBottomWidth: last ? 0 : StyleSheet.hairlineWidth,
          borderBottomColor: colors.separator,
        },
      ]}>
      <View
        style={[
          styles.tile,
          ipad
            ? [styles.ipadTile, { backgroundColor: colors.fillQuiet }]
            : [
                styles.outlinedTile,
                {
                  backgroundColor: colors.surfaceContent,
                  borderColor: colors.separator,
                },
              ],
        ]}>
        <Text
          style={[
            styles.tileLetter,
            ipad && styles.ipadProviderName,
            { color: colors.textPrimary },
          ]}>
          {letter}
        </Text>
      </View>
      <View style={styles.providerText}>
        <Text
          style={[
            styles.providerName,
            ipad && styles.ipadProviderName,
            { color: colors.textPrimary },
          ]}>
          {name}
        </Text>
        <Text
          style={[
            styles.providerDetail,
            ipad && styles.ipadProviderDetail,
            { color: colors.textSecondary },
          ]}>
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
  fill = 'content',
}: {
  readonly icon: string;
  readonly title: string;
  readonly description: string | undefined;
  readonly children?: ReactNode;
  readonly fill?: 'content' | 'brand';
}) {
  const colors = usePalette();
  const ink = fill === 'brand' ? colors.brandOnDeep : colors.textPrimary;
  return (
    <View
      style={[
        styles.card,
        fill === 'brand' && styles.brandCard,
        {
          backgroundColor:
            fill === 'brand' ? colors.brandDeep : colors.surfaceContent,
          boxShadow: colors.menuShadow,
        },
      ]}>
      <View
        style={[styles.cardHeader, fill === 'brand' && styles.brandCardHeader]}>
        <View
          style={[
            styles.iconTile,
            fill === 'brand' && styles.brandIconTile,
            {
              backgroundColor:
                fill === 'brand' ? palette.dark.fillQuiet : colors.fillQuiet,
            },
          ]}>
          <SFSymbol
            name={icon}
            // The brand tile's key is drawn 12×22pt.
            size={fill === 'brand' ? 18 : 24}
            color={ink}
          />
        </View>
        <Text
          accessibilityRole="header"
          style={[
            styles.cardTitle,
            fill === 'brand' && styles.brandTitle,
            { color: ink },
          ]}>
          {title}
        </Text>
        {description === undefined ? null : (
          <Text
            style={[
              styles.cardDescription,
              fill === 'brand' && styles.brandDescription,
              {
                color:
                  fill === 'brand' ? colors.brandOnDeep : colors.textSecondary,
              },
            ]}>
            {description}
          </Text>
        )}
      </View>
      {children}
    </View>
  );
}
