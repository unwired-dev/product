import type { ImapFolder } from '@private-email/mail-core/imap-inbox';

import {
  ambiguousFolders,
  folderChoice,
  startingPicks,
} from '@private-email/mail-core/mailboxes';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { useWindowIdentifier } from './command-palette.tsx';
import { PopUp } from './composer-controls.tsx';
import { Button, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useMailboxes, useProfile } from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { windowHost } from './settings-window-client.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  sheet: { gap: spacing.m, padding: spacing.xl },
  title: textStyles.title3Emphasized,
  text: textStyles.body,
  group: { borderRadius: radius.card, borderCurve: 'continuous' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    minHeight: 44,
    paddingHorizontal: spacing.m,
  },
  rowText: { flex: 1 },
  label: textStyles.body,
  subtitle: textStyles.subheadline,
  separator: { height: StyleSheet.hairlineWidth, marginLeft: 36 },
  message: { flexDirection: 'row', alignItems: 'flex-start', gap: spacing.s },
  note: { ...textStyles.subheadline, flex: 1 },
  actions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
    paddingTop: spacing.xs,
  },
  choose: { alignSelf: 'flex-start' },
});

// Choose Folders… under an IMAP connection's not-included notice opens the choice as a sheet on
// this window.
export function FolderChoice({
  connection,
  folders,
}: {
  readonly connection: string;
  readonly folders: readonly ImapFolder[];
}) {
  const { t } = useLocalization();
  const account = use(AccountContext);
  const window = useWindowIdentifier();
  const profile = useProfile();
  if (account === undefined || ambiguousFolders(folders)) {
    return null;
  }
  return (
    <View style={styles.choose}>
      <Button
        label={t('mailboxes.folders.choose')}
        onPress={() => {
          windowHost()?.openFolderChoice(window, connection, profile);
        }}
      />
    </View>
  );
}

// The sheet's content, in its own React root: the person picks the folders that hold Spam and
// Trash for the roles its server marks no folder with. AppKit sizes the sheet to it.
export function FolderChoiceSheet({
  window,
  connection,
}: {
  readonly window: string;
  readonly connection: string;
}) {
  const account = use(AccountContext);
  const mailbox = useMailboxes().find(({ id }) => id === connection);
  const state = mailbox?.state;
  const choosing =
    account !== undefined &&
    state?.kind === 'ready' &&
    'folders' in state &&
    !ambiguousFolders(state.folders);
  // The choice closes once its connection is gone or no longer offers it.
  useEffect(() => {
    if (!choosing) {
      windowHost()?.closeSheet(window);
    }
  }, [choosing, window]);
  if (!choosing) {
    return null;
  }
  const saved = account.mailboxes.find(({ id }) => id === connection)?.folders;
  return (
    <FolderSheet
      window={window}
      address={mailbox?.address ?? state.address}
      folders={state.folders}
      marked={state.marked}
      saved={saved}
      onSave={(chosen) => account.chooseFolders(connection, chosen)}
    />
  );
}

function FolderSheet({
  window,
  address,
  folders,
  marked,
  saved,
  onSave,
}: {
  readonly window: string;
  readonly address: string;
  readonly folders: readonly ImapFolder[];
  readonly marked: Parameters<typeof startingPicks>[0];
  readonly saved: Parameters<typeof startingPicks>[1];
  readonly onSave: (
    chosen: ReturnType<typeof folderChoice>['chosen'],
  ) => Promise<boolean>;
}) {
  const { t } = useLocalization();
  const colors = usePalette();
  const [picks, setPicks] = useState(() => startingPicks(marked, saved));
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const mounted = useRef(true);
  useLayoutEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const choice = folderChoice(t, {
    address,
    folders,
    marked,
    saved,
    picks,
    saving,
    failed,
  });
  const close = () => {
    windowHost()?.closeSheet(window);
  };
  const save = async () => {
    setSaving(true);
    setFailed(false);
    const done = await onSave(choice.chosen);
    // This window may already show a replacement sheet after Cancel.
    if (!mounted.current) {
      return;
    }
    if (done) {
      close();
    } else {
      setSaving(false);
      setFailed(true);
    }
  };
  return (
    <View
      style={styles.sheet}
      onLayout={({ nativeEvent }) => {
        windowHost()?.fitSheet(window, nativeEvent.layout.height);
      }}>
      <Text
        accessibilityRole="header"
        style={[styles.title, { color: colors.textPrimary }]}>
        {choice.title}
      </Text>
      <Text style={[styles.text, { color: colors.textPrimary }]}>
        {choice.intro}
      </Text>
      <View style={[styles.group, { backgroundColor: colors.fillQuiet }]}>
        {choice.rows.map((row, index) => (
          <View key={row.role}>
            {index === 0 ? null : (
              <View
                style={[
                  styles.separator,
                  { backgroundColor: colors.separator },
                ]}
              />
            )}
            <View style={styles.row}>
              <SFSymbol
                name={row.symbol}
                color={colors.textSecondary}
                size={16}
              />
              <View style={styles.rowText}>
                <Text style={[styles.label, { color: colors.textPrimary }]}>
                  {row.name}
                </Text>
                <Text
                  style={[
                    styles.subtitle,
                    {
                      color: row.missing
                        ? colors.statusDestructive
                        : colors.textSecondary,
                    },
                  ]}>
                  {row.subtitle}
                </Text>
              </View>
              {row.server === undefined ? (
                <PopUp
                  label={row.value}
                  accessibilityLabel={row.name}
                  disabled={saving}
                  sections={row.options.map((section) => ({
                    items: section.map((option) => ({
                      key: option.name,
                      title: option.title,
                      subtitle: option.holding,
                      checked: option.checked,
                      disabled: option.taken,
                      run: () => {
                        setPicks((current) => ({
                          ...current,
                          [row.role]: option.name,
                        }));
                        setFailed(false);
                      },
                    })),
                  }))}
                />
              ) : (
                <Text style={[styles.label, { color: colors.textSecondary }]}>
                  {row.value}
                </Text>
              )}
            </View>
          </View>
        ))}
      </View>
      {choice.warning === undefined ? null : (
        <View style={styles.message}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            color={colors.statusWarning}
            size={13}
          />
          <Text
            accessibilityRole="alert"
            style={[styles.note, { color: colors.textPrimary }]}>
            {choice.warning}
          </Text>
        </View>
      )}
      <Text style={[styles.subtitle, { color: colors.textSecondary }]}>
        {choice.note}
      </Text>
      <View style={styles.actions}>
        <Button
          label={t('common.cancel')}
          isCancel
          onPress={close}
        />
        <Button
          label={t('drafts.saveAction')}
          fill="accent"
          isDefault
          disabled={!choice.ready}
          onPress={() => {
            void save();
          }}
        />
      </View>
      {saving ? (
        <View style={styles.message}>
          <ActivityIndicator size="small" />
          <Text style={[styles.note, { color: colors.textSecondary }]}>
            {t('mailboxes.folders.saving')}
          </Text>
        </View>
      ) : null}
    </View>
  );
}
