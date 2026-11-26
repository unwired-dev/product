// A received message's standards-based unsubscribe mechanism (ADR 0044), read only from its list
// headers, never from body prose. Nothing here leaves the device.

import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { DraftStorageFailure } from './draft-native.ts';
import type { BodyDocument } from './message-body.ts';
import type { Registration } from './registration.ts';

import {
  decodeDiagnostic,
  rejectionDiagnostic,
  runLogged,
} from './diagnostics.ts';
import { malformed, native as stored, ownerMismatch } from './draft-native.ts';
import { ownerOf } from './drafts.ts';
import { withoutComments } from './message-body.ts';

// What a message offers for leaving its mailing list: an RFC 8058 one-click HTTPS request, or else
// an RFC 2369 mailto message to one address. `list` names the list for the person, and `identity`
// is its Mailing List Identity, present only when the List-Id header conveys one.
export type UnsubscribeOffer = Readonly<{ list: string; identity?: string }> &
  (
    | Readonly<{ kind: 'one-click'; url: string }>
    | Readonly<{
        kind: 'mailto';
        address: string;
        subject?: string;
        body?: string;
      }>
  );

// An HTTPS address whose authority is a host name and an optional port; React Native has no
// complete URL parser.
const oneClickUrl =
  /^https:\/\/[a-z\d-]+(?:\.[a-z\d-]+)*(?::(?<port>\d{1,5}))?(?:[/?#][^\s\p{Cc}]*)?$/iu;
const isOneClickUrl = (uri: string) => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [match, port] = oneClickUrl.exec(uri) ?? [];
  return (
    match !== undefined &&
    (port === undefined || (Number(port) >= 1 && Number(port) <= 65_535))
  );
};
// One address, then optional header fields.
const mailtoUrl = /^mailto:(?<address>[^?,]+)(?:\?(?<query>.*))?$/iu;
const addressPattern =
  /^[^\s@<>()[\]\\,;:"]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]{2,}$/u;
// An RFC 2919 list identifier: dot-atom text with a label and a namespace, which no URI with a
// scheme matches.
const listIdentifier =
  /^[\w!#$%&'*+/=?^`{|}~-]+(?:\.[\w!#$%&'*+/=?^`{|}~-]+)+$/u;

const decoded = (value: string) => {
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
};

// How many comments the text between URIs opens, less those it closes; escapes are not delimiters.
const nesting = (text: string) => {
  const plain = text.replaceAll(/\\./gsu, '');
  return plain.split('(').length - plain.split(')').length;
};

// The bracketed URIs of a List-Unsubscribe header, in order. Brackets inside a comment are not
// URIs, and whitespace inside one is ignored.
const urisOf = (header: string) => {
  let depth = 0;
  // Splitting on a capture group alternates the text between URIs with the URIs themselves.
  return header.split(/(?<uri><[^<>]*>)/u).flatMap((part, index) => {
    // Text between URIs, or a bracketed part inside a comment, which may open or close comments.
    if (index % 2 === 0 || depth > 0) {
      depth = Math.max(depth + nesting(part), 0);
      return [];
    }
    return depth === 0 ? [part.slice(1, -1).replaceAll(/\s/gu, '')] : [];
  });
};

// The subject and body a mailto query names, or undefined when a field does not decode. Other
// fields, such as cc, are left out: they would add recipients.
const fieldsOf = (query: string) => {
  const fields: { subject?: string; body?: string } = {};
  for (const field of query.split('&')) {
    const [name = '', value = ''] = field.split('=', 2);
    const key = decoded(name)?.toLowerCase();
    const text = decoded(value);
    if (key === undefined || text === undefined) {
      return undefined;
    }
    if ((key === 'subject' || key === 'body') && text !== '') {
      fields[key] = text;
    }
  }
  return fields;
};

const mailtoOf = (uri: string) => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, rawAddress = '', query = ''] = mailtoUrl.exec(uri) ?? [];
  const address = decoded(rawAddress);
  const fields = fieldsOf(query);
  return address === undefined ||
    !addressPattern.test(address) ||
    fields === undefined
    ? undefined
    : { address, ...fields };
};

// A header's display phrase before its last bracketed part, unquoted.
const phraseOf = (header: string) => {
  const phrase = header.slice(0, Math.max(header.lastIndexOf('<'), 0)).trim();
  return (
    /^"(?<text>.*)"$/su
      .exec(phrase)?.[1]
      ?.replaceAll(/\\(?<char>.)/gsu, '$1') ?? phrase
  );
};

// A header's last bracketed part, or the whole header without brackets.
const bracketedOf = (header: string) =>
  header
    .slice(header.lastIndexOf('<') + 1)
    .replace(/>.*$/su, '')
    .trim();

// The list's name: the List-Id's phrase, else the sender's display name or address. Its identity:
// the List-Id's identifier without case; a sender's address is not one, since several lists can
// share it. Each read is linear in the sender-controlled header.
const listOf = (headers: NonNullable<BodyDocument['headers']>) => {
  const listId = withoutComments(headers.listId ?? '', ' ');
  const from = withoutComments(headers.from ?? '', ' ');
  const address = bracketedOf(from);
  const name =
    phraseOf(listId) ||
    phraseOf(from) ||
    (addressPattern.test(address) ? address : '');
  // RFC 2919 lets whitespace sit around the identifier's dots; it is no part of the identifier.
  // Elsewhere, as where a comment was, it leaves the identifier invalid.
  const identifier = listId.includes('<')
    ? bracketedOf(listId)
        .split('.')
        .map((atom) => atom.trim())
        .join('.')
    : '';
  return name === ''
    ? undefined
    : {
        list: name,
        ...(listIdentifier.test(identifier)
          ? { identity: identifier.toLowerCase() }
          : {}),
      };
};

// The message's unsubscribe offer, or undefined when its headers name no usable mechanism.
export function unsubscribeOf(
  document: Pick<BodyDocument, 'headers'> | undefined,
): UnsubscribeOffer | undefined {
  const headers = document?.headers;
  const list =
    headers?.listUnsubscribe === undefined ? undefined : listOf(headers);
  if (headers?.listUnsubscribe === undefined || list === undefined) {
    return undefined;
  }
  const uris = urisOf(headers.listUnsubscribe);
  const oneClick =
    headers.listUnsubscribePost?.trim() === 'List-Unsubscribe=One-Click'
      ? uris.find(isOneClickUrl)
      : undefined;
  if (oneClick !== undefined) {
    return { kind: 'one-click', ...list, url: oneClick };
  }
  for (const uri of uris) {
    const mailto = mailtoOf(uri);
    if (mailto !== undefined) {
      return { kind: 'mailto', ...list, ...mailto };
    }
  }
  return undefined;
}

// How a one-click request ended: the server accepted it, nothing was sent or the server refused
// it, or it may have arrived without a usable answer.
const Outcome = Schema.Literals(['sent', 'failed', 'uncertain']);
export type UnsubscribeOutcome = typeof Outcome.Type;

const decodeAnswer = Schema.decodeUnknownEffect(
  Schema.Struct({ outcome: Outcome }),
);

export interface NativeUnsubscribe {
  // Sends an RFC 8058 one-click request once over the isolated native path (ADR 0044) and
  // resolves `{ outcome }`.
  readonly requestUnsubscribe: (url: string) => Promise<unknown>;
}

// Sends a one-click offer's request once; it is never retried automatically. A rejected or
// malformed native answer may follow a request that reached the server, so it is uncertain.
export const requestUnsubscribe = (
  native: NativeUnsubscribe,
  offer: Extract<UnsubscribeOffer, { kind: 'one-click' }>,
): Promise<UnsubscribeOutcome> =>
  runLogged(
    Effect.tryPromise({
      try: () => native.requestUnsubscribe(offer.url),
      catch: rejectionDiagnostic,
    }).pipe(
      Effect.flatMap((answer) =>
        decodeAnswer(answer).pipe(Effect.mapError(decodeDiagnostic)),
      ),
      Effect.map(({ outcome }) => outcome),
      Effect.tapError((diagnostic) =>
        Effect.logError('Unsubscribe request ended unusably:', diagnostic),
      ),
      Effect.orElseSucceed(() => 'uncertain' as const),
    ),
  );

// A request to leave a mailing list that ended `sent`: the Mail Profile that owns the receiving
// connection, the list's Mailing List Identity and name, when it was sent in milliseconds since
// the epoch, and the address a `mailto:` request was emailed to. It holds no unsubscribe URI, raw
// header or request body.
const SentRequestSchema = Schema.Struct({
  profile: Schema.NonEmptyString,
  identity: Schema.NonEmptyString,
  list: Schema.NonEmptyString,
  sentAt: Schema.Int,
  to: Schema.optionalKey(Schema.NonEmptyString),
});
export type SentUnsubscribeRequest = typeof SentRequestSchema.Type;

const DocumentSchema = Schema.fromJsonString(
  Schema.Struct({ requests: Schema.Array(SentRequestSchema) }),
);
const OpenedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  document: Schema.NullOr(DocumentSchema),
});
const CommittedSchema = Schema.Struct({
  owner: Schema.NonEmptyString,
  revision: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
});

// The signed-in Product Account's sent unsubscribe requests on this device: one document native
// code keeps encrypted for the account that wrote it, like its Send Reminders. Every call rejects
// with 'locked' while the device is locked.
export interface NativeUnsubscribeRequests {
  // Resolves `{ owner, revision, document }`; `document` is null when the account has none.
  readonly openUnsubscribeRequests: () => Promise<unknown>;
  // Replaces the document only from `expectedRevision` and resolves `{ owner, revision }`.
  readonly commitUnsubscribeRequests: (
    owner: string,
    expectedRevision: number,
    document: string,
  ) => Promise<unknown>;
}

// ADR 0044: the offer returns only for a message the list sends this long after the request.
export const unsubscribeOfferReturnsAfter = 14 * 86_400_000;

// Whether `request` is `profile`'s request to leave the list with `identity`.
const matches =
  (profile: string, identity: string) => (request: SentUnsubscribeRequest) =>
    request.profile === profile && request.identity === identity;

// Locked storage is expected while the device is locked; any other failure is logged.
const report = (
  error: Readonly<Pick<DraftStorageFailure, 'kind' | 'diagnostic'>>,
) =>
  error.kind === 'locked'
    ? Effect.void
    : Effect.logError('Unsubscribe request storage failed:', error.diagnostic);

// Unsubscribe requests, each recorded on this device for the Mail Profile that sent it once it ends
// `sent`: one-click requests here, and `mailto:` requests by the Outbox once it confirms them.
// Records are not synchronized.
export function createUnsubscribe(
  storage: NativeUnsubscribe & NativeUnsubscribeRequests,
  registration: Pick<Registration, 'getSnapshot'>,
) {
  const semaphore = Semaphore.makeUnsafe(1);
  const signedIn = () => ownerOf(registration.getSnapshot().snapshot);
  // The requests of `account`, the Product Account signed in when the action was called, so an
  // action whose read finished while another account signed in reads and writes nothing of it.
  const opened = (account: string | undefined) =>
    Effect.gen(function* () {
      const { owner, revision, document } = yield* stored(
        storage.openUnsubscribeRequests,
        OpenedSchema,
      );
      if (owner !== account || signedIn() !== account) {
        return yield* ownerMismatch();
      }
      return { owner, revision, requests: document?.requests ?? [] };
    });
  // Records `request`, replacing the Profile's earlier one for the list. Resolves whether storage
  // holds it.
  const remember = (
    account: string | undefined,
    request: SentUnsubscribeRequest,
  ) =>
    runLogged(
      Effect.gen(function* () {
        const { owner, revision, requests } = yield* opened(account);
        const document = yield* Schema.encodeEffect(DocumentSchema)({
          requests: [
            ...requests.filter(
              (each) => !matches(request.profile, request.identity)(each),
            ),
            request,
          ],
        }).pipe(Effect.mapError(malformed));
        const committed = yield* stored(
          () => storage.commitUnsubscribeRequests(owner, revision, document),
          CommittedSchema,
        );
        if (committed.owner !== owner) {
          return yield* ownerMismatch();
        }
        return true;
      }).pipe(
        semaphore.withPermit,
        // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
        Effect.catchTag('DraftStorageFailure', (error) =>
          report(error).pipe(Effect.as(false)),
        ),
      ),
    );

  return {
    // `profile`'s sent request to leave `offer`'s list that still covers a message the list sent at
    // `receivedAt`, or undefined when none does: none was sent, the message came more than 14 days
    // after it, the offer has no Mailing List Identity, or storage cannot read the requests.
    sentRequest: (
      profile: string,
      { identity }: UnsubscribeOffer,
      receivedAt: number,
    ) =>
      runLogged(
        opened(signedIn()).pipe(
          Effect.map(({ requests }) =>
            requests.find(
              (request) =>
                identity !== undefined &&
                matches(profile, identity)(request) &&
                receivedAt <= request.sentAt + unsubscribeOfferReturnsAfter,
            ),
          ),
          // oxlint-disable-next-line promise/prefer-await-to-callbacks -- Effect's typed error channel.
          Effect.catchTag('DraftStorageFailure', (error) =>
            report(error).pipe(Effect.as(undefined)),
          ),
        ),
      ),
    // Sends the one-click offer's request once for `profile`, the Mail Profile that owns the
    // receiving connection, and records it for the Product Account signed in now when it ends
    // `sent` and the offer has a Mailing List Identity. A record storage refuses leaves the outcome
    // as it is.
    request: async (
      profile: string,
      offer: Extract<UnsubscribeOffer, { kind: 'one-click' }>,
      now: () => number = Date.now,
    ) => {
      const account = signedIn();
      const outcome = await requestUnsubscribe(storage, offer);
      if (outcome === 'sent' && offer.identity !== undefined) {
        await remember(account, {
          profile,
          identity: offer.identity,
          list: offer.list,
          sentAt: now(),
        });
      }
      return outcome;
    },
    // Records `request`, a confirmed `mailto:` request, for `account`, only while it is signed in.
    record: async (account: string, request: SentUnsubscribeRequest) => {
      await remember(account, request);
    },
  };
}
export type Unsubscribe = ReturnType<typeof createUnsubscribe>;
