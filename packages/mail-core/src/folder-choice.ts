import type { Translate } from '@private-email/localization';

import type { ImapFolder } from './imap-model.ts';
import type { ChosenFolders } from './registration-snapshot.ts';

import { imapRoleFolder } from './imap-actions.ts';
import { inboxFolder } from './imap-model.ts';

const roles = ['junk', 'trash'] as const;
export type FolderRole = (typeof roles)[number];
const otherRole = (role: FolderRole) => (role === 'junk' ? 'trash' : 'junk');

// The roles a folder keeps out of both choices, as the menu names them.
const otherRoles = {
  inbox: 'inbox.title',
  sent: 'mailboxes.sent',
  drafts: 'drafts.heading',
  archive: 'mailboxes.archive',
  all: 'mailboxes.allMail',
  flagged: 'mailboxes.flagged',
} as const;

// A server marking several folders with a role is left out of All Mail, since a choice can't say
// what the others hold.
export const ambiguousFolders = (folders: readonly ImapFolder[]) =>
  roles.some(
    (role) =>
      folders.filter(
        (folder) => folder.selectable && folder.roles.includes(role),
      ).length > 1,
  );

// A new choice starts from the saved one, for the roles its server marks no folder with.
export const startingPicks = (
  marked: ChosenFolders,
  saved: ChosenFolders | undefined,
): ChosenFolders =>
  Object.fromEntries(
    roles
      .filter((role) => marked[role] === undefined)
      .map((role) => [role, saved?.[role]]),
  );

// An IMAP connection's Spam and Trash folders as Settings › Email Accounts lists them, where its
// server leaves either unmarked and a choice can include it in All Mail. `chosen` once both have
// a folder; a chosen folder that leaves the server needs a choice again.
export function folderSummary(
  t: Translate,
  {
    folders,
    marked,
  }: {
    readonly folders: readonly ImapFolder[];
    readonly marked: ChosenFolders;
  },
) {
  if (
    roles.every((role) => marked[role] !== undefined) ||
    ambiguousFolders(folders) ||
    folders.some((folder) => folder.selectable && folder.roles.includes('all'))
  ) {
    return undefined;
  }
  const junk = imapRoleFolder(folders, 'junk');
  const trash = imapRoleFolder(folders, 'trash');
  if (junk !== undefined && trash !== undefined) {
    return {
      chosen: true,
      subtitle: t('mailboxes.folders.settings.chosen', { junk, trash }),
    };
  }
  let open = t('mailboxes.folders.settings.both');
  if (junk !== undefined) {
    open = t('mailboxes.trash');
  } else if (trash !== undefined) {
    open = t('mailboxes.spam');
  }
  return {
    chosen: false,
    subtitle: t('mailboxes.folders.settings.needed', { roles: open }),
  };
}

// The Spam and Trash choice for an IMAP connection's not-included notice, as each client's sheet
// shows it: a row per role, whose menu lists the folders a role can take after those another role
// holds, and whether Save can send the picks.
export function folderChoice(
  t: Translate,
  {
    address,
    folders,
    marked,
    saved,
    picks,
    saving,
    failed,
    context,
  }: {
    readonly address: string;
    readonly folders: readonly ImapFolder[];
    // The folders its server marks with a role, which the person cannot change.
    readonly marked: ChosenFolders;
    readonly saved: ChosenFolders | undefined;
    readonly picks: ChosenFolders;
    readonly saving: boolean;
    readonly failed: boolean;
    // A localization context, such as 'iphone' where folders are listed in Mailboxes.
    readonly context?: string | undefined;
  },
) {
  const open = roles.filter((role) => marked[role] === undefined);
  const exists = (name: string | undefined) =>
    folders.some((folder) => folder.selectable && folder.name === name);
  const missing = open.filter(
    (role) => picks[role] !== undefined && !exists(picks[role]),
  );
  const [gone] = missing;
  const changing = saved !== undefined;
  const roleName = (role: FolderRole) =>
    t(role === 'junk' ? 'mailboxes.spam' : 'mailboxes.trash');
  const holding = (role: FolderRole, folder: ImapFolder) =>
    folder.name === (marked[otherRole(role)] ?? picks[otherRole(role)])
      ? roleName(otherRole(role))
      : Object.entries(otherRoles)
          .filter(([key]) => folder.roles.includes(key))
          .map(([, key]) => t(key))[0];
  // Menus and Save accept the same folders, including after a server listing changes.
  const taken = (role: FolderRole, folder: ImapFolder) =>
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
  // A role's folders, those another role holds first; Inbox names no other role.
  const options = (role: FolderRole) => {
    const option = (folder: ImapFolder) => ({
      name: folder.name,
      title: folder.name === inboxFolder ? t('inbox.title') : folder.name,
      holding: folder.name === inboxFolder ? undefined : holding(role, folder),
      taken: taken(role, folder),
      checked: picks[role] === folder.name,
    });
    const listed = folders.filter(({ selectable }) => selectable);
    return [
      listed.filter((folder) => taken(role, folder)).map(option),
      listed.filter((folder) => !taken(role, folder)).map(option),
    ].filter((section) => section.length > 0);
  };
  const subtitle = (role: FolderRole) => {
    const pick = picks[role];
    const was = saved?.[role];
    if (marked[role] !== undefined) {
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
  const rows = roles.map((role) => ({
    role,
    name: roleName(role),
    symbol: role === 'junk' ? 'xmark.bin' : 'trash',
    // A server-marked folder shows as a value; the others in a menu.
    server: marked[role],
    pick: picks[role],
    value: marked[role] ?? picks[role] ?? t('mailboxes.folders.placeholder'),
    subtitle: subtitle(role),
    missing: missing.includes(role),
    options: options(role),
  }));
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
    ...(context === undefined ? {} : { context }),
  };
  const lost =
    gone === undefined
      ? undefined
      : t('mailboxes.folders.gone', {
          folder: picks[gone],
          role: roleName(gone),
        });
  return {
    rows,
    ready,
    // What Save sends: the picks for the roles its server leaves unmarked.
    chosen: Object.fromEntries(open.map((role) => [role, picks[role]])),
    title: t(`mailboxes.folders.${kind}.title`, values),
    intro: t(`mailboxes.folders.${kind}.intro`, values),
    note:
      changing && (gone !== undefined || failed)
        ? t('mailboxes.folders.updateNote')
        : t(
            `mailboxes.folders.${kind}.${ready ? 'readyNote' : 'note'}`,
            values,
          ),
    warning: failed ? t('mailboxes.folders.saveFailed') : lost,
  };
}
