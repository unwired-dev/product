import type { GmailLabel } from '@private-email/mail-core/gmail-actions';
import type { ReactNode } from 'react';
import type { TextInputInstance } from 'react-native';

import {
  BottomSheet,
  Group,
  Host,
  RNHostView,
  Button as SwiftUIButton,
  Text as SwiftUIText,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  font,
  foregroundStyle,
  frame,
  disabled as inactive,
  presentationBackground,
  presentationDetents,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { typedLabel } from '@private-email/mail-core/gmail-actions';
import { spacing } from '@private-email/mail-core/theme';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  Alert,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProviderName } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

// The Labels frames: 20pt inside the panel, 10pt between its parts, 17pt grouped rows.
const styles = StyleSheet.create({
  form: { flex: 1, gap: 10, padding: 20 },
  // The iPad popover's width and the space its list may take beneath the toolbar.
  panel: { width: 400, padding: 20, gap: 10 },
  panelList: { maxHeight: 300, flexGrow: 0 },
  list: { flexShrink: 1 },
  listContent: { gap: 10 },
  title: { ...textStyles.headline },
  account: { ...textStyles.subheadline },
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 46,
    paddingHorizontal: 12,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  input: { ...textStyles.body, flex: 1, minHeight: 44, padding: 0 },
  group: { borderRadius: 17, borderCurve: 'continuous', overflow: 'hidden' },
  row: { minHeight: 52, justifyContent: 'center', paddingHorizontal: 16 },
  createRow: { minHeight: 68, paddingVertical: 12 },
  rowTitle: { ...textStyles.body },
  rowDetail: { ...textStyles.footnote },
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 16 },
  header: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingHorizontal: 16,
    paddingTop: 13,
  },
  footer: { ...textStyles.footnote, paddingHorizontal: 16 },
  buttons: { gap: spacing.s },
});

// One of the form's full-width capsule buttons: the system's bordered button, prominent for Apply.
function FormButton({
  label,
  prominent,
  disabled,
  onPress,
}: {
  readonly label: string;
  readonly prominent: boolean;
  readonly disabled: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  return (
    <Host matchContents={{ vertical: true }}>
      <SwiftUIButton
        modifiers={[
          buttonStyle(prominent ? 'borderedProminent' : 'bordered'),
          buttonBorderShape('capsule'),
          controlSize('large'),
          tint(prominent ? colors.accentFill : colors.fillQuiet),
          inactive(disabled),
        ]}
        onPress={onPress}>
        <SwiftUIText
          modifiers={[
            font({ textStyle: 'headline' }),
            foregroundStyle(
              prominent ? colors.accentOnFill : colors.textPrimary,
            ),
            frame({ maxWidth: Infinity }),
          ]}>
          {label}
        </SwiftUIText>
      </SwiftUIButton>
    </Host>
  );
}

// A tappable row of a grouped list.
function Row({
  label,
  separated = false,
  disabled,
  onPress,
  children,
}: {
  readonly label: string;
  readonly separated?: boolean;
  readonly disabled: boolean;
  readonly onPress: () => void;
  readonly children: ReactNode;
}) {
  const colors = usePalette();
  return (
    <>
      {separated ? (
        <View
          style={[styles.separator, { backgroundColor: colors.separator }]}
        />
      ) : null}
      <Pressable
        accessibilityLabel={label}
        accessibilityRole="button"
        accessibilityState={{ disabled }}
        disabled={disabled}
        focusable
        onPress={onPress}
        style={({ pressed }) => [
          styles.row,
          pressed && { backgroundColor: colors.accentSelectionSubtle },
        ]}>
        {children}
      </Pressable>
    </>
  );
}

// Labels, as New Label… opens it on iPhone and iPad: a name to type, a row creating it in Gmail,
// then the account's labels. Apply creates the label and applies it, or applies the label Gmail
// already has under that name; a name that differs from one only in case offers that label
// instead. Labels already on the Thread stay.
function LabelForm({
  open,
  labels,
  onApply,
  onCreate,
  onClose,
}: {
  readonly open: boolean;
  readonly labels: readonly GmailLabel[];
  readonly onApply: (label: string) => void;
  // Creates the label in Gmail and applies it; false when nothing was applied.
  readonly onCreate: (name: string) => Promise<boolean>;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = useProviderName();
  const field = useRef<TextInputInstance>(null);
  const [typed, setTyped] = useState('');
  const [creating, setCreating] = useState(false);
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      setTyped('');
      setCreating(false);
    }
  }
  // A token for each opening of the form, so a creation settling later changes only the opening it
  // began in.
  const opening = useRef<object>(undefined);
  useLayoutEffect(() => {
    opening.current = open ? {} : undefined;
    return () => {
      opening.current = undefined;
    };
  }, [open]);
  // Opening starts with the name, as the frames show its caret.
  useEffect(() => {
    if (open) {
      field.current?.focus();
    }
  }, [open]);
  const label = typedLabel(labels, typed);
  const create = async () => {
    setCreating(true);
    const began = opening.current;
    const created = await onCreate(label.name);
    // Closing Labels while Gmail answers lets the label be created and applied, as on Mac, and a
    // refusal is still explained.
    if (opening.current === began) {
      setCreating(false);
      if (created) {
        onClose();
      }
    }
    if (created) {
      return;
    }
    Alert.alert(
      t('gmailActions.labelNotCreated', { label: label.name }),
      t('gmailActions.labelNotCreatedDetail'),
    );
  };
  const apply = () => {
    const { name, existing } = label;
    if (name === '' || creating) {
      return;
    }
    if (existing === undefined) {
      void create();
    } else if (existing.name === name) {
      onApply(existing.id);
    } else {
      Alert.alert(
        t('gmailActions.labelCaseTitle', { label: name }),
        t('gmailActions.labelCaseDetail'),
        [
          {
            text: t('gmailActions.useLabel', { label: existing.name }),
            isPreferred: true,
            onPress: () => {
              onApply(existing.id);
            },
          },
          {
            text: t('gmailActions.editLabelName'),
            style: 'cancel',
            onPress: () => {
              field.current?.focus();
            },
          },
        ],
      );
    }
  };
  const createTitle =
    label.parent === undefined
      ? t('gmailActions.createLabel', { label: label.name })
      : t('gmailActions.createNestedLabel', {
          label: label.leaf,
          parent: label.parent,
        });
  const secondary = { color: colors.textSecondary };
  const primary = { color: colors.textPrimary };
  const quiet = { backgroundColor: colors.fillQuiet };
  return (
    <>
      <View>
        <Text
          accessibilityRole="header"
          style={[styles.title, primary]}>
          {t('gmailActions.labels')}
        </Text>
        <Text
          numberOfLines={1}
          style={[styles.account, secondary]}>
          {mailbox === undefined
            ? provider
            : `${provider} · ${mailbox.address}`}
        </Text>
      </View>
      <View style={[styles.field, quiet]}>
        <SFSymbol
          name="tag"
          color={colors.textSecondary}
        />
        <TextInput
          ref={field}
          accessibilityLabel={t('gmailActions.labelName')}
          autoCapitalize="none"
          autoCorrect={false}
          editable={!creating}
          onChangeText={setTyped}
          onSubmitEditing={apply}
          placeholder={t('gmailActions.labelName')}
          placeholderTextColor={colors.textSecondary}
          returnKeyType="done"
          style={[styles.input, primary]}
          submitBehavior="submit"
          value={typed}
        />
      </View>
      <ScrollView
        keyboardShouldPersistTaps="handled"
        style={compact ? styles.list : styles.panelList}
        contentContainerStyle={styles.listContent}>
        {label.name === '' || label.existing !== undefined ? null : (
          <View style={[styles.group, quiet]}>
            <Row
              label={`${createTitle}, ${t('gmailActions.createLabelDetail')}`}
              disabled={creating}
              onPress={apply}>
              <View style={styles.createRow}>
                <Text style={[styles.rowTitle, primary]}>{createTitle}</Text>
                <Text style={[styles.rowDetail, secondary]}>
                  {t('gmailActions.createLabelDetail')}
                </Text>
              </View>
            </Row>
          </View>
        )}
        {labels.length === 0 ? null : (
          <View>
            {label.name === '' ? null : (
              <Text
                accessibilityRole="header"
                style={[styles.header, secondary]}>
                {t('gmailActions.matchingLabels')}
              </Text>
            )}
            <View style={[styles.group, quiet, { marginTop: 10 }]}>
              {labels.map((match, index) => (
                <Row
                  key={match.id}
                  label={match.name}
                  separated={index > 0}
                  disabled={creating}
                  onPress={() => {
                    onApply(match.id);
                  }}>
                  <Text
                    numberOfLines={1}
                    style={[styles.rowTitle, primary]}>
                    {match.name}
                  </Text>
                </Row>
              ))}
            </View>
          </View>
        )}
        <Text style={[styles.footer, secondary]}>
          {t('gmailActions.newLabelFooter')}
        </Text>
      </ScrollView>
      <View style={styles.buttons}>
        <FormButton
          label={t('common.cancel')}
          prominent={false}
          // A label being created is applied once Gmail answers, so it cannot be cancelled.
          disabled={creating}
          onPress={onClose}
        />
        <FormButton
          label={t('gmailActions.applyLabel')}
          prominent
          disabled={label.name === '' || creating}
          onPress={apply}
        />
      </View>
    </>
  );
}

// iPhone shows Labels in a system sheet; iPad in the reader's panel beneath its toolbar.
export function NewLabel(props: Parameters<typeof LabelForm>[0]) {
  const colors = usePalette();
  const { height } = useWindowDimensions();
  const { bottom } = useSafeAreaInsets();
  if (!compact) {
    return (
      <View
        testID="new-label"
        style={styles.panel}>
        <LabelForm {...props} />
      </View>
    );
  }
  return (
    <Host matchContents>
      <BottomSheet
        isPresented={props.open}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            props.onClose();
          }
        }}>
        <Group
          modifiers={[
            // The frame's sheet is 626pt tall; a custom detent leaves out the bottom safe area.
            presentationDetents([
              { height: Math.min(626, height - 70) - bottom },
            ]),
            presentationBackground(colors.surfacePanel),
          ]}>
          <RNHostView>
            <View
              testID="new-label"
              style={styles.form}>
              <LabelForm {...props} />
            </View>
          </RNHostView>
        </Group>
      </BottomSheet>
    </Host>
  );
}
