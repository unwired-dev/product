import type { Translate } from '@private-email/localization';
import type {
  Favorite,
  MailboxProblem,
  UnifiedRole,
} from '@private-email/mail-core/mailboxes';
import type { MailProvider } from '@private-email/mail-core/registration';
import type { ReactNode } from 'react';

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
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  Fragment,
  use,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import type { InboxMailbox } from './private-storage.ts';

import { RegisterCommands } from './command-palette.tsx';
import { ContextMenu, MenuButton, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { useAllMailboxes } from './mailbox-list.ts';
import { useMailboxes, useProfile, useReloadMailboxes } from './mailbox.tsx';
import { useProfileOutbox } from './outbox.tsx';
import { InboxPreferencesContext } from './preview-lines.tsx';
import { ProfileMonogram, promptNewProfile } from './profile-settings.tsx';
import { AccountContext } from './registration-gate.tsx';
import { textStyles, usePalette, useProfilePalette } from './theme.ts';

// What the message list shows: every mailbox of the Profile, one mailbox, one of its folders, a
// Unified Mailbox of every mailbox, or the Profile's Outbox. The Inbox folder is the default of a
// mailbox.
export type MailboxView = Readonly<{
  mailbox?: string | undefined;
  folder?: string | undefined;
  unified?: UnifiedRole | undefined;
  outbox?: boolean | undefined;
}>;

// A sidebar row's height, which a dragged Favorites row moves by.
const rowHeight = 28;

const styles = StyleSheet.create({
  fill: { flex: 1 },
  // The window controls' row: AppKit draws them at its leading end, centered 26pt down the
  // window, level with the toggle; the Profile Switcher follows 32pt below that center.
  controls: {
    height: 36,
    marginBottom: 14,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
    paddingHorizontal: spacing.s,
  },
  list: { paddingHorizontal: spacing.s, paddingBottom: spacing.l },
  sectionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.xs,
    paddingHorizontal: spacing.s,
    paddingTop: spacing.m,
    paddingBottom: spacing.xs,
  },
  section: { ...textStyles.subheadline, fontWeight: '600', flex: 1 },
  warning: { marginRight: spacing.xs },
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
  // The frames' 16pt symbol slot, its glyph drawn at 13pt.
  icon: { width: 16, height: 16 },
  // An Edit Favorites row: checkmark, symbol, name and drag handle, 6pt apart.
  editRow: { height: rowHeight, gap: 6 },
  // The frames' 18pt-wide slot for a row's own symbol.
  editIcon: { width: 18 },
  // Done overlaps the header's trailing end as the frames draw it, so the header keeps its height.
  done: {
    position: 'absolute',
    top: 3,
    right: 0,
    height: 28,
    justifyContent: 'center',
    paddingHorizontal: 12,
    borderRadius: 6,
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
        onManage: () => {
          account.openAccount('profiles');
        },
        fills,
      })}
      style={[styles.switcher, { backgroundColor: colors.fillQuiet }]}>
      <View style={styles.switcherRow}>
        <ProfileMonogram
          name={name}
          style={profileStyle(profiles, profile)}
          size={22}
        />
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
  // A failed read beside the folder, in place of its count.
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
        // tray.2's ink at 13pt is larger than the frames' 13.3pt glyph.
        size={icon === 'tray.2' ? 11.7 : 13}
        style={styles.icon}
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

// The warning beside a Mailbox Connection's header while the connection has a problem: the
// frames' 13pt-wide glyph, 9pt before the chevron.
function HeaderWarning() {
  const colors = usePalette();
  return (
    <SFSymbol
      name="exclamationmark.triangle.fill"
      color={colors.statusWarning}
      size={12.5}
      style={styles.warning}
    />
  );
}

// A section's header: its label, its connection's warning, and a trailing disclosure chevron that
// collapses or expands the section's rows.
function SectionHeader({
  label,
  collapsed,
  onToggle,
  trouble,
}: {
  readonly label: string;
  readonly collapsed: boolean;
  readonly onToggle: () => void;
  // The connection's problem, expanded or collapsed.
  readonly trouble?: string | undefined;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  return (
    <Pressable
      accessibilityLabel={
        trouble === undefined ? label : `${label}, ${trouble}`
      }
      // A control, so VoiceOver finds the disclosure among buttons; AppKit's header role is static
      // text.
      accessibilityRole="button"
      accessibilityState={{ expanded: !collapsed }}
      // Mac Fabric announces expanded, but omits the collapsed state from its value.
      accessibilityValue={
        collapsed ? { text: t('mailboxes.collapsed') } : undefined
      }
      accessibilityActions={[{ name: 'activate' }]}
      onAccessibilityAction={onToggle}
      onPress={onToggle}
      style={styles.sectionRow}>
      <Text
        numberOfLines={1}
        style={[styles.section, { color: colors.textSecondary }]}>
        {label}
      </Text>
      {trouble === undefined ? null : <HeaderWarning />}
      <SFSymbol
        name={collapsed ? 'chevron.right' : 'chevron.down'}
        color={colors.textSecondary}
        size={10}
      />
    </Pressable>
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
// after another mailbox is chosen; the connection's own problem is on its header.
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
    );
  });
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
    change: (change: (stored: typeof entries) => typeof entries) => {
      void store.changeFavorites(profile, change);
    },
  };
}

// The keys an Edit Favorites row handles: Space and Return show or hide it, as a Pressable's do,
// and Command-Option-Up and Down move it.
const editKeys = [
  { key: ' ' },
  { key: 'Enter' },
  { key: 'ArrowUp', altKey: true, metaKey: true },
  { key: 'ArrowDown', altKey: true, metaKey: true },
];

// A Favorites row in Edit mode: the checkmark that shows or hides it, its symbol and name, and the
// handle that drags it to another place. Activating the row shows or hides it, except All
// Inboxes, which stays shown; Move Up and Move Down reorder it from the keyboard and VoiceOver.
function EditRow({
  row,
  shown,
  moved,
  moves,
  offset,
  onToggle,
  onMove,
  onDrag,
  onDrop,
}: {
  readonly row: Favorite;
  readonly shown: boolean;
  // How many times the keyboard or VoiceOver moved the row in a row, so it keeps focus.
  readonly moved: number | undefined;
  // Which ways the row can move by one place.
  readonly moves: Readonly<{ up: boolean; down: boolean }>;
  // How far the pointer drags the row from where it shows, while it does.
  readonly offset: number | undefined;
  readonly onToggle: () => void;
  readonly onMove: (by: -1 | 1) => void;
  readonly onDrag: (dy: number) => void;
  // Where the pointer let go, as far from where the drag began; undefined when it was cancelled.
  readonly onDrop: (dy: number | undefined) => void;
}) {
  const colors = usePalette();
  const { t } = useLocalization();
  const [focused, setFocused] = useState(false);
  const { title, icon } = favoriteRow(t, row);
  // Where the pointer pressed the handle, while it drags the row.
  const [start, setStart] = useState(0);
  // Moving a row reinserts its view, which loses focus; give it back.
  const ref = useRef<View>(null);
  useEffect(() => {
    if (moved !== undefined) {
      ref.current?.focus();
    }
  }, [moved]);
  const move = (by: -1 | 1) => {
    if (by < 0 ? moves.up : moves.down) {
      onMove(by);
    }
  };
  return (
    <Pressable
      ref={ref}
      // AppKit titles each action by its name; VoiceOver's Press shows or hides the row.
      accessibilityActions={[
        ...(moves.up ? [{ name: t('mailboxes.moveUp') }] : []),
        ...(moves.down ? [{ name: t('mailboxes.moveDown') }] : []),
      ]}
      accessibilityLabel={title}
      accessibilityRole="button"
      accessibilityValue={{
        text: t(shown ? 'mailboxes.shown' : 'mailboxes.hidden'),
      }}
      focusable
      keyDownEvents={editKeys}
      onAccessibilityAction={({ nativeEvent }) => {
        move(nativeEvent.actionName === t('mailboxes.moveUp') ? -1 : 1);
      }}
      onBlur={() => {
        setFocused(false);
      }}
      onFocus={() => {
        setFocused(true);
      }}
      onKeyDown={({ nativeEvent: { key, altKey, metaKey } }) => {
        if (altKey && metaKey && (key === 'ArrowUp' || key === 'ArrowDown')) {
          move(key === 'ArrowUp' ? -1 : 1);
        }
      }}
      onPress={onToggle}
      style={[
        styles.row,
        styles.editRow,
        { borderColor: focused ? colors.accentInk : 'transparent' },
        offset === undefined
          ? undefined
          : {
              zIndex: 1,
              transform: [{ translateY: offset }],
              backgroundColor: colors.accentSelectionSubtle,
            },
      ]}>
      <SFSymbol
        name={shown ? 'checkmark.circle.fill' : 'circle'}
        color={shown ? colors.accentFill : colors.textSecondary}
        size={14}
        style={styles.icon}
      />
      <SFSymbol
        name={icon}
        color={colors.accentInk}
        // tray.2's ink at 13pt is larger than the frames' 13.3pt glyph.
        size={icon === 'tray.2' ? 11.7 : 13}
        style={[styles.icon, styles.editIcon]}
      />
      <Text
        numberOfLines={1}
        style={[
          styles.label,
          { color: shown ? colors.textPrimary : colors.textSecondary },
        ]}>
        {title}
      </Text>
      <View
        onStartShouldSetResponder={() => true}
        onResponderGrant={({ nativeEvent }) => {
          setStart(nativeEvent.pageY);
        }}
        onResponderMove={({ nativeEvent }) => {
          onDrag(nativeEvent.pageY - start);
        }}
        onResponderRelease={({ nativeEvent }) => {
          onDrop(nativeEvent.pageY - start);
        }}
        onResponderTerminate={() => {
          onDrop(undefined);
        }}>
        <SFSymbol
          name="line.3.horizontal"
          color={colors.textSecondary}
          size={12}
          style={styles.icon}
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
}: {
  readonly rows: ReadonlyArray<Readonly<{ row: Favorite; shown: boolean }>>;
  readonly onToggle: (row: Favorite) => void;
  readonly onMove: (row: Favorite, index: number) => void;
}) {
  const [drag, setDrag] = useState<Readonly<{ row: Favorite; dy: number }>>();
  // The row the keyboard or VoiceOver last moved, and how many times in a row.
  const [moved, setMoved] =
    useState<Readonly<{ row: Favorite; times: number }>>();
  // The place `dy` below row `from` falls on.
  const place = (from: number, dy: number) =>
    Math.max(0, Math.min(rows.length - 1, from + Math.round(dy / rowHeight)));
  const from = rows.findIndex(({ row }) => row === drag?.row);
  const dragged = rows[from];
  const to = drag === undefined ? from : place(from, drag.dy);
  const rest = rows.filter((entry) => entry !== dragged);
  const order =
    dragged === undefined
      ? rows
      : [...rest.slice(0, to), dragged, ...rest.slice(to)];
  return order.map(({ row, shown }) => {
    const index = rows.findIndex((entry) => entry.row === row);
    return (
      <EditRow
        key={row}
        row={row}
        shown={shown}
        moved={moved?.row === row ? moved.times : undefined}
        moves={{ up: index > 0, down: index < rows.length - 1 }}
        offset={
          drag === undefined || row !== drag.row
            ? undefined
            : drag.dy - (to - from) * rowHeight
        }
        onToggle={() => {
          onToggle(row);
        }}
        onMove={(by) => {
          setMoved({
            row,
            times: moved?.row === row ? moved.times + 1 : 1,
          });
          onMove(row, index + by);
        }}
        onDrag={(dy) => {
          setMoved(undefined);
          setDrag({ row, dy });
        }}
        onDrop={(dy) => {
          setDrag(undefined);
          if (dy !== undefined && place(index, dy) !== index) {
            onMove(row, place(index, dy));
          }
        }}
      />
    );
  });
}

// The Mailboxes of the window's Profile: every Inbox together, the Unified Mailboxes with the
// Outbox after Sent while it holds a message, then each Mailbox Connection with its folders, and
// Settings last.
export function Mailboxes({
  view,
  onView,
  onProfile,
  toggle,
}: {
  readonly view: MailboxView;
  readonly onView: (view: MailboxView) => void;
  // Switches the window to another Mail Profile.
  readonly onProfile: (profile: string) => void;
  // The sidebar toggle, at the trailing end of the window controls' row.
  readonly toggle?: ReactNode;
}) {
  const mailboxes = useMailboxes();
  const account = use(AccountContext);
  const profile = useProfile();
  const reload = useReloadMailboxes();
  const outbox = useProfileOutbox();
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
  // The window's collapsed sections, by Favorites or Mailbox Connection.
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set());
  const section = (key: string, label: string, trouble?: string) => {
    const toggleSection = () => {
      setCollapsed((current) => {
        const next = new Set(current);
        if (!next.delete(key)) {
          next.add(key);
        }
        return next;
      });
    };
    return {
      header: (
        <SectionHeader
          label={label}
          trouble={trouble}
          collapsed={collapsed.has(key)}
          onToggle={toggleSection}
        />
      ),
      shown: !collapsed.has(key),
      toggle: toggleSection,
    };
  };
  const favorites = section('favorites', t('mailboxes.favorites'));
  // Edit Favorites, per window; it shows Favorites expanded.
  const [editing, setEditing] = useState(false);
  const edit = () => {
    setEditing(true);
    setCollapsed((current) => {
      const next = new Set(current);
      next.delete('favorites');
      return next;
    });
  };
  const { entries, change } = useFavorites(profile);
  const rows = favoriteRows(entries);
  const shownRows = rows.filter(({ shown }) => shown);
  // Hiding the selected Unified Mailbox selects the first row still shown.
  const showOrHide = (row: Favorite) => {
    change((stored) => toggleFavorite(stored, row));
    const after = favoriteRows(toggleFavorite(entries, row));
    if (
      view.unified === row &&
      after.some((entry) => entry.row === row && !entry.shown)
    ) {
      const first = after.find(({ shown }) => shown)?.row;
      onView(
        first === undefined || first === allInboxes ? {} : { unified: first },
      );
    }
  };
  // The Outbox follows Sent, or ends Favorites while Sent is hidden.
  const outboxRow =
    outbox.length > 0 ? (
      <Item
        icon="tray.and.arrow.up"
        label={t('outbox.heading')}
        selected={view.outbox === true}
        onPress={() => {
          onView({ outbox: true });
        }}
      />
    ) : null;
  return (
    <View style={styles.fill}>
      <RegisterCommands
        offer={() =>
          sidebarCommands(t, {
            // The sidebar has its toggle only while it shows.
            favorites: toggle === undefined ? undefined : edit,
            unified: (role) => {
              onView({ unified: role });
            },
          })
        }
      />
      <View style={styles.fill}>
        <View style={styles.controls}>{toggle}</View>
        <ScrollView
          style={styles.fill}
          contentContainerStyle={styles.list}>
          <ProfileSwitcher onProfile={onProfile} />
          {editing ? (
            <View style={styles.sectionRow}>
              <Text
                accessibilityRole="header"
                numberOfLines={1}
                style={[styles.section, { color: colors.textSecondary }]}>
                {t('mailboxes.favorites')}
              </Text>
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={t('mailboxes.done')}
                focusable
                onPress={() => {
                  setEditing(false);
                }}
                style={[styles.done, { backgroundColor: colors.accentFill }]}>
                <Text style={[textStyles.body, { color: colors.accentOnFill }]}>
                  {t('mailboxes.done')}
                </Text>
              </Pressable>
            </View>
          ) : (
            <ContextMenu
              sections={[
                {
                  items: [
                    {
                      key: 'edit-favorites',
                      title: t('mailboxes.editFavorites'),
                      symbol: 'pencil',
                      run: edit,
                    },
                  ],
                },
                {
                  items: [
                    {
                      key: 'collapse-favorites',
                      title: t(
                        favorites.shown
                          ? 'mailboxes.collapseFavorites'
                          : 'mailboxes.expandFavorites',
                      ),
                      symbol: favorites.shown
                        ? 'chevron.down'
                        : 'chevron.right',
                      run: favorites.toggle,
                    },
                  ],
                },
              ]}>
              {favorites.header}
            </ContextMenu>
          )}
          {editing ? (
            <EditFavorites
              rows={rows}
              onToggle={showOrHide}
              onMove={(row, index) => {
                change((stored) => moveFavorite(stored, row, index));
              }}
            />
          ) : null}
          {!editing && favorites.shown ? (
            <>
              {shownRows.map(({ row }) => {
                const { title, icon } = favoriteRow(t, row);
                return (
                  <Fragment key={row}>
                    {row === allInboxes ? (
                      <Item
                        icon={icon}
                        label={title}
                        count={sidebar.unread}
                        selected={sidebar.allSelected && view.outbox !== true}
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
            </>
          ) : null}
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
              const { header, shown } = section(
                mailbox.id,
                `${provider} · ${name}`,
                trouble,
              );
              return (
                <Fragment key={mailbox.id}>
                  {header}
                  {shown ? (
                    <FolderRows
                      mailbox={mailbox}
                      folders={folders}
                      onView={onView}
                    />
                  ) : null}
                </Fragment>
              );
            }
            const { connection, recovery, selected } = entry.waiting;
            const provider = t(`mailProviders.${connection.provider}`);
            const imap = recovery === 'account';
            const title = `${provider} · ${connection.address}`;
            const trouble = imap
              ? t('mailboxes.states.imap-authorization')
              : t('mailboxes.states.authorization', { provider });
            return (
              <Fragment key={connection.id}>
                {/* A connection waiting for authorization keeps its one row and its action in view. */}
                <View
                  accessible
                  accessibilityRole="header"
                  accessibilityLabel={`${title}, ${trouble}`}
                  style={styles.sectionRow}>
                  <Text
                    numberOfLines={1}
                    style={[styles.section, { color: colors.textSecondary }]}>
                    {title}
                  </Text>
                  <HeaderWarning />
                </View>
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
              label={t('settings.title')}
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
