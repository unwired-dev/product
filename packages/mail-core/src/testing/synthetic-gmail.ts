import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Layer from 'effect/Layer';
import * as Schema from 'effect/Schema';

import type { Reply, RequestURL } from './synthetic-relay.ts';

import {
  SyntheticScenario,
  refuse,
  reply,
  requestURL,
} from './synthetic-relay.ts';

// A synthetic Gmail message; `disposition` is served as its Content-Disposition header.
interface SyntheticGmailMessage {
  readonly from?: string;
  readonly subject?: string;
  readonly snippet?: string;
  readonly internalDate?: string;
  readonly labelIds?: readonly string[];
  readonly html?: string;
  readonly text?: string;
  readonly disposition?: string;
}

// A synthetic Gmail mailbox: three Inbox messages over two list pages and one label. Label changes
// from this launch apply; history reports no other changes.
export const SyntheticGmailMessages = Context.Reference<
  Readonly<Record<string, SyntheticGmailMessage>>
>('@private-email/mail-core/testing/SyntheticGmailMessages', {
  defaultValue: () => ({
    '19a0c0ffee000001': {
      from: 'Rowan Hale <rowan@example.invalid>',
      subject: 'Garden plans for spring',
      snippet: 'The seed order arrived. Shall we plan the beds this weekend?',
      internalDate: '1759219200000',
      labelIds: ['INBOX', 'UNREAD'],
      html:
        '<p>The seed order arrived. Shall we plan the beds this weekend?</p>' +
        '<p>Planting notes: <a href="https://example.invalid/garden">garden plan</a></p>' +
        '<img src="https://example.invalid/pixel.gif" alt="">',
    },
    '19a0c0ffee000002': {
      from: '"Ada Brook" <ada@example.invalid>',
      subject: 'Notes from Tuesday',
      snippet: 'Thanks for the thoughtful questions &amp; the follow-up.',
      internalDate: '1759132800000',
      labelIds: ['INBOX'],
      text: 'Thanks for the thoughtful questions & the follow-up.\n\nAda',
    },
    '19a0c0ffee000003': {
      from: 'test@example.invalid',
      subject: 'Welcome to your synthetic Inbox',
      snippet: 'Nothing here came from a real mailbox.',
      internalDate: '1759046400000',
      labelIds: ['INBOX', 'CATEGORY_UPDATES'],
      text: 'Nothing here came from a real mailbox.',
    },
  }),
});

const gmailScope = 'https://www.googleapis.com/auth/gmail.modify';
const mailbox = 'synthetic-alternate-mailbox';
const LabelChange = Schema.fromJsonString(
  Schema.Struct({
    addLabelIds: Schema.optionalKey(Schema.Array(Schema.String)),
    removeLabelIds: Schema.optionalKey(Schema.Array(Schema.String)),
  }),
);
const identity = (subject: string, granted: boolean) => ({
  subject,
  idToken: 'synthetic-identity',
  accessToken: 'synthetic-mail-access',
  scopes: granted ? [gmailScope] : [],
});
// A message's MIME headers, as its single part declares them.
const mimeHeaders = (message: SyntheticGmailMessage, mimeType: string) => [
  { name: 'Content-Type', value: `${mimeType}; charset=UTF-8` },
  ...(message.disposition === undefined
    ? []
    : [{ name: 'Content-Disposition', value: message.disposition }]),
];
const missing: Reply = { status: 404, body: '' };

const mimeTypeOf = (message: SyntheticGmailMessage) =>
  message.html === undefined ? 'text/plain' : 'text/html';
// The body-free preflight prefetch makes: each synthetic message is one part, and only the
// requested admission headers are returned.
const admission = (
  message: SyntheticGmailMessage,
  requested: ReadonlySet<string>,
) => {
  const mimeType = mimeTypeOf(message);
  const headers = mimeHeaders(message, mimeType).filter(({ name }) =>
    requested.has(name.toLowerCase()),
  );
  return { payload: { mimeType, headers } };
};
// The single part with every MIME header and its base64url body.
const full = (message: SyntheticGmailMessage) => {
  const mimeType = mimeTypeOf(message);
  const content = message.html ?? message.text ?? '';
  const data = Base64.encode(content).replaceAll('+', '-').replaceAll('/', '_');
  return {
    payload: {
      mimeType,
      headers: mimeHeaders(message, mimeType),
      body: { size: new TextEncoder().encode(content).length, data },
    },
  };
};
// The message as the Inbox list reads it: its snippet, date and envelope headers.
const summary = (message: SyntheticGmailMessage) => ({
  snippet: message.snippet ?? '',
  historyId: '100',
  internalDate: message.internalDate ?? '',
  payload: {
    headers: [
      { name: 'From', value: message.from ?? '' },
      { name: 'Subject', value: message.subject ?? '' },
    ],
  },
});
// A message as its request's format shows it, beside its identifiers and labels.
function view(message: SyntheticGmailMessage, { item, query }: RequestURL) {
  // Gmail repeats metadataHeaders once per requested header, in any order and case.
  const requested = new Set(
    query
      .filter(([name]) => name === 'metadataHeaders')
      .map(([, value]) => value.toLowerCase()),
  );
  if (
    item('format') === 'metadata' &&
    (requested.has('content-type') || requested.has('content-disposition'))
  ) {
    return admission(message, requested);
  }
  return item('format') === 'full' ? full(message) : summary(message);
}

// Google sign-in and the Gmail API, as the native Google provider sees them.
export class SyntheticGoogle extends Context.Service<SyntheticGoogle>()(
  '@private-email/mail-core/testing/SyntheticGoogle',
  {
    make: Effect.gen(function* () {
      const { scenario } = yield* SyntheticScenario;
      const messages = yield* SyntheticGmailMessages;
      const labels = new Map(
        Object.entries(messages).map(([id, message]) => [
          id,
          message.labelIds ?? [],
        ]),
      );

      const signIn = Effect.fn('SyntheticGoogle.signIn')(function* (
        mail: boolean,
        hint: string | null,
      ) {
        if (!mail) {
          return identity('synthetic-product-subject', false);
        }
        if (hint === null) {
          return identity(mailbox, true);
        }
        switch (scenario) {
          case 'registration-cancelled': {
            return yield* refuse('cancelled');
          }
          case 'registration-no-gmail': {
            return identity('synthetic-no-gmail', true);
          }
          case 'registration-interrupted': {
            return yield* refuse('unavailable');
          }
          default: {
            return identity('synthetic-product-subject', false);
          }
        }
      });
      const refresh = Effect.fn('SyntheticGoogle.refresh')(function* (
        subject: string,
      ) {
        if (!subject.startsWith('synthetic-')) {
          return yield* refuse('invalid-identity');
        }
        return identity(subject, subject === mailbox);
      });
      const verify = Effect.fn('SyntheticGoogle.verify')(function* (
        subject: string,
      ) {
        if (subject === 'synthetic-no-gmail') {
          return yield* refuse('gmail-unavailable');
        }
        return { subject, address: 'other@example.invalid' };
      });

      const modify = Effect.fn('SyntheticGoogle.modify')(function* (
        id: string,
        body: string | null,
      ) {
        const current = labels.get(id);
        const change =
          body === null
            ? undefined
            : yield* Schema.decodeEffect(LabelChange)(body).pipe(
                Effect.orElseSucceed(() => undefined),
              );
        if (current === undefined || change === undefined) {
          return missing;
        }
        const removed = new Set(change.removeLabelIds);
        const remaining = current.filter((label) => !removed.has(label));
        const next = [
          ...remaining,
          ...(change.addLabelIds ?? []).filter(
            (label) => !remaining.includes(label),
          ),
        ];
        labels.set(id, next);
        return yield* reply(200, { id, threadId: id, labelIds: next });
      });
      // Gmail's named resources, by the request's last path segment.
      const resources: Readonly<
        Record<
          string,
          (
            url: RequestURL,
            body: string | null,
          ) => Effect.Effect<Reply, Schema.SchemaError>
        >
      > = {
        profile: () =>
          reply(200, {
            emailAddress: 'other@example.invalid',
            historyId: '100',
          }),
        // Synthetic Gmail accepts every message and keeps nothing of it.
        send: () =>
          reply(200, { id: '19a0c0ffee0000ff', threadId: '19a0c0ffee0000ff' }),
        history: () => reply(200, { historyId: '100' }),
        labels: () =>
          reply(200, {
            labels: [{ id: 'Label_1', name: 'Travel', type: 'user' }],
          }),
        modify: ({ segments }, body) => modify(segments.at(-2) ?? '', body),
        messages: ({ item }) =>
          reply(
            200,
            item('pageToken') === '2'
              ? {
                  messages: [
                    { id: '19a0c0ffee000003', threadId: '19a0c0ffee000003' },
                  ],
                }
              : {
                  messages: ['19a0c0ffee000001', '19a0c0ffee000002'].map(
                    (id) => ({ id, threadId: id }),
                  ),
                  nextPageToken: '2',
                },
          ),
      };
      // One message, as its format asks for it.
      const read = (id: string, url: RequestURL) => {
        const message = Object.hasOwn(messages, id) ? messages[id] : undefined;
        return message === undefined
          ? Effect.succeed(missing)
          : reply(200, {
              id,
              threadId: id,
              labelIds: labels.get(id) ?? [],
              ...view(message, url),
            });
      };
      // One Gmail API request with the identity's access token.
      const gmail = Effect.fn('SyntheticGoogle.gmail')(function* ({
        subject,
        url,
        body,
      }: Readonly<{ subject: string; url: string; body: string | null }>) {
        if (subject !== mailbox) {
          return { status: 401, body: '' };
        }
        const request = requestURL(url);
        const last = request.segments.at(-1) ?? '';
        const resource = Object.hasOwn(resources, last)
          ? resources[last]
          : undefined;
        return yield* resource === undefined
          ? read(last, request)
          : resource(request, body);
      });

      return { signIn, refresh, verify, gmail } as const;
    }),
  },
) {
  /**
   * Consumers provide SyntheticScenario; SyntheticGmailMessages has its default
   * mailbox.
   */
  public static readonly layer = Layer.effect(this, this.make);
}

// Sign in with Apple, whose synthetic identity stays authorized.
export class SyntheticApple extends Context.Service<SyntheticApple>()(
  '@private-email/mail-core/testing/SyntheticApple',
  {
    make: Effect.succeed({
      signIn: Effect.succeed({
        subject: 'synthetic-apple-subject',
        idToken: 'synthetic-apple-identity',
        email: 'relay@privaterelay.example.invalid',
      }),
      credentialState: (subject: string) =>
        Effect.succeed({
          state:
            subject === 'synthetic-apple-subject' ? 'authorized' : 'revoked',
        }),
    } as const),
  },
) {
  public static readonly layer = Layer.effect(this, this.make);
}
