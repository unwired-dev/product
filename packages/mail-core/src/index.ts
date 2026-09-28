import { Context, Data, Effect, Layer } from 'effect';

export interface Message {
  readonly id: string;
  readonly sender: string;
  readonly address: string;
  readonly subject: string;
  readonly preview: string;
  readonly body: string;
  readonly receivedAt: string;
  readonly unread: boolean;
}

export class MessageNotFound extends Data.TaggedError('MessageNotFound')<{
  readonly id: string;
}> {}

export class Mailbox extends Context.Service<
  Mailbox,
  {
    readonly list: Effect.Effect<readonly Message[]>;
    readonly find: (id: string) => Effect.Effect<Message, MessageNotFound>;
  }
>()('@private-email/mail-core/Mailbox') {}

const messages: readonly Message[] = [
  {
    id: 'studio-review',
    sender: 'Maya Chen',
    address: 'maya@example.com',
    subject: 'A little more room to think',
    preview: 'I put together a few notes for our studio review on Thursday.',
    body: 'Hi Alex,\n\nI put together a few notes for our studio review on Thursday. The quieter layout gives the work a little more room to breathe.\n\nCould we spend the first ten minutes looking at the reading experience on iPad? I would love to hear what feels natural with a keyboard attached.\n\nSee you then,\nMaya',
    receivedAt: '2026-09-28T09:42:00Z',
    unread: true,
  },
  {
    id: 'weekend-walk',
    sender: 'Oliver Park',
    address: 'oliver@example.com',
    subject: 'Saturday, by the river?',
    preview: 'The forecast looks good. Coffee first, then the long way home.',
    body: 'Hey Alex,\n\nThe forecast looks good. Coffee first, then the long way home? I can meet you by the river at ten.\n\nNo rush to reply.\nOliver',
    receivedAt: '2026-09-28T08:15:00Z',
    unread: true,
  },
  {
    id: 'reading-list',
    sender: 'Field Notes',
    address: 'notes@example.com',
    subject: 'Things worth keeping',
    preview: 'This week: small libraries, good questions, and a slower Sunday.',
    body: 'This week: small libraries, good questions, and a slower Sunday.\n\nOur reading list is taking a short break. We will be back next week with a new collection of essays.\n\nThanks for reading,\nThe Field Notes team',
    receivedAt: '2026-09-27T16:30:00Z',
    unread: false,
  },
  {
    id: 'reservation',
    sender: 'North House',
    address: 'hello@example.com',
    subject: 'Your table is ready for Friday',
    preview: 'We look forward to welcoming you at 19:00.',
    body: 'Hello Alex,\n\nYour reservation for two is confirmed for Friday at 19:00.\n\nWe look forward to welcoming you.\nNorth House',
    receivedAt: '2026-09-27T11:05:00Z',
    unread: false,
  },
];

export const MockMailbox = Layer.succeed(Mailbox, {
  list: Effect.succeed(messages),
  find: Effect.fn('MockMailbox.find')(function* (id: string) {
    const message = messages.find((candidate) => candidate.id === id);
    if (message === undefined) {
      return yield* new MessageNotFound({ id });
    }
    return message;
  }),
});

export const listInbox = Effect.gen(function* () {
  const mailbox = yield* Mailbox;
  return yield* mailbox.list;
});

export const readMessage = Effect.fn('readMessage')(function* (id: string) {
  const mailbox = yield* Mailbox;
  return yield* mailbox.find(id);
});
