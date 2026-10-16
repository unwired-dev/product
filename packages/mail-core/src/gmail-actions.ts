import type { Translate } from '@private-email/localization';

import * as Schema from 'effect/Schema';

import type { GmailMessage } from './mailbox-message.ts';
import type { MailProvider } from './registration-snapshot.ts';

// Gmail organizes mail with labels: Inbox, Trash, Spam, read state and stars are system labels
// that one message modify request adds or removes. Microsoft mail uses the same actions on its
// folders, whose IDs are URL-safe base64; native Gmail code accepts only Gmail's label IDs.
const LabelId = Schema.String.check(Schema.isPattern(/^[\w=-]{1,512}$/u));

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

// Gmail's All Mail view has no label of its own: it lists every message outside Spam and Trash.
export const allMail = 'ALL_MAIL';
// The views every Gmail mailbox has after its Inbox and its own labels.
export const systemViews = [allMail, 'SPAM', 'TRASH'] as const;

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
  // Gmail's Move to: the label replaces the view's label, or the Inbox from All Mail, and every
  // other label stays.
  move: (label: string, view = 'INBOX'): GmailAction => ({
    kind: 'move',
    add: [label],
    remove: label === view ? [] : [view === allMail ? 'INBOX' : view],
  }),
  // Takes a message out of Trash or Spam and back into the Inbox.
  restore: (view: string) => ({
    kind: 'restore' as const,
    add: ['INBOX'],
    remove: [view],
  }),
} as const satisfies Record<
  string,
  GmailAction | ((label: string) => GmailAction)
>;

// Spam and Trash list only their own messages, and every other view leaves them out.
export const inView = (view: string, labels: readonly string[]) =>
  view === 'SPAM' || view === 'TRASH'
    ? labels.includes(view)
    : !labels.includes('SPAM') &&
      !labels.includes('TRASH') &&
      (view === allMail || labels.includes(view));

export const inInbox = (labels: readonly string[]) => inView('INBOX', labels);

// A Gmail view's name: the Inbox, one of the mailbox's own labels, All Mail, Spam or Trash.
export const gmailViewTitle = (
  t: Translate,
  view: string,
  labels: readonly GmailLabel[],
) => {
  if (view === allMail) {
    return t('mailboxes.allMail');
  }
  if (view === 'SPAM' || view === 'TRASH') {
    return t(view === 'SPAM' ? 'mailboxes.spam' : 'mailboxes.trash');
  }
  return labels.find(({ id }) => id === view)?.name ?? t('inbox.title');
};

const viewSymbols: Readonly<Record<string, string>> = {
  INBOX: 'tray',
  [allMail]: 'tray.2',
  SPAM: 'xmark.bin',
  TRASH: 'trash',
};
// The SF Symbol of a Gmail view's sidebar row; a label is a folder.
export const gmailViewSymbol = (view: string) => viewSymbols[view] ?? 'folder';

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

// What the Inbox says about an organizing action's outcome at `provider`, the mail provider's
// name; only unsaved changes are counted.
export const gmailActionCopy = (
  t: Translate,
  {
    kind,
    action,
    message,
    count = 1,
  }: Readonly<{
    kind: 'done' | 'rejected' | 'unsaved' | 'blocked';
    // An IMAP change uses the same kinds.
    action: Readonly<{ kind: GmailAction['kind'] }>;
    message: Readonly<{ subject: string }>;
    count?: number;
  }>,
  provider: string,
) =>
  kind === 'unsaved'
    ? t('gmailActions.unsaved', {
        context: action.kind,
        subject: message.subject,
        count,
        provider,
      })
    : t(`gmailActions.${kind}`, {
        context: action.kind,
        subject: message.subject,
        provider,
      });

// A message whose Gmail labels are not known yet, from a cache saved before labels were kept,
// offers no actions until it is listed again: Undo could not tell which labels it already had.
export const canOrganize = (message: GmailMessage) =>
  message.labels !== undefined;

// Whether an action takes a message shown in `view` out of it.
export const leavesView = (
  view: string,
  labels: readonly string[],
  action: GmailAction,
) => inView(view, labels) && !inView(view, relabel(labels, action));

// Microsoft mail has no star; its Spam is the Junk Email folder. Mail in Gmail's Trash or Spam
// moves back to the Inbox instead of being archived, trashed or reported again.
export const quickActions = (
  t: Translate,
  message: GmailMessage,
  {
    provider = 'gmail',
    unavailableActions = [],
    view = 'INBOX',
  }: Readonly<{
    provider?: MailProvider;
    unavailableActions?: ReadonlyArray<GmailAction['kind']> | undefined;
    view?: string | undefined;
  }> = {},
) =>
  (canOrganize(message)
    ? [
        message.unread ? gmailAction.read : gmailAction.unread,
        ...(provider === 'gmail'
          ? [
              message.labels?.includes('STARRED') === true
                ? gmailAction.unstar
                : gmailAction.star,
            ]
          : []),
        ...(view === 'TRASH' || view === 'SPAM'
          ? [gmailAction.restore(view)]
          : [
              // A label or All Mail can list mail already out of the Inbox, which Archive cannot move.
              ...(view === 'INBOX' || message.labels?.includes('INBOX') === true
                ? [gmailAction.archive]
                : []),
              gmailAction.trash,
              gmailAction.spam,
            ]),
      ]
    : []
  )
    .filter((action) => !unavailableActions.includes(action.kind))
    .map((action) => ({
      name: action.kind,
      label: t(`gmailActions.label.${action.kind}`),
      action,
    }));
