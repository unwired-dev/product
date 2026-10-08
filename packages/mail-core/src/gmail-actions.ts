import type { Translate } from '@private-email/localization';

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

// What the Inbox says about an organizing action's outcome; only unsaved changes are counted.
export const gmailActionCopy = (
  t: Translate,
  {
    kind,
    action,
    message,
    count = 1,
  }: Readonly<{
    kind: 'done' | 'rejected' | 'unsaved' | 'blocked';
    action: GmailAction;
    message: Readonly<{ subject: string }>;
    count?: number;
  }>,
) =>
  kind === 'unsaved'
    ? t('gmailActions.unsaved', {
        context: action.kind,
        subject: message.subject,
        count,
      })
    : t(`gmailActions.${kind}`, {
        context: action.kind,
        subject: message.subject,
      });

// A message whose Gmail labels are not known yet, from a cache saved before labels were kept,
// offers no actions until it is listed again: Undo could not tell which labels it already had.
export const canOrganize = (message: GmailMessage) =>
  message.labels !== undefined;

export const quickActions = (t: Translate, message: GmailMessage) =>
  (canOrganize(message)
    ? [
        message.unread ? gmailAction.read : gmailAction.unread,
        message.labels?.includes('STARRED') === true
          ? gmailAction.unstar
          : gmailAction.star,
        gmailAction.archive,
        gmailAction.trash,
        gmailAction.spam,
      ]
    : []
  ).map((action) => ({
    name: action.kind,
    label: t(`gmailActions.label.${action.kind}`),
    action,
  }));
