import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Schema from 'effect/Schema';

import type { Reply, RequestURL } from './synthetic-relay.ts';

import { refuse, reply, requestURL } from './synthetic-relay.ts';

const message = 'AAMkAGI2-synthetic-outlook=';
const projects = 'AQMkAGI2-synthetic-projects=';
const delta =
  "https://graph.microsoft.com/v1.0/me/mailFolders('inbox')/messages/delta";
const identity = {
  scopes: ['Mail.ReadWrite', 'Mail.Send', 'User.Read', 'offline_access'],
};
const from = {
  emailAddress: { name: 'Jordan Lee', address: 'jordan@example.invalid' },
};
const Change = Schema.fromJsonString(
  Schema.Struct({
    isRead: Schema.optionalKey(Schema.Boolean),
    destinationId: Schema.optionalKey(Schema.String),
  }),
);
const folderID = (name: string) =>
  name === projects ? name : `AQMkAGI2-synthetic-${name}=`;

// A synthetic Microsoft mailbox read, organized and sent from through Graph: one message, in the
// Inbox until a write moves it, a delta round that reports each later change, its text body, the
// mailbox's folders and search. sendMail accepts every message and keeps no Sent Items copy.
export class SyntheticMicrosoft extends Context.Service<SyntheticMicrosoft>()(
  '@private-email/mail-core/testing/SyntheticMicrosoft',
  {
    make: Effect.sync(() => {
      // The message's well-known folder name or folder ID, its read state, and how many writes
      // changed it; a delta link names the count it was issued at.
      let folder = 'inbox';
      let isRead = false;
      let changes = 0;
      const listed = () => ({
        id: message,
        conversationId: 'synthetic-outlook-conversation',
        receivedDateTime: '2025-10-01T09:00:00Z',
        subject: 'Quarterly planning',
        bodyPreview: 'Agenda for Thursday.',
        isRead,
        from,
      });
      const placement = () => ({
        id: message,
        parentFolderId: folderID(folder),
        isRead,
      });

      const write = Effect.fn('SyntheticMicrosoft.write')(function* (
        method: string,
        body: string,
      ) {
        const change = yield* Schema.decodeEffect(Change)(body).pipe(
          Effect.catch(() => refuse('unavailable')),
        );
        isRead = change.isRead ?? isRead;
        folder = change.destinationId ?? folder;
        changes += 1;
        return yield* reply(method === 'POST' ? 201 : 200, placement());
      });
      const deltaRound = ({ search }: RequestURL) => {
        const token = search.split('deltatoken=').at(-1) ?? '';
        const since = /^\d+$/u.test(token) ? Number(token) : -1;
        const inbox = folder === 'inbox';
        const changed = since < 0 || since < changes;
        return reply(200, {
          value:
            changed && (inbox || since >= 0)
              ? [
                  inbox
                    ? listed()
                    : { id: message, '@removed': { reason: 'changed' } },
                ]
              : [],
          '@odata.deltaLink': `${delta}?$deltatoken=${changes}`,
        });
      };
      // Graph's reads, in the order they are matched against the request's path.
      const routes: ReadonlyArray<
        Readonly<{
          matches: (path: string, lower: string) => boolean;
          answer: (url: RequestURL) => Effect.Effect<Reply, Schema.SchemaError>;
        }>
      > = [
        {
          matches: (path) => path.endsWith('/attachments'),
          answer: () => reply(200, { value: [] }),
        },
        { matches: (path) => path.endsWith('/delta'), answer: deltaRound },
        {
          matches: (path, lower) =>
            lower.startsWith('/v1.0/me/mailfolders/') &&
            !path.includes('/messages'),
          answer: ({ segments }) =>
            reply(200, { id: folderID(segments.at(-1) ?? '') }),
        },
        {
          matches: (_, lower) => lower === '/v1.0/me/mailfolders',
          answer: () =>
            reply(200, {
              value: [
                ...[
                  'inbox',
                  'archive',
                  'deleteditems',
                  'junkemail',
                  'drafts',
                  'sentitems',
                  'outbox',
                ].map((name) => ({ id: folderID(name), displayName: name })),
                { id: projects, displayName: 'Projects' },
              ],
            }),
        },
        {
          matches: (path) => path === '/v1.0/me/messages',
          answer: () =>
            reply(200, {
              value: [{ ...listed(), parentFolderId: folderID(folder) }],
            }),
        },
        {
          matches: (path) => path.startsWith('/v1.0/me/messages/'),
          answer: ({ search }) =>
            reply(
              200,
              search.includes('parentFolderId')
                ? placement()
                : {
                    id: message,
                    hasAttachments: false,
                    body: {
                      contentType: 'text',
                      content: 'Agenda for Thursday.\n\nJordan',
                    },
                    from,
                    toRecipients: [
                      { emailAddress: { address: 'casey@example.invalid' } },
                    ],
                  },
            ),
        },
        {
          matches: (_, lower) =>
            lower === '/v1.0/me/mailfolders/sentitems/messages',
          answer: () => reply(200, { value: [] }),
        },
        {
          matches: (_, lower) =>
            lower.startsWith('/v1.0/me/mailfolders/inbox/messages/'),
          answer: () =>
            folder === 'inbox'
              ? reply(200, listed())
              : reply(404, { error: { code: 'ErrorItemNotFound' } }),
        },
      ];
      // One Graph request: a read, or with a body a write by its method. HTTP failures are
      // replies.
      const graph = Effect.fn('SyntheticMicrosoft.graph')(function* ({
        url,
        method,
        body,
        contentType,
      }: Readonly<{
        url: string;
        method: string;
        body: string | null;
        contentType: string;
      }>) {
        if (contentType === 'text/plain') {
          return { status: 202, body: '' };
        }
        if (body !== null) {
          return yield* write(method, body);
        }
        const request = requestURL(url);
        const route = routes.find(({ matches }) =>
          matches(request.path, request.path.toLowerCase()),
        );
        return yield* route === undefined
          ? reply(200, { value: folder === 'inbox' ? [listed()] : [] })
          : route.answer(request);
      });

      return {
        signIn: Effect.succeed(identity),
        refresh: Effect.succeed(identity),
        verify: Effect.succeed({
          subject: 'synthetic-microsoft-account',
          address: 'casey@example.invalid',
          provider: 'microsoft-graph',
        }),
        graph,
      } as const;
    }),
  },
) {
  public static readonly layer = Layer.effect(this, this.make);
}
