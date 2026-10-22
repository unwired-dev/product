import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Schema from 'effect/Schema';

import type { Reply, RequestURL } from './synthetic-relay.ts';

import { syntheticPerformanceCount } from './synthetic-gmail.ts';
import {
  SyntheticScenario,
  refuse,
  reply,
  requestURL,
} from './synthetic-relay.ts';

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

// The `registration-performance` mailbox adds older Inbox messages, each its own conversation and
// never written to, for the warm-cache performance journey; Outlook update 001 is the newest.
const performance = new Map(
  Array.from({ length: syntheticPerformanceCount }, (_, index) => {
    const number = String(index + 1).padStart(3, '0');
    const id = `AAMkAGI2-synthetic-performance-${number}=`;
    const text = `Outlook update ${number} body. Nothing here came from a real mailbox.`;
    return [
      id,
      {
        listed: {
          id,
          conversationId: `synthetic-performance-conversation-${number}`,
          // An hour after each Gmail update, so the unified Inbox alternates them.
          receivedDateTime: new Date(
            1_758_000_000_000 - index * 7_200_000 - 3_600_000,
          ).toISOString(),
          subject: `Outlook update ${number}`,
          bodyPreview: `Outlook update ${number} preview.`,
          isRead: true,
          from: {
            emailAddress: {
              name: `Colleague ${number}`,
              address: `colleague${number}@example.invalid`,
            },
          },
        },
        text,
      },
    ] as const;
  }),
);

// A synthetic Microsoft mailbox read, organized and sent from through Graph: one message, in the
// Inbox until a write moves it, a delta round that reports each later change, its text body, the
// mailbox's folders and search. sendMail accepts every message and keeps no Sent Items copy.
export class SyntheticMicrosoft extends Context.Service<SyntheticMicrosoft>()(
  '@private-email/mail-core/testing/SyntheticMicrosoft',
  {
    make: Effect.gen(function* () {
      const { scenario } = yield* SyntheticScenario;
      const extra = new Map(
        scenario === 'registration-performance' ? performance : [],
      );
      const extraListed = () =>
        [...extra.values()].map(({ listed: item }) => item);
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
          value: [
            ...(changed && (inbox || since >= 0)
              ? [
                  inbox
                    ? listed()
                    : { id: message, '@removed': { reason: 'changed' } },
                ]
              : []),
            ...(since < 0 ? extraListed() : []),
          ],
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
          matches: (path) =>
            path.startsWith('/v1.0/me/messages/') &&
            extra.has(path.split('/').at(-1) ?? ''),
          answer: ({ search, segments }) => {
            const id = segments.at(-1) ?? '';
            return reply(
              200,
              search.includes('parentFolderId')
                ? { id, parentFolderId: folderID('inbox'), isRead: true }
                : {
                    id,
                    hasAttachments: false,
                    body: { contentType: 'text', content: extra.get(id)?.text },
                    from: extra.get(id)?.listed.from,
                    toRecipients: [
                      { emailAddress: { address: 'casey@example.invalid' } },
                    ],
                  },
            );
          },
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
          answer: ({ segments }) => {
            const found = extra.get(segments.at(-1) ?? '')?.listed;
            if (found !== undefined) {
              return reply(200, found);
            }
            return folder === 'inbox'
              ? reply(200, listed())
              : reply(404, { error: { code: 'ErrorItemNotFound' } });
          },
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
          ? reply(200, {
              value: [
                ...(folder === 'inbox' ? [listed()] : []),
                // Only the Inbox listing holds the added messages.
                ...(request.path.toLowerCase() ===
                '/v1.0/me/mailfolders/inbox/messages'
                  ? extraListed()
                  : []),
              ],
            })
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
