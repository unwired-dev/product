import type { GmailLabel } from '@private-email/mail-core/gmail-actions';
import type { ReactNode, RefObject } from 'react';

import { typedLabel } from '@private-email/mail-core/gmail-actions';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useLayoutEffect, useRef, useState } from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { askInSheet, Button, Popover, SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { useMailbox, useProviderName } from './mailbox.tsx';
import { textStyles, usePalette } from './theme.ts';

// The Mac Labels frames: 20pt inside the popover, 10pt between its parts, rows in 10pt groups.
const styles = StyleSheet.create({
  panel: { width: 360, gap: 10, padding: 20 },
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    height: 28,
    paddingHorizontal: spacing.s,
    borderRadius: radius.control,
  },
  input: { ...textStyles.body, flex: 1 },
  list: { maxHeight: 240, flexGrow: 0 },
  listContent: { gap: 10 },
  group: { borderRadius: 10, borderCurve: 'continuous', overflow: 'hidden' },
  row: {
    minHeight: 40,
    justifyContent: 'center',
    gap: 2,
    // The frame's 12pt and 10pt insets, less the 2pt focus border.
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderWidth: 2,
    borderRadius: 10,
  },
  separator: { height: StyleSheet.hairlineWidth, marginHorizontal: 12 },
  header: {
    ...textStyles.subheadlineEmphasized,
    paddingLeft: 12,
    paddingTop: 10,
  },
  footer: { ...textStyles.subheadline, paddingHorizontal: 12 },
  buttons: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
    paddingTop: 6,
  },
});

// A clickable row of a grouped list that shows keyboard focus.
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
  const [focused, setFocused] = useState(false);
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
        onBlur={() => {
          setFocused(false);
        }}
        onFocus={() => {
          setFocused(true);
        }}
        onPress={onPress}
        style={({ pressed }) => [
          styles.row,
          {
            backgroundColor: pressed
              ? colors.accentSelectionSubtle
              : 'transparent',
            borderColor: focused ? colors.accentInk : 'transparent',
          },
        ]}>
        {children}
      </Pressable>
    </>
  );
}

// Labels, as New Label… opens it below the reader's toolbar: a name to type, a row creating it in
// Gmail, then the account's labels. Apply creates the label and applies it, or applies the label
// Gmail already has under that name; a name that differs from one only in case asks in a sheet
// whether to use that label instead. Labels already on the Thread stay.
export function NewLabel({
  opening,
  anchor,
  labels,
  onApply,
  onCreate,
}: {
  // The view in the reader's window that its sheets attach to.
  // Counts the choices of New Label…; each opens Labels with an empty name, unless Gmail is still
  // answering for the last one, whose name a refusal returns to.
  readonly opening: number;
  readonly anchor: RefObject<View | null>;
  readonly labels: readonly GmailLabel[];
  readonly onApply: (label: string) => void;
  // Creates the label in Gmail and applies it; false when nothing was applied.
  readonly onCreate: (name: string) => Promise<boolean>;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const mailbox = useMailbox();
  const provider = useProviderName();
  const [shown, setShown] = useState(true);
  const [typed, setTyped] = useState('');
  const [creating, setCreating] = useState(false);
  const [opened, setOpened] = useState(opening);
  if (opening !== opened) {
    setOpened(opening);
    setShown(true);
    if (!creating) {
      setTyped('');
    }
  }
  // The sheet asked last; it closes with the reader.
  const asked = useRef<ReturnType<typeof askInSheet>>(undefined);
  // The opening Labels shows, until the reader closes it.
  const live = useRef<number>(undefined);
  useLayoutEffect(() => {
    live.current = opened;
  }, [opened]);
  useLayoutEffect(
    () => () => {
      live.current = undefined;
      asked.current?.retire();
    },
    [],
  );
  // Labels closes for a sheet, as the frames show, and the sheet's index answer is null once
  // another sheet or the reader's closing retired it.
  const ask = async (question: Parameters<typeof askInSheet>[1]) => {
    // Gmail can answer after the reader closed Labels, which then asks nothing.
    if (live.current === undefined) {
      return null;
    }
    setShown(false);
    asked.current?.retire();
    const asking = askInSheet(anchor.current, question);
    asked.current = asking;
    const choice = await asking.answer;
    return asked.current === asking ? choice : null;
  };
  const label = typedLabel(labels, typed);
  const choose = (id: string) => {
    setShown(false);
    onApply(id);
  };
  // Closing Labels while Gmail answers still creates and applies the label, and a refusal is
  // still explained; OK opens Labels again with the name to edit.
  const create = async (name: string) => {
    setCreating(true);
    const created = await onCreate(name);
    setCreating(false);
    if (created) {
      setShown(false);
    } else if (
      (await ask({
        title: t('gmailActions.labelNotCreated', { label: name }),
        detail: t('gmailActions.labelNotCreatedDetail'),
        buttons: [t('common.ok')],
      })) !== null
    ) {
      setShown(true);
    }
  };
  const offerExisting = async (name: string, existing: GmailLabel) => {
    const choice = await ask({
      title: t('gmailActions.labelCaseTitle', { label: name }),
      detail: t('gmailActions.labelCaseDetail'),
      buttons: [
        t('gmailActions.useLabel', { label: existing.name }),
        t('gmailActions.editLabelName'),
      ],
    });
    if (choice === 0) {
      onApply(existing.id);
    } else if (choice === 1) {
      setShown(true);
    }
  };
  const apply = () => {
    const { name, existing } = label;
    if (name === '' || creating) {
      return;
    }
    if (existing === undefined) {
      void create(name);
    } else if (existing.name === name) {
      choose(existing.id);
    } else {
      void offerExisting(name, existing);
    }
  };
  const createTitle =
    label.parent === undefined
      ? t('gmailActions.createLabel', { label: label.name })
      : t('gmailActions.createNestedLabel', {
          label: label.leaf,
          parent: label.parent,
        });
  const primary = { color: colors.textPrimary };
  const secondary = { color: colors.textSecondary };
  const quiet = { backgroundColor: colors.fillQuiet };
  return (
    <Popover
      // Each opening is its own popover, so the last one's close, arriving late, cannot close it.
      key={opened}
      below
      title={t('gmailActions.labels')}
      shown={shown}
      onClose={() => {
        if (live.current === opened) {
          setShown(false);
        }
      }}>
      <View
        testID="new-label"
        style={styles.panel}>
        <Label
          accessibilityRole="header"
          style={[textStyles.title3Emphasized, primary]}>
          {t('gmailActions.labels')}
        </Label>
        <Label
          numberOfLines={1}
          style={[textStyles.body, secondary]}>
          {mailbox === undefined
            ? provider
            : `${provider} · ${mailbox.address}`}
        </Label>
        <View style={[styles.field, quiet]}>
          <SFSymbol
            name="tag"
            size={15}
            color={colors.accentInk}
          />
          <TextInput
            accessibilityLabel={t('gmailActions.labelName')}
            autoCorrect={false}
            // oxlint-disable-next-line jsx-a11y/no-autofocus -- New Label… opens Labels to type a name; it focuses once AppKit gives the popover its window.
            autoFocus
            editable={!creating}
            onChangeText={setTyped}
            // AppKit reports Escape in a text input as a key press; it closes Labels.
            onKeyPress={({ nativeEvent }) => {
              if (nativeEvent.key === 'Escape') {
                setShown(false);
              }
            }}
            onSubmitEditing={apply}
            placeholder={t('gmailActions.labelName')}
            placeholderTextColor={colors.textSecondary}
            style={[styles.input, primary]}
            value={typed}
          />
        </View>
        <ScrollView
          style={styles.list}
          contentContainerStyle={styles.listContent}>
          {label.name === '' || label.existing !== undefined ? null : (
            <View style={[styles.group, quiet]}>
              <Row
                label={`${createTitle}, ${t('gmailActions.createLabelDetail')}`}
                disabled={creating}
                onPress={apply}>
                <Text style={[textStyles.body, primary]}>{createTitle}</Text>
                <Text style={[textStyles.subheadline, secondary]}>
                  {t('gmailActions.createLabelDetail')}
                </Text>
              </Row>
            </View>
          )}
          {labels.length === 0 ? null : (
            <View style={styles.listContent}>
              {label.name === '' ? null : (
                <Label
                  accessibilityRole="header"
                  style={[styles.header, secondary]}>
                  {t('gmailActions.matchingLabels')}
                </Label>
              )}
              <View style={[styles.group, quiet]}>
                {labels.map((match, index) => (
                  <Row
                    key={match.id}
                    label={match.name}
                    separated={index > 0}
                    disabled={creating}
                    onPress={() => {
                      choose(match.id);
                    }}>
                    <Text
                      numberOfLines={1}
                      style={[textStyles.body, primary]}>
                      {match.name}
                    </Text>
                  </Row>
                ))}
              </View>
            </View>
          )}
        </ScrollView>
        <Label style={[styles.footer, secondary]}>
          {t('gmailActions.newLabelFooter')}
        </Label>
        <View style={styles.buttons}>
          <Button
            label={t('common.cancel')}
            // A label being created is applied once Gmail answers, so it cannot be cancelled.
            disabled={creating}
            onPress={() => {
              setShown(false);
            }}
          />
          <Button
            label={t('gmailActions.applyLabel')}
            fill="accent"
            disabled={label.name === '' || creating}
            onPress={apply}
          />
        </View>
      </View>
    </Popover>
  );
}
