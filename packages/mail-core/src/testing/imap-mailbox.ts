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
  };
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
        })
      );
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
  };

  return {
    native,
    server,
    cache,
    bodies,
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
