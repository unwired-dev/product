import type { Translate } from '@private-email/localization';
import type { MailboxProblem } from '@private-email/mail-core/mailboxes';
import type { MailProvider } from '@private-email/mail-core/registration';

import {
  failedFolders,
  gmailMailbox,
  gmailViewRow,
  mailboxSidebar,
} from '@private-email/mail-core/mailboxes';
import {
  profileMenu,
  profileMonogram,
  profileName,
} from '@private-email/mail-core/profile-windows';
import { radius, spacing } from '@private-email/mail-core/theme';
import { Fragment, use, useState, useSyncExternalStore } from 'react';
import {
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { MenuButton, SFSymbol } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import {
  useAllMailboxes,
  useMailboxes,
  useProfile,
  useReloadMailboxes,
} from './mailbox.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette } from './theme.ts';

// What the message list shows: every mailbox of the Profile, one mailbox, or one of its IMAP
// folders. The Inbox folder is the default of a mailbox.
export type MailboxView = Readonly<{
  mailbox?: string | undefined;
  folder?: string | undefined;
}>;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: { paddingHorizontal: spacing.xl, paddingVertical: spacing.l },
  title: { ...textStyles.title3Emphasized },
  list: { paddingHorizontal: spacing.s, paddingBottom: spacing.l },
  section: {
    ...textStyles.subheadline,
    fontWeight: '600',
    paddingHorizontal: spacing.s,
    paddingTop: spacing.m,
    paddingBottom: spacing.xs,
  },
  row: {
    minHeight: 28,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.s,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  label: { ...textStyles.body, flex: 1 },
  count: { ...textStyles.body },
  footer: {
    marginHorizontal: spacing.s,
    paddingVertical: spacing.s,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  switcher: {
    minHeight: 28,
    marginBottom: spacing.xs,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  switcherRow: {
    flexGrow: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.xs,
  },
  monogram: {
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
  monogramText: { ...textStyles.subheadline, fontWeight: '600' },
  switcherName: { ...textStyles.bodyEmphasized, flex: 1 },
});

// The window's Profile Switcher: its Mail Profile's monogram, name and chevron. Its system menu
// switches this window's Profile or names a new one.
function ProfileSwitcher({
  onProfile,
}: {
  readonly onProfile: (profile: string) => void;
}) {
  const account = use(AccountContext);
  const profile = useProfile();
  const mailboxes = useAllMailboxes();
  const colors = usePalette();
  const { t } = useLocalization();
  if (account === undefined) {
    return null;
  }
  const { profiles } = account;
  const name = profileName(t, profile, profiles);
  const create = async (entered: string) => {
    const failure = await account.createProfile(entered);
    if (failure !== undefined) {
      Alert.alert(
        failure === 'upgrade-required'
          ? t('profiles.upgradeTitle')
          : t('profiles.newTitle'),
        failure === 'upgrade-required'
          ? t('profiles.upgradeMessage')
          : t('profiles.failed'),
        [{ text: t('profiles.ok') }],
      );
    }
  };
  return (
    <MenuButton
      accessibilityLabel={t('profiles.switcher', { name })}
      sections={profileMenu(t, {
        profiles,
        connections: account.mailboxes,
        mailboxes,
        current: profile,
        onSwitch: onProfile,
        onCreate: () => {
          Alert.promptMacOS(
            t('profiles.newTitle'),
            t('profiles.newMessage'),
            [
              {
                text: t('profiles.create'),
                onPress: (entered?: string) => {
                  if (entered !== undefined && entered.trim() !== '') {
                    void create(entered);
                  }
                },
              },
              { text: t('common.cancel'), style: 'cancel' },
            ],
            'plain-text',
            [{ placeholder: t('profiles.name') }],
          );
        },
      })}
      style={[styles.switcher, { backgroundColor: colors.fillQuiet }]}>
      <View style={styles.switcherRow}>
        <View
          style={[styles.monogram, { backgroundColor: colors.brandMonogram }]}>
          <Text style={[styles.monogramText, { color: colors.brandOnDeep }]}>
            {profileMonogram(name)}
          </Text>
        </View>
        <Text
          numberOfLines={1}
          style={[styles.switcherName, { color: colors.textPrimary }]}>
          {name}
        </Text>
        <SFSymbol
          name="chevron.down"
          color={colors.textSecondary}
          size={10}
        />
      </View>
    </MenuButton>
  );
}

// A sidebar item: tinted symbol, label and unread count; selection shows as fill and weight.
function Item({
  icon,
  label,
  accessibilityLabel = label,
  count = 0,
  status,
  selected = false,
  onPress,
}: {
  readonly icon: string;
  readonly label: string;
  readonly accessibilityLabel?: string;
  readonly count?: number;
  // A problem beside the mailbox, in place of its count.
  readonly status?: string | undefined;
  readonly selected?: boolean;
  readonly onPress: () => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [focused, setFocused] = useState(false);
  const value =
    status ?? (count === 0 ? undefined : t('mailboxes.unread', { count }));
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      accessibilityValue={value === undefined ? undefined : { text: value }}
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
        (selected || pressed) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
        { borderColor: focused ? colors.accentInk : 'transparent' },
      ]}>
      <SFSymbol
        name={icon}
        color={colors.accentInk}
      />
      <Text
        numberOfLines={1}
        style={[
          styles.label,
          selected && { fontWeight: '600' },
          { color: colors.textPrimary },
        ]}>
        {label}
      </Text>
      {status === undefined ? null : (
        <SFSymbol
          name="exclamationmark.triangle"
          color={colors.statusWarning}
        />
      )}
      {count === 0 || status !== undefined ? null : (
        <Text style={[styles.count, { color: colors.textSecondary }]}>
          {count}
        </Text>
      )}
    </Pressable>
  );
}

function SectionHeader({ label }: { readonly label: string }) {
  const colors = usePalette();
  return (
    <Label
      accessibilityRole="header"
      numberOfLines={1}
      style={[styles.section, { color: colors.textSecondary }]}>
      {label}
    </Label>
  );
}

// The problem beside a mailbox, in the words its Inbox notice uses.
const problemText = (
  t: Translate,
  problem: MailboxProblem | undefined,
  {
    provider,
    name,
  }: Readonly<{ provider: MailProvider | undefined; name: string }>,
) => {
  if (problem === undefined) {
    return undefined;
  }
  if (problem === 'locked' || problem === 'failed') {
    return t(`storage.${problem}`);
  }
  return provider === 'imap'
    ? t(`imapSync.${problem}`)
    : t(`gmailSync.${problem}`, { provider: name });
};

const noSubscription = () => () => undefined;

// A Mailbox Connection's folder rows: an IMAP connection's folders, or a Gmail mailbox's Inbox,
// labels, All Mail, Spam and Trash. A folder or view whose last read failed keeps its warning
// after another mailbox is chosen; the connection's own problem rides on its Inbox row.
function FolderRows({
  mailbox,
  folders,
  trouble,
  onView,
}: {
  readonly mailbox: InboxMailbox;
  readonly folders: ReadonlyArray<
    Readonly<{
      name: string;
      inbox: boolean;
      unread: number;
      selected: boolean;
    }>
  >;
  readonly trouble: string | undefined;
  readonly onView: (view: MailboxView) => void;
}) {
  const { t } = useLocalization();
  const { inbox } = mailbox;
  const name = mailbox.address ?? mailbox.id;
  const names = folders.map((folder) => folder.name);
  // JSON strings escape folder-name newlines while keeping the joined snapshot stable.
  const failed = useSyncExternalStore(
    'openFolder' in inbox ? inbox.subscribe : noSubscription,
    () =>
      'openFolder' in inbox
        ? failedFolders(inbox, names)
            .map((folder) => JSON.stringify(folder))
            .join('\n')
        : '',
  ).split('\n');
  const gmail = gmailMailbox(mailbox);
  // A folder or Gmail view's name, SF Symbol and failed-read notice.
  const row = (folder: string, isInbox: boolean) => {
    if (gmail !== undefined) {
      return gmailViewRow(t, gmail.state, folder);
    }
    return {
      title: isInbox ? t('inbox.title') : folder,
      icon: isInbox ? 'tray' : 'folder',
      failure: failed.includes(JSON.stringify(folder))
        ? t('imap.foldersUnavailable')
        : undefined,
    };
  };
  return folders.map(({ name: folder, inbox: isInbox, unread, selected }) => {
    const { title: label, icon, failure } = row(folder, isInbox);
    return (
      <Item
        key={folder}
        icon={icon}
        label={label}
        accessibilityLabel={t('inbox.rowLabel_mailbox', {
          row: label,
          mailbox: name,
        })}
        count={unread}
        status={isInbox ? trouble : failure}
        selected={selected}
        onPress={() => {
          onView({
            mailbox: mailbox.id,
            folder: isInbox ? undefined : folder,
          });
          if ('openFolder' in inbox) {
            void inbox.openFolder(folder);
          }
        }}
      />
    );
  });
}

// The Mailboxes of the window's Profile: every Inbox together, then each Mailbox Connection with
// its folders, and the account page last.
export function Mailboxes({
  view,
  onView,
  onProfile,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  // Switches the window to another Mail Profile.
  readonly onProfile: (profile: string) => void;
}) {
  const mailboxes = useMailboxes();
  const account = use(AccountContext);
  const profile = useProfile();
  const reload = useReloadMailboxes();
  const colors = usePalette();
  const { t } = useLocalization();
  const sidebar = mailboxSidebar({
    mailboxes,
    connections: account?.mailboxes ?? [],
    profile,
    view,
  });
  const authorize = async (connection: string) => {
    await account?.authorizeMailbox(connection);
    await reload();
  };
  return (
    <View style={styles.fill}>
      <View style={styles.fill}>
        <View style={styles.heading}>
          <Label
            accessibilityRole="header"
            style={[styles.title, { color: colors.textPrimary }]}>
            {t('mailboxes.title')}
          </Label>
        </View>
        <ScrollView
          style={styles.fill}
          contentContainerStyle={styles.list}>
          <ProfileSwitcher onProfile={onProfile} />
          <SectionHeader label={t('mailboxes.favorites')} />
          <Item
            icon="tray.2"
            label={t('inbox.allInboxes')}
            count={sidebar.unread}
            selected={sidebar.allSelected}
            onPress={() => {
              onView({});
            }}
          />
          {sidebar.entries.map((entry) => {
            if ('section' in entry) {
              const { mailbox, folders, problem } = entry.section;
              const name = mailbox.address ?? mailbox.id;
              const provider = t(
                `mailProviders.${mailbox.provider ?? 'gmail'}`,
              );
              const trouble = problemText(t, problem, {
                provider: mailbox.provider,
                name: provider,
              });
              return (
                <Fragment key={mailbox.id}>
                  <SectionHeader label={`${provider} · ${name}`} />
                  <FolderRows
                    mailbox={mailbox}
                    folders={folders}
                    trouble={trouble}
                    onView={onView}
                  />
                </Fragment>
              );
            }
            const { connection, recovery, selected } = entry.waiting;
            const provider = t(`mailProviders.${connection.provider}`);
            const imap = recovery === 'account';
            return (
              <Fragment key={connection.id}>
                <SectionHeader label={`${provider} · ${connection.address}`} />
                <Item
                  icon="tray"
                  label={t('inbox.title')}
                  accessibilityLabel={t('inbox.rowLabel_mailbox', {
                    row: t('inbox.title'),
                    mailbox: connection.address,
                  })}
                  status={
                    imap
                      ? t('mailboxes.states.imap-authorization')
                      : t('mailboxes.states.authorization', { provider })
                  }
                  selected={selected}
                  onPress={() => {
                    // IMAP needs its password entered again in Settings' Email Accounts.
                    if (imap) {
                      account?.openAccount('mailboxes');
                    } else {
                      void authorize(connection.id);
                    }
                  }}
                />
              </Fragment>
            );
          })}
        </ScrollView>
        {account === undefined ? null : (
          <View style={[styles.footer, { borderTopColor: colors.separator }]}>
            <Item
              icon="gearshape"
              label={t('inbox.account')}
              onPress={() => {
                account.openAccount();
              }}
            />
          </View>
        )}
      </View>
    </View>
  );
}
