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
  background,
  buttonBorderShape,
  buttonStyle,
  contentShape,
  controlSize,
  font,
  foregroundStyle,
  frame,
  disabled as inactive,
  padding,
  presentationBackground,
  presentationDetents,
  shapes,
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
import { textStyles, useAppearance, usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

// The Labels frames: 20pt inside the panel, 10pt between its parts, 17pt grouped rows.
const styles = StyleSheet.create({
  form: { flex: 1, gap: 10, padding: 20 },
  // The iPad popover's width and the space its list may take beneath the toolbar.
  panel: { width: 400, padding: 20, gap: 10 },
  panelList: { maxHeight: 300, flexGrow: 0 },
  list: { flexShrink: 1 },
  listContent: { gap: 10 },
  // The frames leave 10pt between the title and the account.
  heading: { gap: 10 },
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
  // A label's row: its name and check, then on iPad the Move to that label.
  choice: { flexDirection: 'row', alignItems: 'stretch' },
  choiceName: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    // Long nested names wrap, so labels sharing a prefix stay apart.
    paddingVertical: 12,
  },
  choiceTitle: { flex: 1 },
  move: { width: 52, alignItems: 'center', justifyContent: 'center' },
  header: {
    ...textStyles.footnote,
    fontWeight: '600',
    paddingHorizontal: 16,
    paddingTop: 13,
  },
  footer: { ...textStyles.footnote, paddingHorizontal: 16 },
  buttons: { gap: spacing.s },
});

// One of the form's full-width capsule buttons.
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
  // The system's bordered styles mute Cancel's fill and override disabled Apply's tint.
  const muted = prominent ? `${colors.accentFill}B3` : colors.fillQuiet;
  const fill = !prominent || disabled ? muted : undefined;
  return (
    <Host matchContents={{ vertical: true }}>
      <SwiftUIButton
        modifiers={[
          ...(fill === undefined
            ? [
                buttonStyle(prominent ? 'borderedProminent' : 'bordered'),
                buttonBorderShape('capsule'),
                controlSize('large'),
                tint(prominent ? colors.accentFill : colors.fillQuiet),
              ]
            : [buttonStyle('plain'), background(fill, shapes.capsule())]),
          inactive(disabled),
        ]}
        onPress={onPress}>
        <SwiftUIText
          modifiers={[
            font({ textStyle: 'headline' }),
            foregroundStyle(
              prominent ? colors.accentOnFill : colors.textPrimary,
            ),
            ...(fill === undefined
              ? [frame({ maxWidth: Infinity })]
              : [
                  padding({ horizontal: 12, vertical: 10 }),
                  frame({ maxWidth: Infinity, minHeight: 50 }),
                  contentShape(shapes.capsule()),
                ]),
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

// The Labels frames' title, over the Gmail account the labels belong to.
function LabelsHeader() {
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = useProviderName();
  return (
    <View style={styles.heading}>
      <Text
        accessibilityRole="header"
        style={[styles.title, { color: colors.textPrimary }]}>
        {t('gmailActions.labels')}
      </Text>
      <Text
        numberOfLines={1}
        style={[styles.account, { color: colors.textSecondary }]}>
        {mailbox === undefined ? provider : `${provider} · ${mailbox.address}`}
      </Text>
    </View>
  );
}

// Gmail's labels as the Labels frames draw them: the account, then the labels in one group,
// checked when the Thread has them, and New Label… in its own. iPad's rows also move the Thread to
// their label. iPhone shows them in a system sheet; iPad in the popover on the reader's toolbar.
export function LabelChoices({
  labels,
  applied,
  notes,
  onToggle,
  onMove,
  onNewLabel,
}: {
  readonly labels: readonly GmailLabel[];
  readonly applied: ReadonlySet<string>;
  readonly notes: readonly string[];
  readonly onToggle: (label: string, applied: boolean) => void;
  readonly onMove?: ((label: string) => void) | undefined;
  readonly onNewLabel: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const primary = { color: colors.textPrimary };
  const quiet = { backgroundColor: colors.fillQuiet };
  const pressedRow = { backgroundColor: colors.accentSelectionSubtle };
  return (
    <View style={compact ? styles.form : styles.panel}>
      <LabelsHeader />
      <ScrollView
        style={compact ? styles.list : styles.panelList}
        contentContainerStyle={styles.listContent}>
        {notes.map((note) => (
          <Text
            key={note}
            style={[styles.footer, { color: colors.textSecondary }]}>
            {note}
          </Text>
        ))}
        {labels.length === 0 ? null : (
          <View style={[styles.group, quiet]}>
            {labels.map((label, index) => {
              const checked = applied.has(label.id);
              return (
                <View key={label.id}>
                  {index > 0 ? (
                    <View
                      style={[
                        styles.separator,
                        { backgroundColor: colors.separator },
                      ]}
                    />
                  ) : null}
                  <View style={styles.choice}>
                    <Pressable
                      accessibilityLabel={label.name}
                      accessibilityRole="checkbox"
                      accessibilityState={{ checked }}
                      focusable
                      onPress={() => {
                        onToggle(label.id, checked);
                      }}
                      style={({ pressed }) => [
                        styles.row,
                        styles.choiceName,
                        pressed && pressedRow,
                      ]}>
                      <Text
                        style={[styles.rowTitle, styles.choiceTitle, primary]}>
                        {label.name}
                      </Text>
                      {checked ? (
                        <SFSymbol
                          name="checkmark"
                          color={colors.textPrimary}
                          semibold
                        />
                      ) : null}
                    </Pressable>
                    {onMove === undefined ? null : (
                      <Pressable
                        accessibilityLabel={t('gmailActions.moveTo', {
                          label: label.name,
                        })}
                        accessibilityRole="button"
                        focusable
                        onPress={() => {
                          onMove(label.id);
                        }}
                        style={({ pressed }) => [
                          styles.move,
                          pressed && pressedRow,
                        ]}>
                        <SFSymbol
                          name="folder"
                          color={colors.textSecondary}
                        />
                      </Pressable>
                    )}
                  </View>
                </View>
              );
            })}
          </View>
        )}
        <View style={[styles.group, quiet]}>
          <Row
            label={t('gmailActions.newLabel')}
            disabled={false}
            onPress={onNewLabel}>
            <Text style={[styles.rowTitle, primary]}>
              {t('gmailActions.newLabel')}
            </Text>
          </Row>
        </View>
      </ScrollView>
    </View>
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
      <LabelsHeader />
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

// iPhone shows Labels in a system sheet; iPad in the labels' popover on the reader's toolbar.
export function NewLabel(props: Parameters<typeof LabelForm>[0]) {
  const colors = usePalette();
  const appearance = useAppearance();
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
            // The Dark frames draw the sheet as the glass panel surface; Light keeps the system's
            // sheet glass, as the Reply sheet does.
            ...(appearance === 'dark'
              ? [presentationBackground(colors.surfacePanel)]
              : []),
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
