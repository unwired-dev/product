import type { ImapFolder } from '@private-email/mail-core/imap-inbox';
import type { ChosenFolders } from '@private-email/mail-core/registration';

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
import { inboxFolder } from '@private-email/mail-core/imap-inbox';
import { radius, spacing } from '@private-email/mail-core/theme';
import { use, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Button, MenuButton, SFSymbol } from './design.tsx';
import { ipad } from './inbox-styles.ts';
import { useLocalization } from './localization.ts';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

const roles = ['junk', 'trash'] as const;
type Role = (typeof roles)[number];
const otherRole = (role: Role) => (role === 'junk' ? 'trash' : 'junk');

// The roles a folder keeps out of both choices, as the menu names them.
const otherRoles = {
  inbox: 'inbox.title',
  sent: 'mailboxes.sent',
  drafts: 'drafts.heading',
  archive: 'mailboxes.archive',
  all: 'mailboxes.allMail',
  flagged: 'mailboxes.flagged',
} as const;

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

// Choose Folders… under an IMAP connection's not-included notice: a sheet where the person
// picks the folders that hold Spam and Trash for the roles its server marks no folder with. A
// server marking several folders with a role is left out of All Mail, since a choice can't say
// what the others hold.
export function FolderChoice({
  connection,
  address,
  folders,
  marked,
}: {
  readonly connection: string;
  readonly address: string;
  readonly folders: readonly ImapFolder[];
  readonly marked: ChosenFolders;
}) {
  const { t } = useLocalization();
  const account = use(AccountContext);
  const [shown, setShown] = useState(false);
  const [session, setSession] = useState(0);
  const ambiguous = roles.some(
    (role) =>
      folders.filter(
        (folder) => folder.selectable && folder.roles.includes(role),
      ).length > 1,
  );
  if (account === undefined || ambiguous) {
    return null;
  }
  const saved = account.mailboxes.find(({ id }) => id === connection)?.folders;
  return (
    <>
      <View style={styles.choose}>
        <Button
          label={t('mailboxes.folders.choose')}
          onPress={() => {
            setSession((previous) => previous + 1);
            setShown(true);
          }}
        />
      </View>
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
                onSave={(chosen) => account.chooseFolders(connection, chosen)}
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
  marked: serverMarked,
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
  const marked = (role: Role) => serverMarked[role];
  const open = roles.filter((role) => marked(role) === undefined);
  const [picks, setPicks] = useState<ChosenFolders>(() =>
    Object.fromEntries(open.map((role) => [role, saved?.[role]])),
  );
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const exists = (name: string | undefined) =>
    folders.some((folder) => folder.selectable && folder.name === name);
  const missing = open.filter(
    (role) => picks[role] !== undefined && !exists(picks[role]),
  );
  const [gone] = missing;
  const changing = saved !== undefined;
  const save = async () => {
    setSaving(true);
    setFailed(false);
    const done = await onSave(
      Object.fromEntries(open.map((role) => [role, picks[role]])),
    );
    setSaving(false);
    if (done) {
      onClose();
    } else {
      setFailed(true);
    }
  };
  const roleName = (role: Role) =>
    t(role === 'junk' ? 'mailboxes.spam' : 'mailboxes.trash');
  const holding = (role: Role, folder: ImapFolder) =>
    folder.name === (marked(otherRole(role)) ?? picks[otherRole(role)])
      ? roleName(otherRole(role))
      : Object.entries(otherRoles)
          .filter(([key]) => folder.roles.includes(key))
          .map(([, key]) => t(key))[0];
  // Menus and Save accept the same folders, including after a server listing changes.
  const taken = (role: Role, folder: ImapFolder) =>
    folder.name === inboxFolder || holding(role, folder) !== undefined;
  const ready =
    !saving &&
    open.every((role) =>
      folders.some(
        (folder) =>
          folder.selectable &&
          folder.name === picks[role] &&
          !taken(role, folder),
      ),
    );
  const menu = (role: Role) => {
    const item = (folder: ImapFolder) => {
      const subtitle =
        folder.name === inboxFolder ? undefined : holding(role, folder);
      return {
        key: `folder:${folder.name}`,
        title: folder.name === inboxFolder ? t('inbox.title') : folder.name,
        symbol: '',
        ...(subtitle === undefined ? {} : { subtitle }),
        disabled: taken(role, folder),
        checked: picks[role] === folder.name,
        run: () => {
          setFailed(false);
          setPicks((previous) => ({ ...previous, [role]: folder.name }));
        },
      };
    };
    const listed = folders.filter(({ selectable }) => selectable);
    return [
      { items: listed.filter((folder) => taken(role, folder)).map(item) },
      { items: listed.filter((folder) => !taken(role, folder)).map(item) },
    ].filter(({ items }) => items.length > 0);
  };
  const row = (role: Role) => {
    const server = marked(role);
    const pick = picks[role];
    const was = saved?.[role];
    const subtitle = () => {
      if (server !== undefined) {
        return t('mailboxes.folders.marked');
      }
      if (pick === undefined) {
        return t('mailboxes.folders.unmarked');
      }
      if (missing.includes(role)) {
        return t('mailboxes.folders.unavailable');
      }
      return was !== undefined && was !== pick && exists(was)
        ? t('mailboxes.folders.changed', { folder: was })
        : t('mailboxes.folders.chosen');
    };
    // The placeholder and a server-marked folder read as secondary; a chosen folder as primary.
    const value = (
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
        {server ?? pick ?? t('mailboxes.folders.placeholder')}
      </Text>
    );
    return (
      <View style={[styles.row, saving ? { opacity: 0.4 } : undefined]}>
        <SFSymbol
          name={role === 'junk' ? 'xmark.bin' : 'trash'}
          size={17}
          color={colors.textSecondary}
        />
        <View style={styles.rowText}>
          <Text style={[styles.label, { color: colors.textPrimary }]}>
            {roleName(role)}
          </Text>
          <Text
            style={[
              styles.footnote,
              {
                color: missing.includes(role)
                  ? colors.statusDestructive
                  : colors.textSecondary,
              },
            ]}>
            {subtitle()}
          </Text>
        </View>
        {server === undefined ? (
          <MenuButton
            accessibilityLabel={roleName(role)}
            accessibilityValue={{
              text: pick ?? t('mailboxes.folders.placeholder'),
            }}
            disabled={saving}
            sections={menu(role)}>
            <View style={styles.value}>
              {value}
              <SFSymbol
                name="chevron.up.chevron.down"
                size={12}
                color={colors.textSecondary}
              />
            </View>
          </MenuButton>
        ) : (
          value
        )}
      </View>
    );
  };
  // Changing a saved choice, choosing the one role its server leaves unmarked, or choosing both.
  const single = open.length === 1 ? open[0] : undefined;
  let kind: 'change' | 'single' | 'both' = 'both';
  if (changing) {
    kind = 'change';
  } else if (single !== undefined) {
    kind = 'single';
  }
  const values = {
    address,
    role: roleName(single ?? 'junk'),
    marked: roleName(otherRole(single ?? 'junk')),
    ...(ipad ? {} : { context: 'iphone' }),
  };
  const note =
    changing && (gone !== undefined || failed)
      ? t('mailboxes.folders.updateNote')
      : t(`mailboxes.folders.${kind}.${ready ? 'readyNote' : 'note'}`, values);
  const lost =
    gone === undefined
      ? undefined
      : t('mailboxes.folders.gone', {
          folder: picks[gone],
          role: roleName(gone),
        });
  const warning = failed ? t('mailboxes.folders.saveFailed') : lost;
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
          {t(`mailboxes.folders.${kind}.title`, values)}
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
              inactive(!ready),
            ]}
          />
        </Host>
      </View>
      <Text style={[styles.text, { color: colors.textSecondary }]}>
        {t(`mailboxes.folders.${kind}.intro`, values)}
      </Text>
      <View style={[styles.group, { backgroundColor: colors.surfaceContent }]}>
        {roles.map((role, index) => (
          <View key={role}>
            {index > 0 ? (
              <View
                style={[
                  styles.separator,
                  { backgroundColor: colors.separator },
                ]}
              />
            ) : null}
            {row(role)}
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
      {saving || warning === undefined ? null : (
        <View
          accessibilityRole="alert"
          style={styles.message}>
          <SFSymbol
            name="exclamationmark.triangle.fill"
            size={ipad ? 16 : 18}
            color={colors.statusWarning}
          />
          <Text style={[styles.note, { color: colors.textPrimary }]}>
            {warning}
          </Text>
        </View>
      )}
      {saving ? null : (
        <Text style={[styles.text, { color: colors.textSecondary }]}>
          {note}
        </Text>
      )}
    </View>
  );
}
