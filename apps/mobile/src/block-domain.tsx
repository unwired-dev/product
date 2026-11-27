import {
  BottomSheet,
  Group,
  Host,
  RNHostView,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  background,
  buttonStyle,
  contentShape,
  font,
  foregroundStyle,
  frame,
  ignoreSafeArea,
  disabled as inactive,
  presentationBackground,
  presentationDetents,
  presentationSizing,
  shapes,
} from '@expo/ui/swift-ui/modifiers';
import {
  addressesAtDomain,
  parentDomain,
} from '@private-email/mail-core/blocked-senders';
import {
  ipadListScale,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { use, useState } from 'react';
import {
  Alert,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import { BlockedSendersContext } from './blocked-senders.tsx';
import { useContactAddresses } from './contacts.ts';
import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, useAppearance, usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

// The iPhone metric, or on iPad the Mac Settings Row metric at the frames' 1.15×.
const metric = (iphone: number, mac: number) =>
  compact ? iphone : mac * ipadListScale;

// The I2 and P2 frames: 20pt inside the panel and 10pt between its parts, grouped rows, and two
// 48pt capsules. iPhone rows use the iOS type and are at least 52pt (56pt with a switch); iPad's
// centred 400pt sheet uses the iPad list type. iPad draws no divider between the choices.
const styles = StyleSheet.create({
  // Block ends 22pt above the screen's foot, as the frame draws it under the floating sheet.
  sheet: { flex: 1, gap: 10, padding: 20, paddingBottom: 14 },
  // The fitted form sheet adds 10pt above and below its content.
  panel: { width: 400, gap: 10, paddingHorizontal: 20, paddingVertical: 10 },
  content: { gap: 10 },
  scroll: { flexShrink: 1 },
  title: { ...textStyles.headline },
  from: { ...textStyles.subheadline },
  group: {
    borderRadius: metric(17, 10),
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: metric(12, 10),
    minHeight: metric(52, 40),
    paddingHorizontal: metric(16, 12),
    paddingVertical: metric(13, 10),
  },
  switchRow: { minHeight: metric(56, 40) },
  // Shrinks to the row, so a long domain wraps as the frames draw it.
  text: { flex: 1, flexShrink: 1, gap: metric(2, 2) },
  body: compact ? textStyles.body : typography.ipadList.body,
  detail: compact ? textStyles.footnote : typography.ipadList.subheadline,
  separator: {
    position: 'absolute',
    top: 0,
    left: 16,
    right: 16,
    height: StyleSheet.hairlineWidth,
  },
  header: {
    ...(compact
      ? textStyles.subheadlineEmphasized
      : { ...typography.ipadList.subheadline, fontWeight: '600' }),
    paddingLeft: metric(15.6, 12),
    paddingTop: metric(13, 10),
  },
  footer: {
    ...(compact
      ? { ...textStyles.subheadline, lineHeight: 18.2 }
      : typography.ipadList.subheadline),
    paddingHorizontal: metric(15.6, 12),
  },
  buttons: { gap: spacing.s },
});

export type DomainSender = Readonly<{
  sender: string;
  address: string;
  domain: string;
  profile: string;
}>;

// One of the sheet's 48pt capsules on the content surface.
function SheetButton({
  label,
  color,
  disabled,
  onPress,
}: {
  readonly label: string;
  readonly color: string;
  readonly disabled: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const appearance = useAppearance();
  return (
    <Host matchContents={{ vertical: true }}>
      <SwiftUIButton
        modifiers={[
          buttonStyle('plain'),
          // The Dark frames draw the capsules in the quiet fill on the panel.
          background(
            appearance === 'dark' ? colors.fillQuiet : colors.surfaceContent,
            shapes.capsule(),
          ),
          inactive(disabled),
        ]}
        onPress={onPress}>
        <SwiftUIText
          modifiers={[
            font({ textStyle: 'headline' }),
            foregroundStyle(color),
            frame({ maxWidth: Infinity, minHeight: 48 }),
            contentShape(shapes.capsule()),
          ]}>
          {label}
        </SwiftUIText>
      </SwiftUIButton>
    </Host>
  );
}

// The sheet's form: the domain with its subdomains or alone, the rule that choice makes, Contacts
// at This Domain as an exemption when the person has any there, then Cancel and Block. Block
// stores the domain with those choices for the reader's Mail Profile; a refused write says so and
// keeps the sheet open.
function BlockDomainForm({
  sender,
  onClose,
}: {
  readonly sender: DomainSender;
  readonly onClose: () => void;
}) {
  const store = use(BlockedSendersContext);
  const colors = usePalette();
  const { t } = useLocalization();
  const { domain } = sender;
  const [subdomains, setSubdomains] = useState(true);
  const [exempting, setExempting] = useState(true);
  const [saving, setSaving] = useState(false);
  // Contacts already readable; blocking never asks for Contacts access, and waits for the read so
  // the exemption is not lost.
  const read = useContactAddresses(true, false);
  const contacts = addressesAtDomain(
    domain,
    subdomains,
    read.addresses.map(({ address }) => address),
  );
  const parent = parentDomain(domain);
  let keeps = t('blockedSenders.ruleKeeps', { context: 'only' });
  if (subdomains) {
    keeps =
      parent === undefined
        ? t('blockedSenders.ruleKeeps')
        : t('blockedSenders.ruleKeepsParent', { parent });
  }
  const block = async () => {
    setSaving(true);
    const stored = await store.blockDomain(sender.profile, domain, {
      subdomains,
      exempt: exempting ? contacts : [],
    });
    setSaving(false);
    if (stored) {
      onClose();
      return;
    }
    Alert.alert(
      t('blockedSenders.blockDomainFailed', { domain }),
      t('blockedSenders.blockDomainTryAgain'),
    );
  };
  const primary = { color: colors.textPrimary };
  const secondary = { color: colors.textSecondary };
  const detail = { color: colors.textDetail };
  const quiet = { backgroundColor: colors.fillQuiet };
  const choices = [
    { value: true, label: t('blockedSenders.withSubdomains', { domain }) },
    { value: false, label: t('blockedSenders.domainOnly', { domain }) },
  ];
  return (
    <>
      <Text
        accessibilityRole="header"
        style={[styles.title, primary]}>
        {t('blockedSenders.blockDomainTitle', { domain })}
      </Text>
      <Text style={[styles.from, secondary]}>
        {sender.sender === '' || sender.sender === sender.address
          ? t('blockedSenders.fromAddress', { address: sender.address })
          : t('blockedSenders.from', {
              sender: sender.sender,
              address: sender.address,
            })}
      </Text>
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.content}>
        <View style={[styles.group, quiet]}>
          {choices.map(({ value, label }, index) => (
            <Pressable
              key={label}
              accessibilityLabel={label}
              accessibilityRole="radio"
              accessibilityState={{ checked: subdomains === value }}
              focusable
              onPress={() => {
                setSubdomains(value);
              }}
              style={({ pressed }) => [
                styles.row,
                pressed && { backgroundColor: colors.accentSelectionSubtle },
              ]}>
              {compact && index > 0 ? (
                <View
                  style={[
                    styles.separator,
                    { backgroundColor: colors.separator },
                  ]}
                />
              ) : null}
              <Text style={[styles.body, styles.text, primary]}>{label}</Text>
              {subdomains === value ? (
                <SFSymbol
                  name="checkmark"
                  // iPad's mark is the list type's, about 10pt of ink.
                  size={compact ? 16 : 11}
                  color={colors.textSecondary}
                />
              ) : null}
            </Pressable>
          ))}
        </View>
        <Text
          accessibilityRole="header"
          style={[styles.header, secondary]}>
          {t('blockedSenders.rule')}
        </Text>
        <View style={[styles.group, quiet]}>
          <View style={styles.row}>
            <View style={styles.text}>
              <Text style={[styles.body, primary]}>
                {subdomains
                  ? t('blockedSenders.ruleSubdomains', { domain })
                  : t('blockedSenders.ruleOnly', { domain })}
              </Text>
              <Text style={[styles.detail, detail]}>{keeps}</Text>
            </View>
          </View>
        </View>
        {contacts.length === 0 ? null : (
          <>
            <Text
              accessibilityRole="header"
              style={[styles.header, secondary]}>
              {t('blockedSenders.exemptions')}
            </Text>
            <View style={[styles.group, quiet]}>
              <View style={[styles.row, styles.switchRow]}>
                <View style={styles.text}>
                  <Text style={[styles.body, primary]}>
                    {t('blockedSenders.exemptContacts')}
                  </Text>
                  <Text style={[styles.detail, detail]}>
                    {contacts.join(', ')}
                  </Text>
                </View>
                <Switch
                  accessibilityLabel={t('blockedSenders.exemptContacts')}
                  onValueChange={setExempting}
                  thumbColor={colors.accentOnFill}
                  trackColor={{
                    false: colors.fillTrack,
                    true: colors.accentFill,
                  }}
                  value={exempting}
                />
              </View>
            </View>
          </>
        )}
        <Text style={[styles.footer, secondary]}>
          {t('blockedSenders.blockDomainFooter')}
        </Text>
      </ScrollView>
      <View style={styles.buttons}>
        <SheetButton
          label={t('common.cancel')}
          color={colors.accentInk}
          disabled={saving}
          onPress={onClose}
        />
        <SheetButton
          label={t('blockedSenders.blockDomainAction', { domain })}
          color={colors.statusDestructive}
          disabled={saving || !read.settled}
          onPress={() => {
            void block();
          }}
        />
      </View>
    </>
  );
}

// Block Domain…'s sheet for `sender`: edge-attached on iPhone, as the I2 frames draw it, and a
// centred form sheet fitted to the panel on iPad (P2). Each opening starts from the frames'
// choices.
export function BlockDomainSheet({
  sender,
  open,
  onClose,
}: {
  readonly sender: DomainSender | undefined;
  readonly open: boolean;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const appearance = useAppearance();
  const { height } = useWindowDimensions();
  const [opening, setOpening] = useState(0);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setOpening(opening + 1);
    }
  }
  if (sender === undefined) {
    return null;
  }
  return (
    <Host matchContents>
      <BottomSheet
        isPresented={open}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            onClose();
          }
        }}>
        <Group
          modifiers={[
            compact
              ? // The frame's sheet starts 707pt above the screen's foot. The floating sheet ends
                // 8pt above it and draws 6pt beyond its detent.
                presentationDetents([
                  { height: Math.min(707, height - 70) - 14 },
                ])
              : presentationSizing('fitted'),
            // The iPhone panel's 14pt bottom padding is its whole bottom inset, as the frames draw it.
            ...(compact
              ? [ignoreSafeArea({ regions: 'container', edges: 'bottom' })]
              : []),
            // The Dark frames draw the sheet as the glass panel surface; Light keeps the system's
            // sheet glass, as the Reply sheet does.
            ...(appearance === 'dark'
              ? [presentationBackground(colors.surfacePanel)]
              : []),
          ]}>
          <RNHostView matchContents={!compact}>
            <View
              testID="block-domain"
              style={compact ? styles.sheet : styles.panel}>
              <BlockDomainForm
                key={opening}
                sender={sender}
                onClose={onClose}
              />
            </View>
          </RNHostView>
        </Group>
      </BottomSheet>
    </Host>
  );
}
