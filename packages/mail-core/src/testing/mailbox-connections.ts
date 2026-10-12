import type { NativeGmailMailbox } from '../gmail-inbox.ts';
import type { NativeImapMailbox } from '../imap-inbox.ts';
import type { NativeGmailMailboxes } from '../mailboxes.ts';

const missing = () =>
  Promise.reject(
    Object.assign(new Error('Synthetic gmail-unavailable'), {
      code: 'gmail-unavailable',
    }),
  );

// Several controlled Gmail or Microsoft mailboxes behind one native module. Each call reaches only the mailbox
// of the connection it names, as native code routes it; another connection's ID reaches nothing.
export function syntheticConnections(
  mailboxes: Readonly<Record<string, Readonly<{ native: NativeGmailMailbox }>>>,
  // Controlled IMAP servers by connection; their cache calls reach only them.
  imap: Readonly<Record<string, NativeImapMailbox>> = {},
): NativeGmailMailboxes {
  const of = (connection: string) =>
    Object.hasOwn(mailboxes, connection)
      ? mailboxes[connection]?.native
      : undefined;
  const server = (connection: string) =>
    Object.hasOwn(imap, connection) ? imap[connection] : undefined;
  return {
    imapFolders: (mailbox) =>
      server(mailbox.connection)?.imapFolders(mailbox) ?? missing(),
    imapSynchronize: (mailbox, request) =>
      server(mailbox.connection)?.imapSynchronize(mailbox, request) ??
      missing(),
    imapMessage: (mailbox, message) =>
      server(mailbox.connection)?.imapMessage(mailbox, message) ?? missing(),
    gmailRequest: (path, query, mailbox) =>
      of(mailbox.connection)?.gmailRequest(path, query, mailbox) ?? missing(),
    graphRequest: (url, mailbox) =>
      of(mailbox.connection)?.graphRequest(url, mailbox) ?? missing(),
    gmailModify: (change, mailbox) =>
      of(mailbox.connection)?.gmailModify(change, mailbox) ?? missing(),
    gmailSend: (message, mailbox) =>
      of(mailbox.connection)?.gmailSend(message, mailbox) ?? missing(),
    openMailbox: (connection) =>
      (server(connection) ?? of(connection))?.openMailbox() ?? missing(),
    commitMailbox: (mailbox, revision, document) =>
      (server(mailbox.connection) ?? of(mailbox.connection))?.commitMailbox(
        mailbox,
        revision,
        document,
      ) ?? missing(),
    openMessageBody: (mailbox, id) =>
      (server(mailbox.connection) ?? of(mailbox.connection))?.openMessageBody(
        mailbox,
        id,
      ) ?? missing(),
    commitMessageBody: (mailbox, id, admission) => {
      const imapServer = server(mailbox.connection);
      return (
        (admission.tier === 'opened'
          ? imapServer?.commitMessageBody(mailbox, id, {
              ...admission,
              tier: 'opened',
            })
          : undefined) ??
        of(mailbox.connection)?.commitMessageBody(mailbox, id, admission) ??
        missing()
      );
    },
    listMessageBodies: (mailbox, ids) =>
      (server(mailbox.connection) ?? of(mailbox.connection))?.listMessageBodies(
        mailbox,
        ids,
      ) ?? missing(),
    retainMessageBodies: (mailbox, ids, protectedIds) =>
      (
        server(mailbox.connection) ?? of(mailbox.connection)
      )?.retainMessageBodies(mailbox, ids, protectedIds) ?? missing(),
    saveAttachment: (mailbox, attachment) =>
      of(mailbox.connection)?.saveAttachment(mailbox, attachment) ?? missing(),
    discardAttachment: (mailbox, file) =>
      of(mailbox.connection)?.discardAttachment(mailbox, file) ?? missing(),
    presentAttachment: (mailbox, file, action) =>
      of(mailbox.connection)?.presentAttachment(mailbox, file, action) ??
      missing(),
    openRemoteContent: (mailbox, resource) =>
      of(mailbox.connection)?.openRemoteContent(mailbox, resource) ?? missing(),
    touchRemoteContent: (mailbox, resource) =>
      of(mailbox.connection)?.touchRemoteContent(mailbox, resource) ??
      missing(),
    fetchRemoteContent: (mailbox, url, request) =>
      of(mailbox.connection)?.fetchRemoteContent(mailbox, url, request) ??
      missing(),
    cancelRemoteContent: (mailbox, session, finished) =>
      of(mailbox.connection)?.cancelRemoteContent(mailbox, session, finished) ??
      missing(),
    commitRemoteContent: (mailbox, resource, admission) =>
      of(mailbox.connection)?.commitRemoteContent(
        mailbox,
        resource,
        admission,
      ) ?? missing(),
  };
}
