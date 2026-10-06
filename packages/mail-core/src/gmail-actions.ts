import * as Schema from 'effect/Schema';

import type { GmailMessage } from './gmail-inbox.ts';

// Gmail organizes mail with labels: Inbox, Trash, Spam, read state and stars are system labels
// that one message modify request adds or removes. Other providers will need their own actions.
const LabelId = Schema.String.check(Schema.isPattern(/^\w{1,100}$/u));

export const GmailActionSchema = Schema.Struct({
  kind: Schema.Literals([
    'read',
    'unread',
    'star',
    'unstar',
    'archive',
    'trash',
    'spam',
    'label',
    'unlabel',
    'move',
    // Undoes a removal from the Inbox: archive, move, trash or spam.
    'restore',
  ]),
  add: Schema.Array(LabelId),
  remove: Schema.Array(LabelId),
});
export type GmailAction = typeof GmailActionSchema.Type;

export const GmailLabelSchema = Schema.Struct({
  id: LabelId,
  name: Schema.String,
});
export type GmailLabel = typeof GmailLabelSchema.Type;

export const gmailAction = {
  read: { kind: 'read', add: [], remove: ['UNREAD'] },
  unread: { kind: 'unread', add: ['UNREAD'], remove: [] },
  star: { kind: 'star', add: ['STARRED'], remove: [] },
  unstar: { kind: 'unstar', add: [], remove: ['STARRED'] },
  archive: { kind: 'archive', add: [], remove: ['INBOX'] },
  trash: { kind: 'trash', add: ['TRASH'], remove: ['INBOX'] },
  spam: { kind: 'spam', add: ['SPAM'], remove: ['INBOX'] },
  label: (label: string): GmailAction => ({
    kind: 'label',
    add: [label],
    remove: [],
  }),
  unlabel: (label: string): GmailAction => ({
    kind: 'unlabel',
    add: [],
    remove: [label],
  }),
  // Gmail's Move to: the label replaces the Inbox and every other label stays.
  move: (label: string): GmailAction => ({
    kind: 'move',
    add: [label],
    remove: ['INBOX'],
  }),
} as const satisfies Record<
  string,
  GmailAction | ((label: string) => GmailAction)
>;

// Gmail lists neither Trash nor Spam in the Inbox, whatever other labels a message keeps.
export const inInbox = (labels: readonly string[]) =>
  labels.includes('INBOX') &&
  !labels.includes('TRASH') &&
  !labels.includes('SPAM');

export const relabel = (labels: readonly string[], action: GmailAction) => [
  ...labels.filter((label) => !action.remove.includes(label)),
  ...action.add.filter((label) => !labels.includes(label)),
];

// Undo of an action that took a message out of the Inbox.
export const restoreAfter = (
  action: GmailAction,
  before: readonly string[] = ['INBOX'],
): GmailAction | undefined =>
  inInbox(relabel(['INBOX'], action))
    ? undefined
    : {
        kind: 'restore',
        add: action.remove.filter((label) => before.includes(label)),
        remove: action.add.filter((label) => !before.includes(label)),
      };

const pastTense: Record<GmailAction['kind'], string> = {
  read: 'Marked as read',
  unread: 'Marked as unread',
  star: 'Starred',
  unstar: 'Star removed',
  archive: 'Archived',
  trash: 'Moved to Trash',
  spam: 'Reported as spam',
  label: 'Label added',
  unlabel: 'Label removed',
  move: 'Moved',
  restore: 'Moved back to the Inbox',
};

const verb: Record<GmailAction['kind'], string> = {
  read: 'mark as read',
  unread: 'mark as unread',
  star: 'star',
  unstar: 'remove the star from',
  archive: 'archive',
  trash: 'move to Trash',
  spam: 'report as spam',
  label: 'label',
  unlabel: 'remove a label from',
  move: 'move',
  restore: 'move back to the Inbox',
};

// What the Inbox says about the latest organizing action.
export const gmailActionCopy = {
  done: (action: GmailAction, subject: string) =>
    `${pastTense[action.kind]}: “${subject}”.`,
  rejected: (action: GmailAction, subject: string) =>
    `Gmail could not ${verb[action.kind]} “${subject}”. The Inbox shows it as Gmail has it.`,
  blocked: (action: GmailAction, subject: string) =>
    `Gmail has not confirmed the request to ${verb[action.kind]} “${subject}” after five attempts. Retry it or discard it to continue.`,
  pending: (count: number) =>
    count === 1
      ? 'One change is saved on this device and waits for Gmail.'
      : `${count} changes are saved on this device and wait for Gmail.`,
  reselection:
    'Selecting a different Google mailbox discards changes still waiting for Gmail in the current mailbox.',
  savedOnly:
    'Organizing mail waits until Gmail can be checked again. Try again to reconnect.',
} as const;

// Shared Gmail decisions; the hosts own only their controls and focus presentation.
const actionLabel: Partial<Record<GmailAction['kind'], string>> = {
  read: 'Mark as read',
  unread: 'Mark as unread',
  star: 'Star',
  unstar: 'Remove star',
  archive: 'Archive',
  trash: 'Move to Trash',
  spam: 'Report spam',
};
export const quickActions = (message: GmailMessage) =>
  [
    message.unread ? gmailAction.read : gmailAction.unread,
    message.labels?.includes('STARRED') === true
      ? gmailAction.unstar
      : gmailAction.star,
    gmailAction.archive,
    gmailAction.trash,
    gmailAction.spam,
  ].map((action) => ({
    name: action.kind,
    label: actionLabel[action.kind] ?? action.kind,
    action,
  }));
