import type { Translate } from '@private-email/localization';
import type {
  Favorite,
  FavoriteEntries,
  MailboxProblem,
  UnifiedRole,
} from '@private-email/mail-core/mailboxes';
import type { MailProvider } from '@private-email/mail-core/registration';

import { Host, Button as SwiftUIButton } from '@expo/ui/swift-ui';
import {
  buttonBorderShape,
  buttonStyle,
  controlSize,
  labelStyle,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { sidebarCommands } from '@private-email/mail-core/commands';
import {
  allInboxes,
  failedFolders,
  favoriteRows,
  gmailMailbox,
  gmailViewRow,
  mailboxSidebar,
  moveFavorite,
  toggleFavorite,
  unifiedRow,
} from '@private-email/mail-core/mailboxes';
import {
  profileMenu,
  profileName,
  profileStyle,
} from '@private-email/mail-core/profile-windows';
import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { Fragment, use, useRef, useState, useSyncExternalStore } from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SafeAreaView } from 'react-native-screens/experimental';

import type { InboxMailbox } from './private-storage.ts';
import type { SettingsDestination } from './settings.tsx';

import { RegisterCommands, usePaletteHeader } from './command-palette.tsx';
import {
  GlassGroup,
  MenuButton,
  NavigationChrome,
  SFSymbol,
  SignInNotice,
} from './design.tsx';
import { BarSpacer, FloatingBar, NewMessageButton } from './inbox-bar.tsx';
import { InboxPreferencesContext } from './list-density.tsx';
import { useLocalization } from './localization.ts';
import { useAllMailboxes } from './mailbox-state.ts';
import { useMailboxes, useProfile, useReloadMailboxes } from './mailbox.tsx';
import { useProfileOutbox } from './outbox.tsx';
import { ProfileMonogram, promptNewProfile } from './profile-settings.tsx';
import { AccountContext } from './registration-gate.tsx';
import { SidebarToggle, SidebarToggleContext } from './sidebar-toggle.tsx';
import { limited } from './sync-status.tsx';
import {
  textStyles,
  useLargeText,
  usePalette,
  useProfilePalette,
} from './theme.ts';

// What the message list shows: every mailbox of the Profile, one mailbox, one of its folders, a
// Unified Mailbox of every mailbox, or the Profile's Outbox. The Inbox folder is the default of a
// mailbox.
export type MailboxView = Readonly<{
  mailbox?: string | undefined;
  folder?: string | undefined;
  unified?: UnifiedRole | undefined;
  outbox?: boolean | undefined;
}>;

const compact = Platform.OS === 'ios' && !Platform.isPad;

const sectionText = {
  ...typography.ipadList.subheadline,
  fontWeight: '600',
} as const;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // iPhone's title sits centered between an empty slot and Account.
  compactHeading: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
  },
  // Edit, or Done, and Account share the trailing half of the header, so the title stays centered.
  headingActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: spacing.s,
  },
  accountGlass: {
    padding: 0,
    borderRadius: 22,
    backgroundColor: 'transparent',
  },
  accountButton: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // The frames set the title 12pt below the header's top, 3pt above its centre.
  title: { ...textStyles.headline, textAlign: 'center', paddingBottom: 6 },
  grow: { flex: 1 },
  list: { paddingBottom: spacing.l },
  // The last rows scroll clear of the floating New Message; the Profile Switcher sits 14pt below
  // the header.
  compactList: {
    paddingHorizontal: spacing.l,
    paddingTop: 14,
    paddingBottom: 72,
  },
  group: {
    borderRadius: radius.mailboxGroup,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  // The frames' 28pt section header with 10pt above and below it.
  compactSection: {
    ...textStyles.headline,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.l,
    paddingBottom: 10,
  },
  // The frames' header with a problem: the warning 6pt after the title, which truncates before it.
  compactSectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.l,
    paddingBottom: 10,
  },
  // The Authorization Needed banner sits 10pt above the connection's folders.
  compactNotice: { marginBottom: 10 },
  // Each symbol takes a 24pt slot, so the labels share the frames' x68 axis.
  compactRow: {
    minHeight: 52,
    gap: spacing.m,
    paddingHorizontal: spacing.l,
    borderRadius: 0,
  },
  compactIcon: { width: 24, alignItems: 'center' },
  separator: { height: StyleSheet.hairlineWidth, marginHorizontal: spacing.l },
  // In Edit mode iPhone's hairlines start at the label, 90pt in, and run to the group's edge.
  editSeparator: { marginLeft: 90, marginRight: 0 },
  // The iPad sidebar follows the Mac recipe at 1.15×, as its frames draw it.
  section: {
    ...sectionText,
    paddingHorizontal: spacing.s * ipadListScale,
    paddingTop: spacing.m * ipadListScale,
    paddingBottom: spacing.xs * ipadListScale,
  },
  // A Mailbox Connection's header with its problem: the title truncates before the warning.
  sectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs * ipadListScale,
    paddingHorizontal: spacing.s * ipadListScale,
    paddingTop: spacing.m * ipadListScale,
    paddingBottom: spacing.xs * ipadListScale,
  },
  sectionTitle: { ...sectionText, flexShrink: 1 },
  // iPhone's title fills the header, so the warning keeps to its trailing end.
  compactSectionTitle: { ...textStyles.headline, flex: 1 },
  row: {
    minHeight: 28 * ipadListScale,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s * ipadListScale,
    paddingHorizontal: spacing.s * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  // An Edit Favorites row: checkmark, symbol, name and drag handle, 8pt apart in their slots.
  editRow: { gap: spacing.s },
  // iPhone's 52pt Edit row: its 26pt slots 12pt apart, 14pt from the group's leading edge and 18pt
  // from its trailing one.
  compactEditRow: {
    minHeight: 52,
    gap: spacing.m,
    paddingLeft: 14,
    paddingRight: 18,
    borderRadius: 0,
  },
  checkSlot: { width: 18, alignItems: 'center' },
  editIcon: { width: 20, alignItems: 'center' },
  compactSlot: { width: 26, alignItems: 'center' },
  handle: { alignSelf: 'stretch', justifyContent: 'center' },
  label: { ...typography.ipadList.body, flex: 1 },
  compactLabel: { ...textStyles.body, flex: 1 },
  compactCount: { ...textStyles.subheadline },
  count: { ...typography.ipadList.body },
  // As the frames draw it, Settings sits 6.9pt beneath their 1.15pt rule and 11.2pt above the
  // panel's edge.
  footer: {
    paddingTop: 6 * ipadListScale,
    paddingBottom: 11.2,
    borderTopWidth: ipadListScale,
  },
  switcher: {
    minHeight: 28 * ipadListScale,
    marginBottom: spacing.xs * ipadListScale,
    borderRadius: radius.control * ipadListScale,
    borderCurve: 'continuous',
  },
  // The floating sidebar panel, inset 8pt from the column beneath the status bar and from the
  // window's bottom edge, as the frames draw it from y40 to y826: 271.4pt wide in the 286pt column,
  // its rows and footer 9.2pt inside it.
  panel: {
    flex: 1,
    margin: spacing.s,
    marginRight: 286 - spacing.s - 271.4,
    paddingHorizontal: spacing.s * ipadListScale,
    borderRadius: radius.window * ipadListScale,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
  },
  // The window controls' row of the panel: its sidebar toggle at the trailing end, 11.8pt below the
  // panel's top edge on the top row's centre line, and the Profile Switcher 57.5pt below it.
  panelTop: {
    height: 57.5,
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'flex-end',
    gap: 9,
    paddingTop: 11.8,
  },
  // Edit and Done keep the toggle's 32.2pt height, centered on its row.
  panelButton: { height: 28 * ipadListScale, justifyContent: 'center' },
  compactSwitcher: {
    minHeight: 48,
    marginBottom: spacing.s,
    borderRadius: radius.profileSwitcher,
  },
  switcherRow: {
    flexGrow: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    paddingHorizontal: spacing.s,
  },
  // iPhone fills the row itself, since the native menu host's fill would draw twice, 12pt in with
  // 12pt beside its monogram.
  compactSwitcherRow: {
    minHeight: 48,
    gap: spacing.m,
    paddingHorizontal: spacing.m,
    borderRadius: radius.profileSwitcher,
    borderCurve: 'continuous',
  },
  switcherName: { ...typography.ipadList.body, fontWeight: '600', flex: 1 },
  compactSwitcherName: { ...textStyles.headline, flex: 1 },
});

// The window's Profile Switcher: its Mail Profile's monogram, name and chevron. Its system menu
// switches this window's Profile or names a new one.
function ProfileSwitcher({
  onProfile,
  onManage,
}: {
  readonly onProfile: (profile: string) => void;
  // Opens Settings on Mail Profiles.
  readonly onManage: () => void;
}) {
  const account = use(AccountContext);
  const profile = useProfile();
  const mailboxes = useAllMailboxes();
  const colors = usePalette();
  const fills = useProfilePalette();
  const { t } = useLocalization();
  if (account === undefined) {
    return null;
  }
  const { profiles } = account;
  const name = profileName(t, profile, profiles);
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
          promptNewProfile(t, account.createProfile);
        },
        onManage,
        fills,
      })}
      style={[
        styles.switcher,
        compact
          ? styles.compactSwitcher
          : { backgroundColor: colors.fillQuiet },
      ]}>
      <View
        style={[
          styles.switcherRow,
          compact && [
            styles.compactSwitcherRow,
            { backgroundColor: colors.fillQuiet },
          ],
        ]}>
        <ProfileMonogram
          name={name}
          style={profileStyle(profiles, profile)}
          size={28}
        />
        <Text
          numberOfLines={1}
          style={[
            compact ? styles.compactSwitcherName : styles.switcherName,
            { color: colors.textPrimary },
          ]}>
          {name}
        </Text>
        <SFSymbol
          name="chevron.down"
          color={colors.textSecondary}
          size={12}
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
  // At accessibility text sizes labels wrap, as UIKit's sidebar lists do.
  const large = useLargeText();
  const value =
    status ?? (count === 0 ? undefined : t('mailboxes.unread', { count }));
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ selected }}
      accessibilityValue={value === undefined ? undefined : { text: value }}
      onPress={onPress}
      style={({ pressed }) => [
        styles.row,
        compact && styles.compactRow,
        (selected || pressed) && {
          backgroundColor: colors.accentSelectionSubtle,
        },
      ]}>
      <View style={compact && styles.compactIcon}>
        <SFSymbol
          name={icon}
          color={colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          compact ? styles.compactLabel : styles.label,
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
        <Text
          style={[
            compact ? styles.compactCount : styles.count,
            { color: colors.textSecondary },
          ]}>
          {count}
        </Text>
      )}
      {compact ? (
        <SFSymbol
          name="chevron.right"
          color={colors.textSecondary}
          size={12}
        />
      ) : null}
    </Pressable>
  );
}

// A section's header. A Mailbox Connection's problem shows as a warning beside its title, on iPad
// the frames' 13pt glyph at 1.15× and on iPhone at the title's 17pt, and VoiceOver reads it with
// the header.
function SectionHeader({
  label,
  trouble,
}: {
  readonly label: string;
  readonly trouble?: string | undefined;
}) {
  const colors = usePalette();
  const large = useLargeText();
  if (trouble === undefined) {
    return (
      <Text
        accessibilityRole="header"
        numberOfLines={large ? 0 : 1}
        style={[
          styles.section,
          compact && styles.compactSection,
          { color: compact ? colors.textPrimary : colors.textSecondary },
        ]}>
        {label}
      </Text>
    );
  }
  return (
    <View
      accessible
      accessibilityRole="header"
      accessibilityLabel={`${label}, ${trouble}`}
      style={compact ? styles.compactSectionRow : styles.sectionRow}>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          styles.sectionTitle,
          compact && styles.compactSectionTitle,
          { color: compact ? colors.textPrimary : colors.textSecondary },
        ]}>
        {label}
      </Text>
      <SFSymbol
        name="exclamationmark.triangle.fill"
        color={colors.statusWarning}
        size={compact ? 17 : 12.5 * ipadListScale}
      />
    </View>
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
// after another mailbox is chosen. The connection's own problem rides on its header.
function FolderRows({
  mailbox,
  folders,
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
  readonly onView: (view: MailboxView) => void;
}) {
  const colors = usePalette();
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
      return gmailViewRow(t, gmail, folder);
    }
    return {
      title: isInbox ? t('inbox.title') : folder,
      icon: isInbox ? 'tray' : 'folder',
      failure: failed.includes(JSON.stringify(folder))
        ? t('imap.foldersUnavailable')
        : undefined,
    };
  };
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {folders.map(
        ({ name: folder, inbox: isInbox, unread, selected }, index) => {
          const { title: label, icon, failure } = row(folder, isInbox);
          return (
            <Fragment key={folder}>
              {compact && index > 0 ? (
                <View
                  style={[
                    styles.separator,
                    { backgroundColor: colors.separator },
                  ]}
                />
              ) : null}
              <Item
                icon={icon}
                label={label}
                accessibilityLabel={t('inbox.rowLabel_mailbox', {
                  row: label,
                  mailbox: name,
                })}
                count={unread}
                status={failure}
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
            </Fragment>
          );
        },
      )}
    </View>
  );
}

// A Favorites row's symbol and name.
const favoriteRow = (t: Translate, row: Favorite) =>
  row === allInboxes
    ? { title: t('inbox.allInboxes'), icon: 'tray.2' }
    : unifiedRow(t, row);

// The window's Profile's Favorites as its Inbox preferences keep them, which its other Trusted
// Devices share.
function useFavorites(profile: string) {
  const store = use(InboxPreferencesContext);
  const entries = useSyncExternalStore(store.subscribe, () =>
    store.favorites(profile),
  );
  return {
    entries,
    // Applies `change` to the stored rows, so an edit made before the last one is read keeps it.
    // Resolves the rows it stored, or undefined when storage failed.
    change: async (change: (stored: FavoriteEntries) => FavoriteEntries) =>
      (await store.changeFavorites(profile, change))
        ? favoriteRows(store.favorites(profile))
        : undefined,
  };
}

// A Favorites row in Edit mode: the checkmark that shows or hides it, its symbol and name, and the
// handle that drags it to another place. Tapping the row shows or hides it, except All Inboxes,
// which stays shown; Move Up and Move Down reorder it with VoiceOver and Full Keyboard Access.
function EditRow({
  row,
  shown,
  moves,
  offset,
  onToggle,
  onMove,
  onDrag,
  onDrop,
}: {
  readonly row: Favorite;
  readonly shown: boolean;
  // Which ways the row can move by one place.
  readonly moves: Readonly<{ up: boolean; down: boolean }>;
  // How far the finger drags the row from where it shows, while it does.
  readonly offset: number | undefined;
  readonly onToggle: () => void;
  readonly onMove: (by: -1 | 1) => void;
  // How far the finger moved since the drag began, and the row's height.
  readonly onDrag: (dy: number, height: number) => void;
  // Where the finger let go, as far from where the drag began, and the row's height; undefined
  // when the drag was cancelled.
  readonly onDrop: (dy: number | undefined, height: number) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const large = useLargeText();
  const { title, icon } = favoriteRow(t, row);
  // Where the finger pressed the handle, and the row's height, which a drag moves by.
  const start = useRef(0);
  const height = useRef(0);
  const slot = compact ? styles.compactSlot : styles.checkSlot;
  return (
    <Pressable
      accessibilityActions={[
        ...(moves.up ? [{ name: 'moveUp', label: t('mailboxes.moveUp') }] : []),
        ...(moves.down
          ? [{ name: 'moveDown', label: t('mailboxes.moveDown') }]
          : []),
      ]}
      accessibilityLabel={title}
      accessibilityRole="button"
      accessibilityValue={{
        text: t(shown ? 'mailboxes.shown' : 'mailboxes.hidden'),
      }}
      onAccessibilityAction={({ nativeEvent }) => {
        onMove(nativeEvent.actionName === 'moveUp' ? -1 : 1);
      }}
      onLayout={({ nativeEvent }) => {
        height.current = nativeEvent.layout.height;
      }}
      onPress={onToggle}
      style={({ pressed }) => [
        styles.row,
        compact ? styles.compactEditRow : styles.editRow,
        pressed && { backgroundColor: colors.accentSelectionSubtle },
        offset === undefined
          ? undefined
          : {
              zIndex: 1,
              transform: [{ translateY: offset }],
              backgroundColor: colors.accentSelectionSubtle,
            },
      ]}>
      <View style={slot}>
        <SFSymbol
          name={shown ? 'checkmark.circle.fill' : 'circle'}
          color={shown ? colors.accentFill : colors.textSecondary}
          size={compact ? 22 : 16}
        />
      </View>
      <View style={compact ? styles.compactSlot : styles.editIcon}>
        <SFSymbol
          name={icon}
          color={colors.accentInk}
        />
      </View>
      <Text
        numberOfLines={large ? 0 : 1}
        style={[
          compact ? styles.compactLabel : styles.label,
          // iPad dims a hidden row's name, as the frames draw it; iPhone keeps it.
          {
            color: shown || compact ? colors.textPrimary : colors.textSecondary,
          },
        ]}>
        {title}
      </Text>
      <View
        onStartShouldSetResponder={() => true}
        // The handle keeps the finger once it has it; the list does not scroll meanwhile.
        onResponderTerminationRequest={() => false}
        onResponderGrant={({ nativeEvent }) => {
          start.current = nativeEvent.pageY;
          onDrag(0, height.current);
        }}
        onResponderMove={({ nativeEvent }) => {
          onDrag(nativeEvent.pageY - start.current, height.current);
        }}
        onResponderRelease={({ nativeEvent }) => {
          onDrop(nativeEvent.pageY - start.current, height.current);
        }}
        onResponderTerminate={() => {
          onDrop(undefined, height.current);
        }}
        // The handle takes the row's height and 44pt of its width.
        hitSlop={{ left: 13, right: 13 }}
        style={[slot, styles.handle]}>
        <SFSymbol
          name="line.3.horizontal"
          color={colors.textSecondary}
          size={compact ? 18 : 14}
        />
      </View>
    </Pressable>
  );
}

// Favorites in Edit mode: every row the Profile can show, in its order. A row dragged by its
// handle moves to where it is dropped, the rows it passes giving way.
function EditFavorites({
  rows,
  onToggle,
  onMove,
  onDragging,
}: {
  readonly rows: ReadonlyArray<Readonly<{ row: Favorite; shown: boolean }>>;
  readonly onToggle: (row: Favorite) => void;
  // Moves `row` to the place `to` gives for its stored place.
  readonly onMove: (row: Favorite, to: (index: number) => number) => void;
  // Whether a row is being dragged, while the list must not scroll.
  readonly onDragging: (dragging: boolean) => void;
}) {
  const colors = usePalette();
  // The dragged row, the place it started from, how far the finger moved it and its height.
  const [drag, setDrag] =
    useState<
      Readonly<{ row: Favorite; from: number; dy: number; height: number }>
    >();
  // The place `dy` below row `from` falls on.
  const place = (from: number, dy: number, height: number) =>
    height === 0
      ? from
      : Math.max(0, Math.min(rows.length - 1, from + Math.round(dy / height)));
  const from = drag?.from ?? -1;
  const dragged = rows.find(({ row }) => row === drag?.row);
  const to = drag === undefined ? from : place(from, drag.dy, drag.height);
  const rest = rows.filter((entry) => entry !== dragged);
  const order =
    dragged === undefined
      ? rows
      : [...rest.slice(0, to), dragged, ...rest.slice(to)];
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {order.map(({ row, shown }, position) => {
        const index = rows.findIndex((entry) => entry.row === row);
        // Where this row's drag began, or its place now when no drag of it has rendered yet, such
        // as a press and release in one event batch.
        const begin = drag?.row === row ? drag.from : index;
        return (
          <Fragment key={row}>
            {compact && position > 0 ? (
              <View
                style={[
                  styles.separator,
                  styles.editSeparator,
                  { backgroundColor: colors.separator },
                ]}
              />
            ) : null}
            <EditRow
              row={row}
              shown={shown}
              moves={{ up: index > 0, down: index < rows.length - 1 }}
              offset={
                drag === undefined || row !== drag.row
                  ? undefined
                  : drag.dy - (to - from) * drag.height
              }
              onToggle={() => {
                onToggle(row);
              }}
              onMove={(by) => {
                onMove(row, (stored) => stored + by);
              }}
              onDrag={(dy, height) => {
                onDragging(true);
                setDrag({ row, from: begin, dy, height });
              }}
              onDrop={(dy, height) => {
                onDragging(false);
                setDrag(undefined);
                // Compared with the row's stored place, which another device may have changed.
                if (dy !== undefined && place(begin, dy, height) !== index) {
                  onMove(row, () => place(begin, dy, height));
                }
              }}
            />
          </Fragment>
        );
      })}
    </View>
  );
}

// Edit, beside Account on iPhone and the sidebar toggle on iPad, and Done, which replaces both on
// iPhone: the system's buttons, as the frames draw them. Mailboxes without an account offer none.
function EditButton({
  editing,
  onEditing,
}: {
  readonly editing: boolean;
  readonly onEditing: (editing: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const account = use(AccountContext);
  if (account === undefined) {
    return null;
  }
  const done = compact
    ? [
        labelStyle('iconOnly'),
        buttonStyle('glassProminent'),
        buttonBorderShape('circle'),
        controlSize('large'),
      ]
    : [
        buttonStyle('borderedProminent'),
        buttonBorderShape('capsule'),
        controlSize('small'),
      ];
  const button = (
    <Host matchContents>
      {editing ? (
        <SwiftUIButton
          label={t('mailboxes.done')}
          {...(compact ? { systemImage: 'checkmark' } : {})}
          modifiers={[...done, tint(colors.accentFill)]}
          onPress={() => {
            onEditing(false);
          }}
        />
      ) : (
        <SwiftUIButton
          label={t('mailboxes.edit')}
          modifiers={[
            buttonStyle(compact ? 'glass' : 'borderless'),
            controlSize(compact ? 'large' : 'regular'),
            tint(colors.textPrimary),
          ]}
          onPress={() => {
            onEditing(true);
          }}
        />
      )}
    </Host>
  );
  return compact ? button : <View style={styles.panelButton}>{button}</View>;
}

// Favorites: All Inboxes and the Unified Mailboxes the Profile shows, in its order, with the
// Outbox after Sent while it holds a message; in Edit mode, every row with its checkmark and handle.
function Favorites({
  view,
  onView,
  onSelect,
  onOutbox,
  unread,
  allSelected,
  editing,
  onDragging,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  readonly onSelect: (view: MailboxView) => void;
  readonly onOutbox?: () => void;
  // All Inboxes' unread count, and whether it is selected.
  readonly unread: number;
  readonly allSelected: boolean;
  readonly editing: boolean;
  readonly onDragging: (dragging: boolean) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const outbox = useProfileOutbox();
  const { entries, change } = useFavorites(useProfile());
  const rows = favoriteRows(entries);
  const shownRows = rows.filter(({ shown }) => shown);
  // Hiding the selected Unified Mailbox selects the first row still shown.
  const showOrHide = async (row: Favorite) => {
    const after = await change((stored) => toggleFavorite(stored, row));
    if (
      view.unified === row &&
      after?.some((entry) => entry.row === row && !entry.shown) === true
    ) {
      const first = after.find(({ shown }) => shown)?.row;
      onSelect(
        first === undefined || first === allInboxes ? {} : { unified: first },
      );
    }
  };
  if (editing) {
    return (
      <EditFavorites
        rows={rows}
        onToggle={(row) => {
          void showOrHide(row);
        }}
        onMove={(row, to) => {
          void change((stored) =>
            moveFavorite(
              stored,
              row,
              to(favoriteRows(stored).findIndex((entry) => entry.row === row)),
            ),
          );
        }}
        onDragging={onDragging}
      />
    );
  }
  // The Outbox follows Sent, or ends Favorites while Sent is hidden. iPhone's grouped rows are
  // divided by hairlines.
  const separator = compact ? (
    <View style={[styles.separator, { backgroundColor: colors.separator }]} />
  ) : null;
  const outboxRow =
    onOutbox !== undefined && outbox.length > 0 ? (
      <>
        {separator}
        <Item
          icon="tray.and.arrow.up"
          label={t('outbox.heading')}
          selected={view.outbox === true}
          onPress={onOutbox}
        />
      </>
    ) : null;
  return (
    <View
      style={compact && [styles.group, { backgroundColor: colors.fillQuiet }]}>
      {shownRows.map(({ row }, index) => {
        const { title, icon } = favoriteRow(t, row);
        return (
          <Fragment key={row}>
            {index > 0 ? separator : null}
            {row === allInboxes ? (
              <Item
                icon={icon}
                label={title}
                count={unread}
                selected={allSelected && view.outbox !== true}
                onPress={() => {
                  onView({});
                }}
              />
            ) : (
              <Item
                icon={icon}
                label={title}
                accessibilityLabel={t('inbox.rowLabel_mailbox', {
                  row: title,
                  mailbox: t('mailboxes.allMailboxes'),
                })}
                selected={view.unified === row}
                onPress={() => {
                  onView({ unified: row });
                }}
              />
            )}
            {row === 'SENT' ? outboxRow : null}
          </Fragment>
        );
      })}
      {shownRows.some(({ row }) => row === 'SENT') ? null : outboxRow}
    </View>
  );
}

// The Mailboxes of the window's Profile: every Inbox together, the Unified Mailboxes with the
// Outbox after Sent while it holds a message, then each Mailbox Connection with its folders, and
// Settings last.
export function Mailboxes({
  view,
  onView,
  onSelect = onView,
  onOutbox,
  onProfile,
  onCompose,
  bar,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  // Selects `view` without opening its list, as when Favorites hides the selected Unified Mailbox.
  readonly onSelect?: (view: MailboxView) => void;
  // Shows the Outbox, ending a search, each time it is chosen; Mailboxes without it offer none.
  readonly onOutbox?: () => void;
  // Switches the window to another Mail Profile.
  readonly onProfile: (profile: string) => void;
  // Opens a new Draft's composer from iPhone's New Message; none where Mailboxes offers no composer.
  readonly onCompose?: (id: string) => void;
  // iPhone's single column, whose navigation bar the Inbox shows and Mailboxes hides.
  readonly bar?: boolean;
}) {
  const mailboxes = useMailboxes();
  const account = use(AccountContext);
  const profile = useProfile();
  const reload = useReloadMailboxes();
  const colors = usePalette();
  const { t } = useLocalization();
  const header = usePaletteHeader();
  // iPhone's list runs under the home indicator, behind New Message's scroll edge.
  const { bottom } = useSafeAreaInsets();
  const toggle = use(SidebarToggleContext);
  const sidebar = mailboxSidebar({
    mailboxes,
    connections: account?.mailboxes ?? [],
    profile,
    view,
  });
  // Edit Favorites, and whether a row is being dragged, while the list must not scroll.
  const [editing, setEditing] = useState(false);
  const [dragging, setDragging] = useState(false);
  const editButton = (
    <EditButton
      editing={editing}
      onEditing={setEditing}
    />
  );
  // Settings over Mailboxes: Back returns here; Open Inbox shows the kept list, as choosing it would.
  const openSettings = (destination?: SettingsDestination) => {
    account?.openAccount(destination, () => {
      onView(view);
    });
  };
  const authorize = async (connection: string) => {
    await account?.authorizeMailbox(connection);
    await reload();
  };
  // iPhone's Authorization Needed banner above a connection's folders: Sign In… asks its provider
  // again, and IMAP enters its password again in Settings' Email Accounts. VoiceOver hears the
  // action with the connection's address, since several connections can need it.
  const signInNotice = ({
    provider,
    address,
    imap,
    onSignIn,
  }: Readonly<{
    provider: string;
    address: string;
    imap: boolean;
    onSignIn: () => Promise<void>;
  }>) =>
    compact ? (
      <SignInNotice
        message={
          imap
            ? t('mailboxes.passwordNotice')
            : t('mailboxes.signInNotice', { provider })
        }
        action={
          imap ? t('mailboxes.enterPasswordAction') : t('mailboxes.signIn')
        }
        accessibilityLabel={
          imap
            ? t('mailboxes.enterPasswordFor', { address })
            : t('mailboxes.signInFor', { address })
        }
        onPress={() => {
          if (imap) {
            openSettings('mailboxes');
          } else {
            void onSignIn();
          }
        }}
        style={styles.compactNotice}
      />
    ) : null;
  return (
    // The safe area keeps its insets as margins, so on iPhone the surface around it fills the
    // screen behind the status bar and home indicator.
    <View style={[styles.fill, { backgroundColor: colors.surfaceContent }]}>
      <RegisterCommands
        offer={() =>
          // Edit Favorites while the iPad sidebar shows beside the list; iPhone's Mailboxes has its
          // Edit button. The Inbox offers Go To each Unified Mailbox.
          sidebarCommands(t, {
            favorites:
              !compact && account !== undefined && toggle?.shown === true
                ? () => {
                    setEditing(true);
                  }
                : undefined,
          })
        }
      />
      {bar === true ? <NavigationChrome /> : null}
      <SafeAreaView
        edges={{
          top: true,
          bottom: compact && onCompose === undefined,
          left: true,
          right: true,
        }}
        style={styles.fill}>
        <View
          style={
            compact
              ? styles.fill
              : [
                  styles.panel,
                  {
                    backgroundColor: colors.surfacePanel,
                    borderColor: colors.separator,
                    boxShadow: colors.largeGlassShadow,
                  },
                ]
          }>
          {compact ? null : (
            <View style={styles.panelTop}>
              {editButton}
              <SidebarToggle />
            </View>
          )}
          {/* On iPhone the header opens the Command Palette by a downward swipe or its
            accessibility action. The iPad sidebar has no heading: the frames start it with the
            Profile Switcher beneath the column's sidebar toggle. */}
          {compact ? (
            <View
              style={styles.compactHeading}
              {...header.swipe}>
              <View style={styles.grow} />
              <Text
                accessibilityRole="header"
                style={[styles.title, { color: colors.textPrimary }]}
                {...header.action}>
                {t('mailboxes.title')}
              </Text>
              <View style={[styles.grow, styles.headingActions]}>
                {editButton}
                {account === undefined || editing ? null : (
                  <GlassGroup style={styles.accountGlass}>
                    <Pressable
                      accessibilityLabel={t('inbox.account')}
                      accessibilityRole="button"
                      onPress={() => {
                        openSettings();
                      }}
                      style={styles.accountButton}>
                      {/* The frames' gear draws 16pt of ink. */}
                      <SFSymbol
                        name="gearshape"
                        size={15.5}
                        color={colors.textPrimary}
                      />
                    </Pressable>
                  </GlassGroup>
                )}
              </View>
            </View>
          ) : null}
          <ScrollView
            style={styles.fill}
            scrollEnabled={!dragging}
            // A row takes its first tap while Search's keyboard is up, so one tap on Outbox ends
            // the search.
            keyboardShouldPersistTaps="handled"
            contentContainerStyle={[
              styles.list,
              compact && styles.compactList,
              compact &&
                onCompose !== undefined && {
                  paddingBottom: styles.compactList.paddingBottom + bottom,
                },
            ]}>
            <ProfileSwitcher
              onProfile={onProfile}
              onManage={() => {
                openSettings('profiles');
              }}
            />
            <SectionHeader label={t('mailboxes.favorites')} />
            <Favorites
              view={view}
              onView={onView}
              onSelect={onSelect}
              unread={sidebar.unread}
              allSelected={sidebar.allSelected}
              editing={editing}
              onDragging={setDragging}
              {...(onOutbox === undefined ? {} : { onOutbox })}
            />
            {sidebar.entries.map((entry) => {
              if ('section' in entry) {
                const { mailbox, folders } = entry.section;
                // Waiting out Gmail's usage limit is a pause the Sync Status Capsule reports.
                const problem = limited(mailbox.state)
                  ? undefined
                  : entry.section.problem;
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
                    <SectionHeader
                      label={`${provider} · ${name}`}
                      trouble={trouble}
                    />
                    {problem === 'authentication'
                      ? signInNotice({
                          provider,
                          address: name,
                          imap: mailbox.provider === 'imap',
                          onSignIn: async () => {
                            await account?.authorizeMailbox(mailbox.id);
                            await mailbox.inbox.load();
                          },
                        })
                      : null}
                    <FolderRows
                      mailbox={mailbox}
                      folders={folders}
                      onView={onView}
                    />
                  </Fragment>
                );
              }
              const { connection, recovery, selected } = entry.waiting;
              const provider = t(`mailProviders.${connection.provider}`);
              const imap = recovery === 'account';
              const trouble = imap
                ? t('mailboxes.states.imap-authorization')
                : t('mailboxes.states.authorization', { provider });
              return (
                <Fragment key={connection.id}>
                  <SectionHeader
                    label={`${provider} · ${connection.address}`}
                    trouble={trouble}
                  />
                  {signInNotice({
                    provider,
                    address: connection.address,
                    imap,
                    onSignIn: () => authorize(connection.id),
                  })}
                  <View
                    style={
                      compact && [
                        styles.group,
                        { backgroundColor: colors.fillQuiet },
                      ]
                    }>
                    <Item
                      icon="tray"
                      label={t('inbox.title')}
                      accessibilityLabel={t('inbox.rowLabel_mailbox', {
                        row: t('inbox.title'),
                        mailbox: connection.address,
                      })}
                      selected={selected}
                      onPress={() => {
                        // IMAP needs its password entered again in Settings' Email Accounts.
                        if (imap) {
                          openSettings('mailboxes');
                        } else {
                          void authorize(connection.id);
                        }
                      }}
                    />
                  </View>
                </Fragment>
              );
            })}
          </ScrollView>
          {compact && onCompose !== undefined ? (
            <FloatingBar
              bottomInset={bottom}
              // The frames fade the last 140pt of Mailboxes behind New Message.
              edge={140}
              leading={null}
              trailing={
                <NewMessageButton
                  onCompose={onCompose}
                  scope={undefined}
                  registerCommand={false}
                />
              }>
              <BarSpacer />
            </FloatingBar>
          ) : null}
          {compact || account === undefined ? null : (
            <View style={[styles.footer, { borderTopColor: colors.separator }]}>
              <Item
                icon="gearshape"
                label={t('settings.title')}
                onPress={() => {
                  openSettings();
                }}
              />
            </View>
          )}
        </View>
      </SafeAreaView>
    </View>
  );
}
