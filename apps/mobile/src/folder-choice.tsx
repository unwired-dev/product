import type { ImapFolder } from '@private-email/mail-core/imap-inbox';
import type { ChosenFolders } from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

import {
  BottomSheet,
  Group,
  Host,
  RNHostView,
  Button as SwiftUIButton,
} from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  disabled as inactive,
  labelStyle,
  presentationDetents,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  ambiguousFolders,
  folderChoice,
  startingPicks,
} from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Button, MenuButton, SFSymbol } from './design.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  sheet: { gap: 14, padding: spacing.l, paddingTop: 10 },
  header: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
  title: { ...textStyles.headline, flex: 1, textAlign: 'center' },
  text: { ...textStyles.subheadline, paddingHorizontal: spacing.l },
  group: { borderRadius: radius.insetGroup, borderCurve: 'continuous' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 56,
    paddingHorizontal: spacing.l,
  },
  rowText: { flex: 1 },
  label: textStyles.body,
  footnote: textStyles.footnote,
  separator: { height: StyleSheet.hairlineWidth, marginLeft: spacing.l },
  value: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  message: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
  },
  note: { ...textStyles.subheadline, flex: 1 },
  choose: { alignSelf: 'flex-start' },
});

// A sheet where the person picks the folders that hold Spam and Trash for the roles an IMAP
// connection's server marks no folder with. `children` opens it: Choose Folders… under the
// connection's not-included notice by default, or its Settings row.
export function FolderChoice({
  address,
  folders,
  marked,
  saved,
  onSave,
  children,
}: {
  readonly address: string;
  readonly folders: readonly ImapFolder[];
  readonly marked: ChosenFolders;
  readonly saved: ChosenFolders | undefined;
  readonly onSave: (chosen: ChosenFolders) => Promise<boolean>;
  readonly children?: (open: () => void) => ReactNode;
}) {
  const { t } = useLocalization();
  const [shown, setShown] = useState(false);
  const [session, setSession] = useState(0);
  if (ambiguousFolders(folders)) {
    return null;
  }
  const open = () => {
    setSession((previous) => previous + 1);
    setShown(true);
  };
  return (
    <>
      {children === undefined ? (
        <View style={styles.choose}>
          <Button
            label={t('mailboxes.folders.choose')}
            onPress={open}
          />
        </View>
      ) : (
        children(open)
      )}
      <Host matchContents>
        <BottomSheet
          isPresented={shown}
          onIsPresentedChange={setShown}>
          <Group modifiers={[presentationDetents(['medium', 'large'])]}>
            <RNHostView>
              <FolderSheet
                key={session}
                address={address}
                folders={folders}
                marked={marked}
                saved={saved}
                onSave={onSave}
                onClose={() => {
                  setShown(false);
                }}
              />
            </RNHostView>
          </Group>
        </BottomSheet>
      </Host>
    </>
  );
}

function FolderSheet({
  address,
  folders,
  marked,
  saved,
  onSave,
  onClose,
}: {
  readonly address: string;
  readonly folders: readonly ImapFolder[];
  readonly marked: ChosenFolders;
  readonly saved: ChosenFolders | undefined;
  readonly onSave: (chosen: ChosenFolders) => Promise<boolean>;
  readonly onClose: () => void;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const [picks, setPicks] = useState(() => startingPicks(marked, saved));
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const choice = folderChoice(t, {
    address,
    folders,
    marked,
    saved,
    picks,
    saving,
    failed,
    context: ipad ? undefined : 'iphone',
  });
  const save = async () => {
    setSaving(true);
    setFailed(false);
    const done = await onSave(choice.chosen);
    setSaving(false);
    if (done) {
      onClose();
    } else {
      setFailed(true);
    }
  };
  const row = ({
    role,
    name,
    symbol,
    server,
    pick,
    value,
    subtitle,
    missing,
    options,
  }: (typeof choice.rows)[number]) => {
    const sections = options.map((section) => ({
      items: section.map((option) => ({
        key: `folder:${option.name}`,
        title: option.title,
        symbol: '',
        ...(option.holding === undefined ? {} : { subtitle: option.holding }),
        disabled: option.taken,
        checked: option.checked,
        run: () => {
          setFailed(false);
          setPicks((previous) => ({ ...previous, [role]: option.name }));
        },
      })),
    }));
    // The placeholder and a server-marked folder read as secondary; a chosen folder as primary.
    const shown = (
      <Text
        style={[
          styles.label,
          {
            color:
              server === undefined && pick !== undefined
                ? colors.textPrimary
                : colors.textSecondary,
          },
        ]}>
        {value}
      </Text>
    );
    return (
      <View style={[styles.row, saving ? { opacity: 0.4 } : undefined]}>
        <SFSymbol
          name={symbol}
          size={17}
          color={colors.textSecondary}
        />
        <View style={styles.rowText}>
          <Text style={[styles.label, { color: colors.textPrimary }]}>
            {name}
          </Text>
          <Text
            style={[
              styles.footnote,
              {
                color: missing
                  ? colors.statusDestructive
                  : colors.textSecondary,
              },
            ]}>
            {subtitle}
          </Text>
        </View>
        {server === undefined ? (
          <MenuButton
            accessibilityLabel={name}
            accessibilityValue={{ text: value }}
            disabled={saving}
            sections={sections}>
            <View style={styles.value}>
              {shown}
              <SFSymbol
                name="chevron.up.chevron.down"
                size={12}
                color={colors.textSecondary}
              />
            </View>
          </MenuButton>
        ) : (
          shown
        )}
      </View>
    );
  };
  return (
    <View style={styles.sheet}>
      <View style={styles.header}>
        <Host matchContents>
          <SwiftUIButton
            label={t('drafts.close')}
            systemImage="xmark"
            onPress={onClose}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('glass'),
              buttonBorderShape('circle'),
              controlSize('large'),
            ]}
          />
        </Host>
        <Text
          accessibilityRole="header"
          style={[styles.title, { color: colors.textPrimary }]}>
          {choice.title}
        </Text>
        <Host matchContents>
          <SwiftUIButton
            label={t('drafts.saveAction')}
            systemImage="checkmark"
            onPress={() => {
              void save();
            }}
            modifiers={[
              labelStyle('iconOnly'),
              buttonStyle('glassProminent'),
              buttonBorderShape('circle'),
              controlSize('large'),
              tint(colors.accentFill),
              inactive(!choice.ready),
            ]}
          />
        </Host>
      </View>
      <Text style={[styles.text, { color: colors.textSecondary }]}>
        {choice.intro}
      </Text>
      <View style={[styles.group, { backgroundColor: colors.surfaceContent }]}>
        {choice.rows.map((shown, index) => (
          <View key={shown.role}>
            {index > 0 ? (
              <View
                style={[
                  styles.separator,
                  { backgroundColor: colors.separator },
                ]}
              />
            ) : null}
            {row(shown)}
          </View>
        ))}
      </View>
      {saving ? (
        <View style={styles.message}>
          <ActivityIndicator />
          <Text style={[styles.note, { color: colors.textSecondary }]}>
            {t('mailboxes.folders.saving')}
          </Text>
        </View>
      ) : null}
      {saving || choice.warning === undefined ? null : (
        <View
          accessibilityRole="alert"
          style={styles.message}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            size={ipad ? 16 : 18}
            color={colors.statusWarning}
          />
          <Text style={[styles.note, { color: colors.textPrimary }]}>
            {choice.warning}
          </Text>
        </View>
      )}
      {saving ? null : (
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {choice.note}
        </Text>
      )}
    </View>
  );
}
