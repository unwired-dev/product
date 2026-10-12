/* oxlint-disable typescript/prefer-readonly-parameter-types -- Tests change the controlled server between steps. */
import * as Arr from 'effect/Array';
import * as Base64 from 'effect/encoding/Base64';
import * as Order from 'effect/Order';

import type { NativeImapMailbox } from '../imap-inbox.ts';

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

export function createSyntheticImap({
  address = 'alex@example.invalid',
}: Readonly<{ address?: string }> = {}) {
  const folders = new Map<string, ServerFolder>([
    [
      'INBOX',
      {
        name: 'INBOX',
        roles: ['inbox'],
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

  const folder = (name: string) => {
    const found = folders.get(name);
    if (found === undefined) {
      throw new Error(`No synthetic folder ${name}`);
    }
    return found;
  };
  const reach = () =>
    server.failure === undefined ? undefined : rejection(server.failure);

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

  const native: NativeImapMailbox = {
    imapFolders: () => {
      server.reads.push('folders');
      return (
        reach() ??
        Promise.resolve({
          folders: [...folders.values()].map(({ name, roles }) => ({
            name,
            roles,
            selectable: true,
          })),
          ...server.capabilities,
        })
      );
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
    cache,
    bodies,
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
    addFolder: (name: string, roles: string[] = []) => {
      folders.set(name, {
        name,
        roles,
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
