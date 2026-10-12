import type { Translate } from '@private-email/localization';

import type {
  ImapCapabilities,
  ImapFolder,
  ImapMessage,
} from './imap-model.ts';

import { gmailActionCopy } from './gmail-actions.ts';
import { inboxFolder } from './imap-model.ts';

/**
 * Explains an IMAP outcome without offering replay of an uncertain move.
 *
 * @param {Translate} t Translates the outcome.
 * @param {object} notice The action's outcome.
 * @param {string} provider The mailbox's provider name.
 * @returns {string} The visible and announced outcome.
 */
export const imapActionCopy = (
  t: Translate,
  notice: Parameters<typeof gmailActionCopy>[1],
  provider: string,
) =>
  notice.kind === 'blocked'
    ? t('imapActions.uncertain', { subject: notice.message.subject })
    : gmailActionCopy(t, notice, provider);

// IMAP has no labels: archive, Trash and Spam are folders the server declares by special-use role.
// Without a declared role, or a server that moves without expunging other messages, the action is
// not offered.
const roles = [
  ['archive', 'archive'],
  ['trash', 'trash'],
  ['spam', 'junk'],
] as const;

// A connection's folders and what its server advertised, as its Inbox state carries them.
type Listing = Readonly<{
  folders: readonly ImapFolder[];
  capabilities: ImapCapabilities | undefined;
}>;

export const imapRoleFolder = (
  folders: readonly ImapFolder[],
  role: string,
) => {
  const matches = folders.filter(
    ({ selectable, roles: declared }) => selectable && declared.includes(role),
  );
  return matches.length === 1 ? matches[0]?.name : undefined;
};

/**
 * Lists a message's quick actions: its read state, then moves to the folders
 * the server declares for archive, Trash and Spam.
 *
 * @example
 *   imapQuickActions(t, message, state);
 *
 * @param {Translate} t Localizes each action's label.
 * @param {ImapMessage} message The message the actions change.
 * @param {Listing} listing The connection's folders, and what its server
 *   advertised; unknown capabilities offer no moves.
 * @returns {readonly object[]} Each action's name, label and change.
 */
export const imapQuickActions = (
  t: Translate,
  message: ImapMessage,
  { folders, capabilities }: Listing,
) => {
  const actions: ReadonlyArray<
    | Readonly<{ kind: 'read' | 'unread' }>
    | Readonly<{ kind: 'archive' | 'trash' | 'spam'; destination: string }>
  > = [
    { kind: message.unread ? 'read' : 'unread' },
    ...(capabilities?.moves === true
      ? roles.flatMap(([kind, role]) => {
          const destination = imapRoleFolder(folders, role);
          return destination === undefined || destination === message.folder
            ? []
            : [{ kind, destination }];
        })
      : []),
  ];
  return actions.map((action) => ({
    name: action.kind,
    label: t(`gmailActions.label.${action.kind}`),
    action,
  }));
};

/**
 * Lists the folders a message can move to: every other selectable folder, in
 * the server's order.
 *
 * @example
 *   imapMoveTargets(message, state);
 *
 * @param {ImapMessage} message The message to move.
 * @param {Listing} listing The connection's folders, and what its server
 *   advertised; unknown capabilities offer none.
 * @returns {readonly ImapFolder[]} The folders offered under Move to.
 */
export const imapMoveTargets = (
  message: ImapMessage,
  { folders, capabilities }: Listing,
) =>
  capabilities?.moves === true
    ? folders.filter(
        ({ name, selectable }) => selectable && name !== message.folder,
      )
    : [];

// Search covers the Inbox, then folders with another declared role, then the rest, leaving out
// Trash and Spam as Gmail's search does.
const unsearched = new Set(['trash', 'junk']);
export const searchedFolders = (folders: readonly ImapFolder[]) => {
  const candidates = folders.filter(
    ({ selectable, roles: declared }) =>
      selectable && !declared.some((role) => unsearched.has(role)),
  );
  return [
    inboxFolder,
    ...candidates
      .filter(
        ({ name, roles: declared }) =>
          name !== inboxFolder && declared.length > 0,
      )
      .map(({ name }) => name),
    ...candidates
      .filter(
        ({ name, roles: declared }) =>
          name !== inboxFolder && declared.length === 0,
      )
      .map(({ name }) => name),
  ];
};
