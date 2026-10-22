/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the controlled server between steps. */
import * as Arr from 'effect/Array';
import * as Base64 from 'effect/encoding/Base64';
import * as Order from 'effect/Order';

import type { NativeImapMailbox } from '../imap-inbox.ts';

import { createSyntheticRemoteContent } from './remote-content.ts';
import { createSyntheticAttachments } from './saved-attachments.ts';

// A controlled IMAP server behind one connection, with the encrypted cache native code keeps for
// it. Synchronization answers as the native engine does: without a checkpoint at the folder's
// UIDVALIDITY it lists the newest messages again; otherwise it reads the flags of the known
// messages that remain and the messages that arrived since the checkpoint.

interface ServerMessage {
  uid: number;
  flags: string[];
  received: number;
  sender: string;
  address: string;
  subject: string;
  raw: string;
}
interface ServerFolder {
  name: string;
  roles: string[];
  // False for a container that holds other folders but no messages (\Noselect).
  selectable: boolean;
  uidValidity: number;
  uidNext: number;
  messages: ServerMessage[];
}

const newestUid = Order.flip(
  Order.mapInput(Order.Number, ({ uid }: Readonly<ServerMessage>) => uid),
);

// What a FETCH of the message's envelope, flags, date and size reports.
const envelope = ({ raw, ...message }: Readonly<ServerMessage>) => ({
  ...message,
  size: raw.length,
});

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error(`Synthetic ${code}`), { code }));

// A plain-text message with the headers its envelope reports.
export const syntheticRaw = (subject: string, body: string) =>
  [
    'From: Synthetic Sender <sender@example.invalid>',
    'To: alex@example.invalid',
    `Subject: ${subject}`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
    'Content-Transfer-Encoding: quoted-printable',
    '',
    body,
  ].join('\r\n');

// Text segments as sent, with each asset named in place of its bytes.
const rawOf = (
  segments: Parameters<NativeImapMailbox['imapSend']>[0]['segments'],
) =>
  segments
    .map((segment) =>
      'text' in segment ? segment.text : `[asset ${segment.asset.id}]`,
    )
    .join('');
const subjectOf = (raw: string) =>
  /^Subject: (?<subject>.*)$/mu.exec(raw)?.groups?.subject ?? '';

export function createSyntheticImap({
  address = 'alex@example.invalid',
}: Readonly<{ address?: string }> = {}) {
  const folders = new Map<string, ServerFolder>([
    [
      'INBOX',
      {
        name: 'INBOX',
        roles: ['inbox'],
        selectable: true,
        uidValidity: 7,
        uidNext: 1,
        messages: [],
      },
    ],
  ]);
  const server = {
    // The code every server read rejects with, such as `gmail-unavailable` for a refused
    // password or `offline`.
    failure: undefined as string | undefined,
    reads: [] as string[],
    // What the server advertises: MOVE or UIDPLUS, and IDLE.
    capabilities: { moves: true, idle: true },
    // UIDPLUS fallback returns COPYUID before source deletion.
    copyOnly: false,
    // Applies the next change, then loses its reply as a dropped connection would.
    loseReply: false,
    // Changes the server applied, in order.
    changes: [] as string[],
    // Sessions opened and not yet closed.
    sessions: new Set<string>(),
  };
  let sessionCount = 0;
  // The connection's SMTP server: what it accepted, and the code its next submission rejects
  // with, such as `smtp-refused`, `smtp-rejected`, `offline` or `delivery-unknown`. `lost`
  // accepts the next submission and loses its reply, as a dropped connection would; `stopped`
  // accepts it and never answers, as when the app stops meanwhile.
  const smtp = {
    accepted: [] as Array<{ raw: string; recipients: readonly string[] }>,
    failure: undefined as string | undefined,
    lost: false,
    stopped: false,
  };
  // IDLE waits in progress; `notify` ends them as a change would.
  const idles: Array<(changed: boolean) => void> = [];
  const cache = {
    revision: 0,
    generation: 'generation-1',
    document: null as string | null,
    availability: undefined as 'retry' | undefined,
    commits: 0,
  };
  const bodies = new Map<string, string>();
  // Downloaded Attachments native code saved for the connection.
  const files = createSyntheticAttachments(
    (owner) => owner.generation === cache.generation,
  );

  const folder = (name: string) => {
    const found = folders.get(name);
    if (found === undefined) {
      throw new Error(`No synthetic folder ${name}`);
    }
    return found;
  };
  const reach = () =>
    server.failure === undefined ? undefined : rejection(server.failure);
  // A command on a session that is not open is refused, as native code refuses a closed handle.
  const inSession = (session: string) =>
    server.sessions.has(session) ? reach() : rejection('mailbox-invalidated');

  // Applies or loses a change's reply, as the connection would.
  const answer = (reply: unknown) => {
    if (server.loseReply) {
      server.loseReply = false;
      return rejection('imap-interrupted');
    }
    return Promise.resolve(reply);
  };
  const storeRead = (
    change: Readonly<{ folder: string; uid: number; read?: boolean }>,
    message: ServerMessage,
  ) => {
    const seen = String.raw`\Seen`;
    message.flags = [
      ...message.flags.filter((flag) => flag !== seen),
      ...(change.read === true ? [seen] : []),
    ];
    server.changes.push(
      `${change.read === true ? 'read' : 'unread'} ${change.folder} ${change.uid}`,
    );
    return { outcome: 'stored' };
  };
  // MOVE, with the new UID the server reports.
  const moveTo = ({
    name,
    source,
    message,
    uid,
  }: Readonly<{
    name: string;
    source: ServerFolder;
    message: ServerMessage;
    uid: number;
  }>) => {
    if (!server.capabilities.moves) {
      return rejection('imap-unsupported');
    }
    const destination = folders.get(name);
    if (destination === undefined) {
      return rejection('imap-rejected');
    }
    if (!server.copyOnly) {
      source.messages = source.messages.filter((item) => item !== message);
    }
    const moved = destination.uidNext;
    destination.uidNext += 1;
    destination.messages.push({ ...message, uid: moved });
    server.changes.push(
      `${server.copyOnly ? 'copy' : 'move'} ${source.name} ${uid} ${name}`,
    );
    return answer({
      outcome: server.copyOnly ? 'copied' : 'moved',
      uidValidity: destination.uidValidity,
      uid: moved,
    });
  };

  const finishCopy = ({
    source,
    change,
    copied,
  }: Readonly<{
    source: ServerFolder;
    change: Parameters<NativeImapMailbox['imapModify']>[1];
    copied: Readonly<{ uidValidity: number; uid: number }>;
  }>) => {
    const target = folders.get(change.destination ?? '');
    if (target?.uidValidity !== copied.uidValidity) {
      return rejection('imap-changed');
    }
    if (!target.messages.some(({ uid }) => uid === copied.uid)) {
      return rejection('imap-missing');
    }
    source.messages = source.messages.filter(({ uid }) => uid !== change.uid);
    server.changes.push(`delete ${change.folder} ${change.uid}`);
    return answer({ outcome: 'moved', ...copied });
  };

  // A controlled image server for the connection's Remote Message Content.
  const remote = createSyntheticRemoteContent(
    (owner) =>
      owner.address === address && owner.generation === cache.generation,
    () => address,
  );
  const native: NativeImapMailbox = {
    ...remote.native,
    imapSend: (message) => {
      const { failure } = smtp;
      smtp.failure = undefined;
      if (failure !== undefined) {
        return rejection(failure);
      }
      smtp.accepted.push({
        raw: rawOf(message.segments),
        recipients: message.recipients,
      });
      if (smtp.lost) {
        smtp.lost = false;
        return rejection('delivery-unknown');
      }
      if (smtp.stopped) {
        // oxlint-disable-next-line promise/avoid-new -- A submission that never answers.
        return new Promise<never>(() => {
          // Never settles.
        });
      }
      return Promise.resolve({ accepted: true });
    },
    imapFileSent: (_mailbox, request) => {
      server.reads.push(`file ${request.folder}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      const sent = folders.get(request.folder);
      if (sent === undefined) {
        return rejection('imap-missing');
      }
      if (sent.messages.some(({ raw }) => raw.includes(request.boundary))) {
        return Promise.resolve({});
      }
      const raw = rawOf(request.segments);
      sent.messages.push({
        uid: sent.uidNext,
        flags: [String.raw`\Seen`],
        received: Date.UTC(2026, 9, 1, 9, sent.uidNext),
        sender: 'Alex',
        address,
        subject: subjectOf(raw),
        raw,
      });
      sent.uidNext += 1;
      server.changes.push(`append ${request.folder}`);
      return answer({});
    },
    imapFindSent: (_mailbox, request) => {
      server.reads.push(`find ${request.folder}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      return Promise.resolve({
        count:
          folders
            .get(request.folder)
            ?.messages.filter(({ raw }) => raw.includes(request.boundary))
            .length ?? 0,
      });
    },
    imapOpen: () => {
      server.reads.push('login');
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      sessionCount += 1;
      const session = `session-${sessionCount}`;
      server.sessions.add(session);
      return Promise.resolve({ session });
    },
    imapCapabilities: (_mailbox, { session }) =>
      inSession(session) ??
      Promise.resolve({
        capabilities: [
          'IMAP4rev1',
          ...(server.capabilities.moves ? ['MOVE', 'UIDPLUS'] : []),
          ...(server.capabilities.idle ? ['IDLE'] : []),
        ],
      }),
    imapListFolders: (_mailbox, { session }) => {
      server.reads.push('folders');
      return (
        inSession(session) ??
        Promise.resolve({
          folders: [...folders.values()].map(({ name, roles, selectable }) => ({
            name,
            // The special-use attributes the roles come from, as LIST reports them.
            attributes: [
              ...roles
                .filter((role) => role !== 'inbox')
                .map(
                  (role) => `\\${role.charAt(0).toUpperCase()}${role.slice(1)}`,
                ),
              ...(selectable ? [] : [String.raw`\Noselect`]),
            ],
            delimiter: '/',
          })),
        })
      );
    },
    imapClose: (_mailbox, { session }) => {
      server.sessions.delete(session);
      return Promise.resolve({});
    },
    imapModify: (_mailbox, change) => {
      server.reads.push(`modify ${change.folder} ${change.uid}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      const source = folders.get(change.folder);
      if (source === undefined) {
        return rejection('imap-missing');
      }
      if (source.uidValidity !== change.uidValidity) {
        return rejection('imap-changed');
      }
      if (change.copied !== undefined) {
        return finishCopy({ source, change, copied: change.copied });
      }
      const message = source.messages.find(({ uid }) => uid === change.uid);
      if (message === undefined) {
        return Promise.resolve({ outcome: 'absent' });
      }
      return change.destination === undefined
        ? answer(storeRead(change, message))
        : moveTo({
            name: change.destination,
            source,
            message,
            uid: change.uid,
          });
    },
    imapSearch: (_mailbox, request) => {
      server.reads.push(`search ${request.folders.join(',')}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      const query = request.query.toLowerCase();
      const searched = request.folders.flatMap((name) => {
        const current = folders.get(name);
        if (current === undefined) {
          return [];
        }
        const matches = Arr.sort(
          current.messages.filter(
            ({ subject, raw }) =>
              subject.toLowerCase().includes(query) ||
              raw.toLowerCase().includes(query),
          ),
          newestUid,
        );
        return [
          {
            folder: name,
            uidValidity: current.uidValidity,
            messages: matches.slice(0, 50).map(envelope),
            more: matches.length > 50,
          },
        ];
      });
      return Promise.resolve({
        folders: searched.filter(({ messages }) => messages.length > 0),
        skipped: request.folders.length - searched.length,
      });
    },
    imapIdle: (_mailbox, request) => {
      server.reads.push(`idle ${request.folder}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      if (!server.capabilities.idle) {
        return rejection('imap-unsupported');
      }
      // oxlint-disable-next-line promise/avoid-new -- The controlled server holds the wait until the test notifies it.
      return new Promise((resolve) => {
        idles.push((changed) => {
          resolve({ changed });
        });
      });
    },
    imapSynchronize: (_mailbox, request) => {
      server.reads.push(`synchronize ${request.folder}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      const current = folder(request.folder);
      const newest = Arr.sort(current.messages, newestUid).slice(
        0,
        request.window,
      );
      if (
        request.from === undefined ||
        request.from.uidValidity !== current.uidValidity
      ) {
        return Promise.resolve({
          uidValidity: current.uidValidity,
          uidNext: current.uidNext,
          reset: true,
          messages: newest.map(envelope),
          flags: [],
        });
      }
      const { from } = request;
      const known = new Set(from.known);
      return Promise.resolve({
        uidValidity: current.uidValidity,
        uidNext: current.uidNext,
        reset: false,
        messages: current.messages
          .filter(({ uid }) => uid >= from.uidNext)
          .map(envelope),
        flags: current.messages
          .filter(({ uid }) => known.has(uid))
          .map(({ uid, flags }) => ({ uid, flags })),
      });
    },
    imapMessage: (_mailbox, request) => {
      server.reads.push(`message ${request.folder} ${request.uid}`);
      const failed = reach();
      if (failed !== undefined) {
        return failed;
      }
      const current = folder(request.folder);
      if (current.uidValidity !== request.uidValidity) {
        return rejection('imap-changed');
      }
      const message = current.messages.find(({ uid }) => uid === request.uid);
      return message === undefined
        ? rejection('imap-missing')
        : Promise.resolve({
            data: Base64.encode(new TextEncoder().encode(message.raw)),
          });
    },
    openMailbox: () =>
      Promise.resolve({
        revision: cache.revision,
        address,
        generation: cache.generation,
        document: cache.document,
        ...(cache.availability === undefined
          ? {}
          : { availability: cache.availability }),
      }),
    commitMailbox: (mailbox, expectedRevision, document) => {
      if (mailbox.generation !== cache.generation) {
        return rejection('mailbox-invalidated');
      }
      if (expectedRevision !== cache.revision) {
        return rejection('conflict');
      }
      cache.revision += 1;
      cache.commits += 1;
      cache.document = document;
      return Promise.resolve({ revision: cache.revision });
    },
    openMessageBody: (_mailbox, id) =>
      Promise.resolve({ document: bodies.get(id) ?? null }),
    commitMessageBody: (_mailbox, id, admission) => {
      bodies.set(id, admission.document);
      return Promise.resolve({ admitted: true });
    },
    listMessageBodies: (_mailbox, ids) =>
      Promise.resolve({
        stored: ids.filter((id) => bodies.has(id)),
        excluded: [],
      }),
    ...files.native,
    // Removes every body not named, only at the cache revision the caller read.
    retainMessageBodies: (mailbox, ids) => {
      if (mailbox.revision !== cache.revision) {
        return rejection('conflict');
      }
      const kept = new Set(ids);
      for (const id of bodies.keys()) {
        if (!kept.has(id)) {
          bodies.delete(id);
        }
      }
      return Promise.resolve(null);
    },
  };

  return {
    native,
    server,
    smtp,
    cache,
    bodies,
    files,
    ...remote.controls,
    // Ends every IDLE wait, as a change to the watched folder or the wait's bound would.
    notify: (changed = true) => {
      for (const end of idles.splice(0)) {
        end(changed);
      }
    },
    idling: () => idles.length,
    // Delivers a message to a folder, as an SMTP injection would.
    deliver: (
      name: string,
      message: Readonly<{
        subject: string;
        body?: string;
        raw?: string;
        received?: number;
        flags?: string[];
      }>,
    ) => {
      const current = folder(name);
      const uid = current.uidNext;
      current.uidNext += 1;
      current.messages.push({
        uid,
        flags: message.flags ?? [],
        received: message.received ?? Date.UTC(2026, 9, 1, 9, uid),
        sender: 'Synthetic Sender',
        address: 'sender@example.invalid',
        subject: message.subject,
        raw: message.raw ?? syntheticRaw(message.subject, message.body ?? ''),
      });
      return uid;
    },
    addFolder: (name: string, roles: string[] = [], selectable = true) => {
      folders.set(name, {
        name,
        roles,
        selectable,
        uidValidity: 3,
        uidNext: 1,
        messages: [],
      });
    },
    // Deletes a folder, as another client removing or renaming it would.
    removeFolder: (name: string) => {
      folders.delete(name);
    },
    setFlags: (name: string, uid: number, flags: string[]) => {
      const message = folder(name).messages.find((item) => item.uid === uid);
      if (message !== undefined) {
        message.flags = flags;
      }
    },
    expunge: (name: string, uid: number) => {
      const current = folder(name);
      current.messages = current.messages.filter((item) => item.uid !== uid);
    },
    // The server recreated the folder: every UID from before is gone.
    renumber: (name: string) => {
      const current = folder(name);
      current.uidValidity += 1;
      current.messages = current.messages.map((message, index) => ({
        ...message,
        uid: current.uidNext + index,
      }));
      current.uidNext += current.messages.length;
    },
  };
}
